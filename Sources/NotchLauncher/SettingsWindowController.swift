import Cocoa
import UniformTypeIdentifiers

/// 偏好设置:面板参数、登录项,以及配置导入/导出/恢复默认。
final class SettingsWindowController: NSWindowController {
    private let openStepper = NSStepper()
    private let closeStepper = NSStepper()
    private let rowStepper = NSStepper()
    private let openValueLabel = NSTextField(labelWithString: "")
    private let closeValueLabel = NSTextField(labelWithString: "")
    private let rowValueLabel = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录后自动启动", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 304),
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
        refreshLoginStatus()
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
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)

        let grid = NSGridView(views: [
            [titleLabel("悬停展开延迟"), openValueLabel, openStepper],
            [titleLabel("悬停收起延迟"), closeValueLabel, closeStepper],
            [titleLabel("每行图标数"), rowValueLabel, rowStepper],
            [titleLabel("开机启动"), loginCheckbox, NSView()],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)

        let hint = titleLabel("延迟范围 0.05–2.00 秒;每行 3–10 个。外部修改配置会自动加载。")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        let importButton = NSButton(title: "导入…", target: self, action: #selector(importConfig))
        let exportButton = NSButton(title: "导出…", target: self, action: #selector(exportConfig))
        let resetButton = NSButton(title: "恢复默认参数", target: self, action: #selector(resetSettings))
        let buttons = NSStackView(views: [importButton, exportButton, resetButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .labelColor
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

    /// 以配置文件中的现值为底,避免保存时抹掉其它已有关注字段。
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
        var settings = currentSettings()
        settings.openDelay = openStepper.doubleValue
        settings.closeDelay = closeStepper.doubleValue
        settings.iconsPerRow = rowStepper.integerValue
        refreshLabels(
            open: settings.resolvedOpenDelay,
            close: settings.resolvedCloseDelay,
            rows: settings.resolvedIconsPerRow
        )
        if AppConfig.saveSettings(settings) { notifyConfigurationChanged() }
    }

    @objc private func loginItemChanged() {
        let requested = loginCheckbox.state == .on
        let previous = LoginItemManager.isEnabled
        do {
            try LoginItemManager.setEnabled(requested)
            var settings = currentSettings()
            settings.loginItemEnabled = requested
            _ = AppConfig.saveSettings(settings)
            guard case .success(let saved) = AppConfig.loadConfig(), saved.settings == settings else {
                try? LoginItemManager.setEnabled(previous)
                throw LoginItemError.preferenceSaveFailed
            }
            notifyConfigurationChanged()
            if LoginItemManager.requiresApproval {
                showMessage("请在 系统设置 → 通用 → 登录项与扩展 中允许 NotchLauncher。")
            }
        } catch {
            showError(error)
        }
        refreshLoginStatus()
    }

    @objc private func importConfig() {
        let panel = NSOpenPanel()
        panel.prompt = "导入"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AppConfig.importConfig(from: url)
            var loginError: Error?
            if case .success(let file) = AppConfig.loadConfig(), let enabled = file.settings?.loginItemEnabled {
                do { try LoginItemManager.setEnabled(enabled) } catch { loginError = error }
            }
            loadCurrentValues()
            refreshLoginStatus()
            notifyConfigurationChanged()
            if let loginError {
                showMessage("配置已导入,但登录项状态未能同步:\(loginError.localizedDescription)")
            } else {
                showMessage("配置导入成功,原配置已备份。")
            }
        } catch {
            showError(error)
        }
    }

    @objc private func exportConfig() {
        let panel = NSSavePanel()
        panel.prompt = "导出"
        panel.nameFieldStringValue = "NotchLauncher-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AppConfig.exportConfig(to: url) } catch { showError(error) }
    }

    @objc private func resetSettings() {
        if AppConfig.resetInteractionSettings() { notifyConfigurationChanged() }
        loadCurrentValues()
    }

    private func refreshLoginStatus() {
        loginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
        loginCheckbox.toolTip = LoginItemManager.requiresApproval
            ? "需要在系统设置中允许"
            : nil
    }

    private func notifyConfigurationChanged() {
        NotificationCenter.default.post(name: .launcherSettingsDidChange, object: nil)
    }

    private func refreshLabels(open: Double, close: Double, rows: Int) {
        openValueLabel.stringValue = String(format: "%.2f 秒", open)
        closeValueLabel.stringValue = String(format: "%.2f 秒", close)
        rowValueLabel.stringValue = "\(rows) 个"
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func showMessage(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }
}
