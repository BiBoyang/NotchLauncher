import Cocoa
import UniformTypeIdentifiers

private let nlLogLock = NSLock()

func nlLog(_ message: String) {
    nlLogLock.lock()
    defer { nlLogLock.unlock() }
    FileHandle.standardError.write(Data(("[NotchLauncher] " + message + "\n").utf8))
}

extension NSScreen {
    /// 刘海矩形,全局屏幕坐标(左下原点)。无刘海返回 nil。
    var notchRect: NSRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }
        let minX = frame.origin.x + left.maxX
        let maxX = frame.origin.x + right.minX
        let height = safeAreaInsets.top
        return NSRect(x: minX, y: frame.maxY - height, width: maxX - minX, height: height)
    }
}

final class NotchController: NSResponder {
    private enum State { case closed, open }

    private var window: NotchWindow?
    private var contentView: LauncherContentView?
    private var state: State = .closed
    private var notchRect: NSRect = .zero
    private var screen: NSScreen?

    private var openWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    /// 拖拽会话(进或出)进行中:抑制 mouseExited 自动关闭。
    private var dragInProgress = false

    private let openDelay: TimeInterval = 0.15
    private let closeDelay: TimeInterval = 0.35
    private let hoverMarginSide: CGFloat = 4
    private let hoverMarginBottom: CGFloat = 8

    func start() {
        AppConfig.ensureExists()
        rebuildWindow()
    }

    func screenParametersChanged() {
        rebuildWindow()
    }

    private func hoverFrame(for notch: NSRect) -> NSRect {
        NSRect(
            x: notch.origin.x - hoverMarginSide,
            y: notch.origin.y - hoverMarginBottom,
            width: notch.width + hoverMarginSide * 2,
            height: notch.height + hoverMarginBottom
        )
    }

    private func rebuildWindow() {
        openWorkItem?.cancel()
        closeWorkItem?.cancel()
        removeMonitors()
        dragInProgress = false

        let oldWindow = window
        window = nil
        contentView = nil
        oldWindow?.orderOut(nil)

        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let notch = screen.notchRect else {
            state = .closed
            nlLog("未找到刘海屏,等待屏幕变化")
            return
        }

        self.screen = screen
        self.notchRect = notch
        state = .closed

        let window = NotchWindow(
            contentRect: hoverFrame(for: notch),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let content = LauncherContentView(frame: NSRect(origin: .zero, size: hoverFrame(for: notch).size))
        content.actionHandler = { [weak self] action in self?.handle(action) }
        window.contentView = content

        content.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        window.orderFrontRegardless()
        self.window = window
        self.contentView = content
        nlLog("就绪,刘海区域:\(NSStringFromRect(notch))")
    }

    // MARK: - 悬停事件(tracking area owner)

    override func mouseEntered(with event: NSEvent) {
        closeWorkItem?.cancel()
        guard state == .closed, window != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.openPanel() }
        openWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragInProgress else { return }
        openWorkItem?.cancel()
        guard state == .open else { return }
        let item = DispatchWorkItem { [weak self] in self?.closePanel() }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: item)
    }

    // MARK: - 拖拽会话抑制(拖入/拖出共用一个标志)

    private func setDragInProgress(_ inProgress: Bool) {
        guard dragInProgress != inProgress else { return }
        dragInProgress = inProgress
        if inProgress {
            closeWorkItem?.cancel()
            guard state == .closed, window != nil else { return }
            let item = DispatchWorkItem { [weak self] in self?.openPanel() }
            openWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: item)
        } else {
            openWorkItem?.cancel()
            guard state == .open, let window, !window.frame.contains(NSEvent.mouseLocation) else { return }
            let item = DispatchWorkItem { [weak self] in self?.closePanel() }
            closeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: item)
        }
    }

    // MARK: - 展开 / 收起

    private func openPanel() {
        guard let window, let contentView, let screen, state == .closed else { return }
        state = .open

        contentView.reloadApps(notchHeight: notchRect.height)
        let size = contentView.desiredPanelSize(minimumWidth: notchRect.width + 140)
        let target = panelTargetRect(size: size, screen: screen)

        contentView.panelExpanded = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        }
        installMonitors()
        nlLog("open")
    }

    private func closePanel() {
        guard let window, let contentView, state == .open else { return }
        state = .closed
        removeMonitors()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(hoverFrame(for: notchRect), display: true)
        }, completionHandler: {
            DispatchQueue.main.async {
                contentView.panelExpanded = false
            }
        })
        nlLog("closed")
    }

    private func panelTargetRect(size: CGSize, screen: NSScreen) -> NSRect {
        NSRect(
            x: notchRect.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 配置内容变化后:重建图标列表;面板开着则同步调整窗口尺寸。
    private func refreshApps() {
        guard let contentView else { return }
        contentView.reloadApps(notchHeight: notchRect.height)
        guard let window, let screen, state == .open else { return }
        let size = contentView.desiredPanelSize(minimumWidth: notchRect.width + 140)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().setFrame(panelTargetRect(size: size, screen: screen), display: true)
        }
    }

    private func installMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalClickMonitor = nil
        localKeyMonitor = nil
    }

    // MARK: - 动作

    private func handle(_ action: LauncherAction) {
        switch action {
        case .activate(let app):
            activate(app)
            closePanel()
        case .dragBegan:
            setDragInProgress(true)
        case .dragEnded:
            setDragInProgress(false)
        case .appsChanged:
            refreshApps()
        case .removeRequest(let identity, let dropPoint):
            setDragInProgress(false)
            handleRemoveRequest(identity: identity, dropPoint: dropPoint)
        case .addApps:
            presentOpenPanel()
        case .openConfig:
            AppConfig.openInEditor()
            closePanel()
        case .reload:
            contentView?.reloadApps(notchHeight: notchRect.height)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// 拖出删除:松手点必须超出面板窗口 frame 任一边界 >24pt 才执行;否则视为误拖,不删。
    private func handleRemoveRequest(identity: String, dropPoint: NSPoint) {
        guard let window else { return }
        let expanded = window.frame.insetBy(dx: -24, dy: -24)
        guard !expanded.contains(dropPoint) else { return }
        if AppConfig.remove(identity: identity) {
            nlLog("删除条目:\(identity)")
            refreshApps()
        }
    }

    /// 右键「添加应用…」:accessory app 先激活再弹 NSOpenPanel,选完关闭面板下拉。
    private func presentOpenPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }

        var added = false
        for url in panel.urls {
            if let entry = AppConfig.entry(forAppAt: url) {
                added = AppConfig.add(entry) || added
            }
        }
        if added {
            nlLog("通过面板添加 \(panel.urls.count) 个应用")
            refreshApps()
        }
        closePanel()
    }

    private func activate(_ app: ResolvedApp) {
        guard let url = app.url else { return }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let running = bundleID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }

        if let running {
            if #available(macOS 14.0, *) {
                running.activate(from: .current, options: [.activateAllWindows])
            } else {
                running.activate(options: [.activateAllWindows])
            }
            nlLog("激活:\(app.name)")
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    nlLog("启动失败 \(app.name):\(error.localizedDescription)")
                } else {
                    nlLog("启动:\(app.name)")
                }
            }
        }
    }
}
