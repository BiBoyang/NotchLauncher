import Cocoa

/// 拖出删除专用私有拖拽类型——严禁暴露 fileURL/file promise,防拖到 Finder 复制 .app。
private let cellRemovalPasteboardType = NSPasteboard.PasteboardType("dev.boyang.NotchLauncher.cellRemoval")

/// 图标拖出会话的拖拽源。独立对象而非让 cell 担任,避免删除后 cell 随 reload 释放的生命周期问题。
private final class CellRemovalDragSource: NSObject, NSDraggingSource {
    var onWillBegin: (() -> Void)?
    var onEnded: ((NSPoint) -> Void)?

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication: return .delete
        case .outsideApplication: return []
        @unknown default: return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onWillBegin?()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded?(screenPoint)
    }
}

final class AppCellView: NSView {
    static let cellSize = NSSize(width: 84, height: 92)

    private let app: ResolvedApp
    private let identity: String
    private let actionHandler: (LauncherAction) -> Void
    private var hovered = false { didSet { needsDisplay = true } }
    private var mouseDownPoint: NSPoint?
    private var activeDragSource: CellRemovalDragSource?

    init(app: ResolvedApp, identity: String, actionHandler: @escaping (LauncherAction) -> Void) {
        self.app = app
        self.identity = identity
        self.actionHandler = actionHandler
        super.init(frame: NSRect(origin: .zero, size: AppCellView.cellSize))

        let imageView = NSImageView(frame: NSRect(x: 18, y: 38, width: 48, height: 48))
        imageView.image = app.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        let label = NSTextField(labelWithString: app.name)
        label.frame = NSRect(x: 2, y: 20, width: 80, height: 14)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if app.isRunning {
            let dot = NSView(frame: NSRect(x: 39, y: 8, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
        }

        if app.url == nil {
            alphaValue = 0.35
            toolTip = "未安装或无法解析"
        } else {
            toolTip = app.name
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { AppCellView.cellSize }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered, app.url != nil {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard app.url != nil, let down = mouseDownPoint else { return }
        let now = convert(event.locationInWindow, from: nil)
        // 位移超过 8pt 才发起拖拽,保护点击激活手势
        guard hypot(now.x - down.x, now.y - down.y) > 8 else { return }
        mouseDownPoint = nil
        startDragSession(with: event, from: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), app.url != nil else { return }
        actionHandler(.activate(app))
    }

    private func startDragSession(with event: NSEvent, from downPoint: NSPoint) {
        let item = NSPasteboardItem()
        item.setString(identity, forType: cellRemovalPasteboardType)

        let iconSize = NSSize(width: 48, height: 48)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.draggingFrame = NSRect(
            x: downPoint.x - iconSize.width / 2,
            y: downPoint.y - iconSize.height / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        let icon = app.icon
        dragItem.imageComponentsProvider = {
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = icon
            component.frame = NSRect(origin: .zero, size: iconSize)
            return [component]
        }

        let source = CellRemovalDragSource()
        source.onWillBegin = { [weak self] in
            self?.actionHandler(.dragBegan)
        }
        let identity = self.identity
        source.onEnded = { [weak self] screenPoint in
            // 异步派发:避免在 session 回调栈里直接触发 reload 拆毁 cell
            DispatchQueue.main.async {
                self?.actionHandler(.removeRequest(identity: identity, dropPoint: screenPoint))
                self?.activeDragSource = nil
            }
        }
        activeDragSource = source

        let session = beginDraggingSession(with: [dragItem], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

final class LauncherContentView: NSView {
    var actionHandler: ((LauncherAction) -> Void)?
    var panelExpanded = false { didSet { needsDisplay = true } }

    private var stack: NSStackView?
    private var notchHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard panelExpanded else { return }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        if dragHighlighted {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    // MARK: - 拖入添加

    private var dragHighlighted = false { didSet { needsDisplay = true } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !draggedAppURLs(sender).isEmpty else { return [] }
        dragHighlighted = true
        actionHandler?(.dragBegan)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedAppURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHighlighted = false
        actionHandler?(.dragEnded)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        var added = false
        for url in draggedAppURLs(sender) where Self.isReadableAppBundle(url) {
            if let entry = AppConfig.entry(forAppAt: url) {
                added = AppConfig.add(entry) || added
            }
        }
        if added { actionHandler?(.appsChanged) }
        return added
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragHighlighted = false
        actionHandler?(.dragEnded)
    }

    /// 拖拽内容里以 .app 结尾的文件 URL;完整校验在松手时做,不合规静默忽略。
    private func draggedAppURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL])?.filter { $0.pathExtension.lowercased() == "app" } ?? []
    }

    private static func isReadableAppBundle(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              Bundle(url: url) != nil else { return false }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        addItem(menu, title: "添加应用…", action: #selector(menuAddApps))
        addItem(menu, title: "编辑配置文件", action: #selector(menuEditConfig))
        addItem(menu, title: "重新加载", action: #selector(menuReload))
        menu.addItem(.separator())
        addItem(menu, title: "退出 NotchLauncher", action: #selector(menuQuit))
        return menu
    }

    private func addItem(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuAddApps() { actionHandler?(.addApps) }
    @objc private func menuEditConfig() { actionHandler?(.openConfig) }
    @objc private func menuReload() { actionHandler?(.reload) }
    @objc private func menuQuit() { actionHandler?(.quit) }
    @objc private func openConfigClicked() { actionHandler?(.openConfig) }

    func reloadApps(notchHeight: CGFloat) {
        self.notchHeight = notchHeight
        stack?.removeFromSuperview()

        let newStack = NSStackView()
        newStack.orientation = .horizontal
        newStack.spacing = 10
        newStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newStack)
        NSLayoutConstraint.activate([
            newStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            newStack.topAnchor.constraint(equalTo: topAnchor, constant: notchHeight + 12),
        ])

        switch AppConfig.load() {
        case .success(let entries) where !entries.isEmpty:
            for entry in entries {
                let app = AppConfig.resolve(entry)
                newStack.addArrangedSubview(AppCellView(app: app, identity: entry.identity) { [weak self] action in
                    self?.actionHandler?(action)
                })
            }
        case .success:
            newStack.addArrangedSubview(makeMessageCell(
                title: "还没有添加应用",
                buttonTitle: "打开配置文件"
            ))
        case .failure(let error):
            newStack.addArrangedSubview(makeMessageCell(
                title: "配置文件格式错误:\(error.localizedDescription)",
                buttonTitle: "打开配置文件"
            ))
        }

        stack = newStack
    }

    func desiredPanelSize(minimumWidth: CGFloat) -> CGSize {
        let fitting = stack?.fittingSize ?? NSSize(width: 280, height: 92)
        return CGSize(
            width: max(fitting.width + 36, minimumWidth),
            height: notchHeight + 12 + fitting.height + 16
        )
    }

    private func makeMessageCell(title: String, buttonTitle: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: title)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.font = NSFont.systemFont(ofSize: 11)
        label.alignment = .center
        label.maximumNumberOfLines = 2

        let button = NSButton(title: buttonTitle, target: self, action: #selector(openConfigClicked))
        button.bezelStyle = .rounded
        button.controlSize = .small

        let vertical = NSStackView(views: [label, button])
        vertical.orientation = .vertical
        vertical.spacing = 8
        vertical.alignment = .centerX
        vertical.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(vertical)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 300),
            container.heightAnchor.constraint(equalToConstant: AppCellView.cellSize.height),
            vertical.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            vertical.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -16),
        ])
        return container
    }
}
