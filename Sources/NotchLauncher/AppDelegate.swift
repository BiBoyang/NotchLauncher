import Cocoa
import ServiceManagement

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

    /// 开机自启:仅当 bundle 位于 /Applications 或 ~/Applications 时注册 SMAppService 登录项;
    /// 从开发目录运行时跳过,防止登录项指向会过期的开发构建。注册失败仅记日志,不影响启动。
    private func registerLoginItemIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let userApplications = NSHomeDirectory() + "/Applications"
        let installed = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(userApplications + "/")

        guard installed else {
            nlLog("LoginItem: skip, bundle not under /Applications or ~/Applications (\(bundlePath))")
            return
        }

        let service = SMAppService.mainApp
        if service.status == .enabled {
            nlLog("LoginItem: already enabled, skip register")
            return
        }

        do {
            try service.register()
            nlLog("LoginItem: registered (\(bundlePath))")
        } catch {
            nlLog("LoginItem: register failed: \(error)")
        }
    }
}
