import Cocoa
import ServiceManagement

enum LoginItemError: LocalizedError {
    case notInstalled
    case preferenceSaveFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "请先将 NotchLauncher.app 放入 /Applications 或 ~/Applications,再修改开机启动。"
        case .preferenceSaveFailed:
            return "系统登录项已修改,但偏好保存失败,已尝试恢复原状态。"
        }
    }
}

enum LoginItemManager {
    private static var service: SMAppService { .mainApp }

    static var isInstalled: Bool {
        let bundlePath = Bundle.main.bundlePath
        let userApplications = NSHomeDirectory() + "/Applications"
        return bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(userApplications + "/")
    }

    static var isEnabled: Bool { service.status == .enabled }
    static var requiresApproval: Bool { service.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        guard isInstalled else { throw LoginItemError.notInstalled }
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
