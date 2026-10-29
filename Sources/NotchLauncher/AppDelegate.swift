import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController()
        controller.start()
        self.controller = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        registerLoginItemIfNeeded()
    }

    @objc private func screenParametersChanged() {
        controller?.screenParametersChanged()
    }

    /// 保留既有首次启动自动注册;用户在设置中明确关闭后不再重复注册。
    private func registerLoginItemIfNeeded() {
        if case .success(let file) = AppConfig.loadConfig(), file.settings?.loginItemEnabled == false {
            nlLog("LoginItem: disabled by user preference, skip register")
            return
        }
        do {
            try LoginItemManager.setEnabled(true)
            nlLog("LoginItem: enabled=\(LoginItemManager.isEnabled), requiresApproval=\(LoginItemManager.requiresApproval)")
        } catch LoginItemError.notInstalled {
            nlLog("LoginItem: skip, development bundle (\(Bundle.main.bundlePath))")
        } catch {
            nlLog("LoginItem: register failed: \(error)")
        }
    }
}
