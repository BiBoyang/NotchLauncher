import Cocoa

/// 拖出删除专用私有拖拽类型——严禁暴露 fileURL/file promise,防拖到 Finder 复制 .app。
private let cellRemovalPasteboardType = NSPasteboard.PasteboardType("dev.boyang.NotchLauncher.cellRemoval")

/// 拖动排序时的占位格:源 cell 隐藏后占据其视觉位置,随鼠标在行间移动。
private final class DropGapView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: AppCellView.cellSize.width, height: AppCellView.cellSize.height)
    }
}

/// 图标拖出/拖内排序会话的拖拽源。独立对象而非让 cell 担任,避免删除后 cell 随 reload 释放的生命周期问题。
private final class CellRemovalDragSource: NSObject, NSDraggingSource {
    var onWillBegin: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
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

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMoved?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded?(screenPoint)
    }
}

final class AppCellView: NSView {
    static let cellSize = NSSize(width: 84, height: 92)

    private let app: ResolvedApp
    let identity: String
    private let actionHandler: (LauncherAction) -> Void

    /// 面板内排序协调回调,由 LauncherContentView 装配。
    var onDragWillBegin: ((String) -> Void)?
    var onDragMoved: ((String, NSPoint) -> Void)?
    var onDragEnded: ((String, NSPoint) -> Void)?

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
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if app.isRunning {
            let dot = NSView(frame: NSRect(x: 39, y: 8, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
        } else {
            label.textColor = NSColor.white.withAlphaComponent(0.55)
        }

        if app.url == nil {
            alphaValue = 0.35
            toolTip = "未安装或无法解析"
            imageView.alphaValue = 1
            label.textColor = NSColor.white.withAlphaComponent(0.55)
        } else if !app.isRunning {
            // 已安装但未运行:图标与名字淡化;运行中维持全彩图标 + 白色名字
            imageView.alphaValue = 0.6
            toolTip = app.name
        } else {
            label.textColor = .white
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

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard app.url != nil else { return nil }
        let menu = NSMenu()
        if runningApplication != nil {
            addMenuItem(menu, title: "退出", action: #selector(terminateApp))
            addMenuItem(menu, title: "强制退出", action: #selector(forceTerminateApp))
        } else {
            addMenuItem(menu, title: "打开", action: #selector(openApp))
        }
        menu.addItem(.separator())
        addMenuItem(menu, title: "在 Finder 中显示", action: #selector(revealApp))
        menu.addItem(.separator())
        addMenuItem(menu, title: "隐藏", action: #selector(hideSelf))
        addMenuItem(menu, title: "从面板移除", action: #selector(removeSelf))
        return menu
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private var runningApplication: NSRunningApplication? {
        guard let url = app.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    @objc private func openApp() { actionHandler(.activate(app)) }
    @objc private func terminateApp() { actionHandler(.terminate(app, force: false)) }
    @objc private func forceTerminateApp() { actionHandler(.terminate(app, force: true)) }
    @objc private func revealApp() { actionHandler(.reveal(app)) }
    @objc private func hideSelf() { actionHandler(.setHidden(identity: identity, hidden: true)) }
    @objc private func removeSelf() { actionHandler(.remove(identity: identity)) }

    // MARK: - 左键:点击激活 / 拖动发起

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
            guard let self else { return }
            self.onDragWillBegin?(self.identity)
        }
        source.onMoved = { [weak self] screenPoint in
            guard let self else { return }
            self.onDragMoved?(self.identity, screenPoint)
        }
        source.onEnded = { [weak self] screenPoint in
            // 异步派发:避免在 session 回调栈里直接触发 reload 拆毁 cell
            DispatchQueue.main.async {
                guard let self else { return }
                self.onDragEnded?(self.identity, screenPoint)
                self.activeDragSource = nil
            }
        }
        activeDragSource = source

        let session = beginDraggingSession(with: [dragItem], event: event, source: source)
        // 拖出删除:松手失败时禁止幽灵图标飞回原位,否则出现"飞回再消失"的诡异动画
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class LauncherContentView: NSView {
    var actionHandler: ((LauncherAction) -> Void)?
    var panelExpanded = false { didSet { needsDisplay = true } }

    private var scrollView: NSScrollView?
    private var grid: NSStackView?
    private var rows: [NSStackView] = []
    private var cellsByIdentity: [String: AppCellView] = [:]
    private var notchHeight: CGFloat = 0
    private var iconsPerRow = LauncherSettings.defaultIconsPerRow
    private var visibleContentSize = NSSize(width: 280, height: 92)

    /// 图标排序拖拽会话进行中(区别于 Finder 文件拖入);期间拒绝 reload 拆毁网格。
    private var reorderIdentity: String?
    var isReorderSessionActive: Bool { reorderIdentity != nil }
    private var gapView: DropGapView?
    private var autoScrollTimer: Timer?
    private var lastDragScreenPoint: NSPoint?

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

    // MARK: - 拖入添加(Finder .app)

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

    // MARK: - 空白处右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        addItem(menu, title: "添加应用…", action: #selector(menuAddApps))
        addItem(menu, title: "设置…", action: #selector(menuSettings))

        let hiddenEntries: [AppEntry]
        if case .success(let file) = AppConfig.loadConfig() {
            hiddenEntries = file.apps.filter { $0.hidden == true }
        } else {
            hiddenEntries = []
        }
        let hiddenItem = NSMenuItem(title: "已隐藏应用 (\(hiddenEntries.count))", action: nil, keyEquivalent: "")
        let hiddenMenu = NSMenu()
        for entry in hiddenEntries {
            let title = entry.name ?? entry.bundleID ?? entry.path ?? "未知应用"
            let item = NSMenuItem(title: title, action: #selector(restoreHiddenApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.identity
            hiddenMenu.addItem(item)
        }
        hiddenItem.submenu = hiddenMenu
        hiddenItem.isEnabled = !hiddenEntries.isEmpty
        menu.addItem(hiddenItem)

        menu.addItem(.separator())
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
    @objc private func menuSettings() { actionHandler?(.openSettings) }
    @objc private func menuEditConfig() { actionHandler?(.openConfig) }
    @objc private func menuReload() { actionHandler?(.reload) }
    @objc private func menuQuit() { actionHandler?(.quit) }
    @objc private func openConfigClicked() { actionHandler?(.openConfig) }

    @objc private func restoreHiddenApp(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String else { return }
        actionHandler?(.setHidden(identity: identity, hidden: false))
    }

    // MARK: - 网格构建(固定按配置顺序)

    func reloadApps(notchHeight: CGFloat, maxContentHeight: CGFloat = .greatestFiniteMagnitude) {
        self.notchHeight = notchHeight
        stopAutoScroll()
        lastDragScreenPoint = nil
        scrollView?.removeFromSuperview()
        scrollView = nil
        rows = []
        cellsByIdentity = [:]
        reorderIdentity = nil
        gapView = nil

        let newGrid = NSStackView()
        newGrid.orientation = .vertical
        newGrid.alignment = .centerX
        newGrid.spacing = 10
        newGrid.translatesAutoresizingMaskIntoConstraints = false

        var cells: [NSView] = []
        switch AppConfig.loadConfig() {
        case .success(let file):
            iconsPerRow = file.settings?.resolvedIconsPerRow ?? LauncherSettings.defaultIconsPerRow
            let visibleEntries = file.apps.filter { $0.hidden != true }
            for entry in visibleEntries {
                cells.append(makeCell(for: entry, app: AppConfig.resolve(entry)))
            }
            if file.apps.isEmpty {
                cells.append(makeMessageCell(title: "还没有添加应用", buttonTitle: "打开配置文件"))
            } else if visibleEntries.isEmpty {
                cells.append(makeMessageCell(
                    title: "所有应用都已隐藏\n可在面板右键菜单中恢复",
                    buttonTitle: "打开配置文件"
                ))
            }
        case .failure(let error):
            iconsPerRow = LauncherSettings.defaultIconsPerRow
            cells.append(makeMessageCell(
                title: "配置文件格式错误:\(error.localizedDescription)",
                buttonTitle: "打开配置文件"
            ))
        }

        for start in stride(from: 0, to: cells.count, by: iconsPerRow) {
            let end = min(start + iconsPerRow, cells.count)
            let row = NSStackView(views: Array(cells[start..<end]))
            row.spacing = 10
            newGrid.addArrangedSubview(row)
            rows.append(row)
        }

        let fitting = newGrid.fittingSize
        let visibleHeight = min(fitting.height, maxContentHeight)
        visibleContentSize = NSSize(width: fitting.width, height: visibleHeight)

        let document = FlippedDocumentView(frame: NSRect(origin: .zero, size: fitting))
        document.addSubview(newGrid)
        NSLayoutConstraint.activate([
            newGrid.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            newGrid.topAnchor.constraint(equalTo: document.topAnchor),
        ])

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: visibleContentSize))
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = fitting.height > visibleHeight + 0.5
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: notchHeight + 12),
            scroll.widthAnchor.constraint(equalToConstant: visibleContentSize.width),
            scroll.heightAnchor.constraint(equalToConstant: visibleContentSize.height),
        ])
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        grid = newGrid
        scrollView = scroll
    }

    private func makeCell(for entry: AppEntry, app: ResolvedApp) -> AppCellView {
        let cell = AppCellView(app: app, identity: entry.identity) { [weak self] action in
            self?.actionHandler?(action)
        }
        cell.onDragWillBegin = { [weak self] identity in self?.reorderBegan(identity) }
        cell.onDragMoved = { [weak self] identity, point in self?.reorderMoved(identity, screenPoint: point) }
        cell.onDragEnded = { [weak self] identity, point in self?.reorderEnded(identity, screenPoint: point) }
        cellsByIdentity[entry.identity] = cell
        return cell
    }

    func desiredPanelSize(minimumWidth: CGFloat) -> CGSize {
        CGSize(
            width: max(visibleContentSize.width + 36, minimumWidth),
            height: notchHeight + 12 + visibleContentSize.height + 16
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

    // MARK: - 面板内拖放排序

    private func reorderBegan(_ identity: String) {
        guard reorderIdentity == nil, let source = cellsByIdentity[identity] else { return }
        reorderIdentity = identity
        actionHandler?(.dragBegan)

        source.isHidden = true
        let gap = DropGapView()
        gapView = gap
        if let row = source.superview as? NSStackView,
           let index = row.arrangedSubviews.firstIndex(where: { $0 === source }) {
            row.insertArrangedSubview(gap, at: index)
        }
    }

    private func reorderMoved(_ identity: String, screenPoint: NSPoint) {
        guard reorderIdentity == identity else { return }
        lastDragScreenPoint = screenPoint
        moveGap(identity, screenPoint: screenPoint)
        updateAutoScroll()
    }

    private func moveGap(_ identity: String, screenPoint: NSPoint) {
        guard reorderIdentity == identity,
              let gapView,
              let window,
              let grid,
              !rows.isEmpty
        else { return }

        let gridPoint = grid.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard let row = rows.first(where: { $0.frame.insetBy(dx: 0, dy: -12).contains(gridPoint) }) else {
            return
        }

        let rowPoint = row.convert(gridPoint, from: grid)
        let visibleViews = row.arrangedSubviews.filter { !($0 is DropGapView) && !$0.isHidden }
        var slot = visibleViews.count
        for (index, view) in visibleViews.enumerated() where rowPoint.x < view.frame.midX {
            slot = index
            break
        }

        gapView.removeFromSuperview()
        let visibleArrangedIndices = row.arrangedSubviews.indices.filter {
            !(row.arrangedSubviews[$0] is DropGapView) && !row.arrangedSubviews[$0].isHidden
        }
        if slot < visibleArrangedIndices.count {
            row.insertArrangedSubview(gapView, at: visibleArrangedIndices[slot])
        } else {
            row.addArrangedSubview(gapView)
        }
    }

    private func reorderEnded(_ identity: String, screenPoint: NSPoint) {
        guard reorderIdentity == identity else { return }
        reorderIdentity = nil
        stopAutoScroll()
        lastDragScreenPoint = nil
        let gap = gapView
        gapView = nil

        guard let window else {
            gap?.removeFromSuperview()
            cellsByIdentity[identity]?.isHidden = false
            actionHandler?(.dragEnded)
            return
        }

        let expanded = window.frame.insetBy(dx: -24, dy: -24)
        guard expanded.contains(screenPoint) else {
            gap?.removeFromSuperview()
            actionHandler?(.removeRequest(identity: identity, dropPoint: screenPoint))
            return
        }

        let newOrder = visualIdentityOrder(sourceIdentity: identity, gap: gap)
        gap?.removeFromSuperview()

        let changed = AppConfig.reorder(orderedIdentities: newOrder)
        actionHandler?(.dragEnded)
        if changed {
            actionHandler?(.appsChanged)
        } else {
            cellsByIdentity[identity]?.isHidden = false
        }
    }

    private func visualIdentityOrder(sourceIdentity: String, gap: DropGapView?) -> [String] {
        var result: [String] = []
        for row in rows {
            for view in row.arrangedSubviews {
                if let gap, view === gap {
                    result.append(sourceIdentity)
                } else if let cell = view as? AppCellView, cell.identity != sourceIdentity {
                    result.append(cell.identity)
                }
            }
        }
        return result
    }

    // MARK: - 排序拖拽边缘自动滚动

    private func autoScrollAmount(for screenPoint: NSPoint) -> CGFloat {
        guard let scrollView, scrollView.hasVerticalScroller, let window else { return 0 }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard scrollView.frame.contains(point) else { return 0 }
        let edge: CGFloat = 28
        let topDistance = scrollView.frame.maxY - point.y
        let bottomDistance = point.y - scrollView.frame.minY
        if topDistance >= 0, topDistance < edge {
            return -max(2, (edge - topDistance) / edge * 10)
        }
        if bottomDistance >= 0, bottomDistance < edge {
            return max(2, (edge - bottomDistance) / edge * 10)
        }
        return 0
    }

    private func updateAutoScroll() {
        guard let point = lastDragScreenPoint, autoScrollAmount(for: point) != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.autoScrollStep()
        }
        autoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func autoScrollStep() {
        guard let identity = reorderIdentity,
              let point = lastDragScreenPoint,
              let scrollView,
              let document = scrollView.documentView else {
            stopAutoScroll()
            return
        }
        let amount = autoScrollAmount(for: point)
        guard amount != 0 else {
            stopAutoScroll()
            return
        }
        let clip = scrollView.contentView
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let oldY = clip.bounds.origin.y
        let newY = min(max(0, oldY + amount), maximum)
        guard newY != oldY else {
            stopAutoScroll()
            return
        }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
        moveGap(identity, screenPoint: point)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }
}
