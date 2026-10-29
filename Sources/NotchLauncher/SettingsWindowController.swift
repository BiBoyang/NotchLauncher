import Cocoa

/// 极简偏好设置窗口:悬停延迟 ×2、每行图标数。改动即时写 apps.json 并广播生效。
final class SettingsWindowController: NSWindowController {
    private let openStepper = NSStepper()
    private let closeStepper = NSStepper()
    private let rowStepper = NSStepper()
    private let openValueLabel = NSTextField(labelWithString: "")
    private let closeValueLabel = NSTextField(labelWithString: "")
    private let rowValueLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 204),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchLauncher 设置"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupContent(in: window)
    }

    func show() {
        loadCurrentValues()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    // MARK: - 构建

    private func setupContent(in window: NSWindow) {
        guard let content = window.contentView else { return }

        configure(openStepper, min: 0.05, max: 2.0, increment: 0.05, action: #selector(openDelayChanged))
        configure(closeStepper, min: 0.05, max: 2.0, increment: 0.05, action: #selector(closeDelayChanged))
        configureRowStepper()

        let grid = NSGridView(views: [
            [titleLabel("悬停展开延迟"), openValueLabel, openStepper],
            [titleLabel("悬停收起延迟"), closeValueLabel, closeStepper],
            [titleLabel("每行图标数"), rowValueLabel, rowStepper],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let hint = titleLabel("延迟范围 0.05–2.00 秒;每行 3–10 个。改动即时生效。")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = NSColor.secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = NSColor.labelColor
        label.alignment = .right
        return label
    }

    private func configure(_ stepper: NSStepper, min: Double, max: Double, increment: Double, action: Selector) {
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = self
        stepper.action = action
    }

    private func configureRowStepper() {
        rowStepper.minValue = Double(LauncherSettings.iconsPerRowRange.lowerBound)
        rowStepper.maxValue = Double(LauncherSettings.iconsPerRowRange.upperBound)
        rowStepper.increment = 1
        rowStepper.valueWraps = false
        rowStepper.autorepeat = true
        rowStepper.target = self
        rowStepper.action = #selector(iconsPerRowChanged)
    }

    // MARK: - 读写

    private func loadCurrentValues() {
        let settings = currentSettings()
        openStepper.doubleValue = settings.resolvedOpenDelay
        closeStepper.doubleValue = settings.resolvedCloseDelay
        rowStepper.integerValue = settings.resolvedIconsPerRow
        refreshLabels(open: settings.resolvedOpenDelay, close: settings.resolvedCloseDelay, rows: settings.resolvedIconsPerRow)
    }

    /// 以配置文件中的现值为底;缺失字段取默认,避免保存时抹掉其它已有关注字段。
    private func currentSettings() -> LauncherSettings {
        if case .success(let file) = AppConfig.loadConfig(), let existing = file.settings {
            return existing
        }
        return LauncherSettings()
    }

    @objc private func openDelayChanged() { persist() }
    @objc private func closeDelayChanged() { persist() }
    @objc private func iconsPerRowChanged() { persist() }

    private func persist() {
        let settings = LauncherSettings(
            openDelay: openStepper.doubleValue,
            closeDelay: closeStepper.doubleValue,
            iconsPerRow: rowStepper.integerValue
        )
        refreshLabels(
            open: settings.resolvedOpenDelay,
            close: settings.resolvedCloseDelay,
            rows: settings.resolvedIconsPerRow
        )
        if AppConfig.saveSettings(settings) {
            NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
        }
    }

    private func refreshLabels(open: Double, close: Double, rows: Int) {
        openValueLabel.stringValue = String(format: "%.2f 秒", open)
        closeValueLabel.stringValue = String(format: "%.2f 秒", close)
        rowValueLabel.stringValue = "\(rows) 个"
    }
}
