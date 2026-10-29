import Cocoa

struct AppEntry: Codable {
    var name: String?
    var bundleID: String?
    var path: String?
    var hidden: Bool? = nil

    /// 条目身份:bundleID 优先,否则 path。去重与删除都按此匹配。
    var identity: String {
        if let bundleID, !bundleID.isEmpty { return "bundleID:" + bundleID }
        return "path:" + (path ?? "")
    }
}

/// 可配置参数;全部可选,缺省/非法值由 resolved* 回退默认。
struct LauncherSettings: Codable, Equatable {
    var openDelay: Double?
    var closeDelay: Double?
    var iconsPerRow: Int?
    /// nil 表示沿用首次启动自动注册的默认行为;false 表示用户明确关闭。
    var loginItemEnabled: Bool?

    static let defaultOpenDelay: TimeInterval = 0.15
    static let defaultCloseDelay: TimeInterval = 0.35
    static let defaultIconsPerRow = 8
    static let maxVisibleRows = 2

    static let delayRange: ClosedRange<Double> = 0...2
    static let iconsPerRowRange: ClosedRange<Int> = 3...10

    /// 逐字段容错解码:任一字段类型错误只丢弃该字段,不拖垮整个 settings。
    init(
        openDelay: Double? = nil,
        closeDelay: Double? = nil,
        iconsPerRow: Int? = nil,
        loginItemEnabled: Bool? = nil
    ) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.iconsPerRow = iconsPerRow
        self.loginItemEnabled = loginItemEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openDelay = (try? c.decodeIfPresent(Double.self, forKey: .openDelay)) ?? nil
        closeDelay = (try? c.decodeIfPresent(Double.self, forKey: .closeDelay)) ?? nil
        iconsPerRow = (try? c.decodeIfPresent(Int.self, forKey: .iconsPerRow)) ?? nil
        loginItemEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .loginItemEnabled)) ?? nil
    }

    var resolvedOpenDelay: TimeInterval {
        Self.clampDelay(openDelay ?? Self.defaultOpenDelay)
    }

    var resolvedCloseDelay: TimeInterval {
        Self.clampDelay(closeDelay ?? Self.defaultCloseDelay)
    }

    var resolvedIconsPerRow: Int {
        guard let iconsPerRow else { return Self.defaultIconsPerRow }
        return Self.iconsPerRowRange.contains(iconsPerRow) ? iconsPerRow : Self.defaultIconsPerRow
    }

    private static func clampDelay(_ value: Double) -> Double {
        min(max(value, delayRange.lowerBound), delayRange.upperBound)
    }
}

struct AppConfigFile: Codable {
    var apps: [AppEntry]
    var settings: LauncherSettings?

    init(apps: [AppEntry], settings: LauncherSettings? = nil) {
        self.apps = apps
        self.settings = settings
    }

    /// settings 整体容错:字段缺失正常,settings 节点类型错误时降级为默认而非整体加载失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decode([AppEntry].self, forKey: .apps)
        settings = (try? c.decodeIfPresent(LauncherSettings.self, forKey: .settings)) ?? nil
    }
}

enum AppConfigWriteResult: Equatable {
    case written
    case noChange
    case limitReached
    case failed
}

struct ResolvedApp {
    let name: String
    let url: URL?
    let icon: NSImage
    let isRunning: Bool
}

enum LauncherAction {
    case activate(ResolvedApp)
    case terminate(ResolvedApp, force: Bool)
    case reveal(ResolvedApp)
    case remove(identity: String)
    case setHidden(identity: String, hidden: Bool)
    case dragBegan
    case dragEnded
    case appsChanged
    case appLimitReached
    case removeRequest(identity: String, dropPoint: NSPoint)
    case addApps
    case openSettings
    case openConfig
    case reload
    case quit
}

extension Notification.Name {
    /// 设置窗口写入新参数后广播;controller 收到后重读并重排。
    static let launcherSettingsDidChange = Notification.Name("dev.boyang.NotchLauncher.settingsDidChange")
    /// 内部写入通知:仅供文件监控更新内容基准,避免把自己的写回误判为外部编辑。
    static let launcherConfigDidWrite = Notification.Name("dev.boyang.NotchLauncher.configDidWrite")
}

enum AppConfig {
    static let visibleAppLimit = 16

    /// 测试接缝:非 nil 时配置目录改指此处(仅数据层断言脚本使用)。
    static var directoryOverride: URL?

    static var directoryURL: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchLauncher", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("apps.json")
    }

    static var backupsDirectoryURL: URL {
        directoryURL.appendingPathComponent("Backups", isDirectory: true)
    }

    static func ensureExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? #"{"apps": []}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func loadConfig() -> Result<AppConfigFile, Error> {
        ensureExists()
        do {
            let data = try Data(contentsOf: fileURL)
            return .success(try JSONDecoder().decode(AppConfigFile.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    static func load() -> Result<[AppEntry], Error> {
        loadConfig().map { $0.apps }
    }

    static func openInEditor() {
        ensureExists()
        NSWorkspace.shared.open(fileURL)
    }

    /// 从 .app bundle 构造条目:自动读出 name/bundleID。
    static func entry(forAppAt url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(name: name, bundleID: bundle.bundleIdentifier, path: url.path)
    }

    /// 添加条目;重复跳过,可见条目达到上限时拒绝。旧配置已有超额条目仍原样保留。
    @discardableResult
    static func add(_ entry: AppEntry) -> Bool {
        addWithResult(entry) == .written
    }

    @discardableResult
    static func addWithResult(_ entry: AppEntry) -> AppConfigWriteResult {
        switch loadConfig() {
        case .failure(let error):
            nlLog("配置读取失败,放弃添加:\(error.localizedDescription)")
            return .failed
        case .success(var file):
            guard !file.apps.contains(where: { $0.identity == entry.identity }) else { return .noChange }
            guard visibleAppCount(in: file) < visibleAppLimit || entry.hidden == true else { return .limitReached }
            file.apps.append(entry)
            return save(file) ? .written : .failed
        }
    }

    /// 按 identity 删除条目;不存在不报错(幂等)。返回是否真的发生了删除。
    @discardableResult
    static func remove(identity: String) -> Bool {
        update { file in
            let before = file.apps.count
            file.apps.removeAll { $0.identity == identity }
            return file.apps.count != before
        }
    }

    /// 按 UI 落地的 identity 顺序重排;漏传的可见条目追加末尾,隐藏条目保留原位置。
    @discardableResult
    static func reorder(orderedIdentities: [String]) -> Bool {
        update { file in
            var byIdentity: [String: AppEntry] = [:]
            for entry in file.apps { byIdentity[entry.identity] = entry }

            var reordered: [AppEntry] = []
            var seen = Set<String>()
            for identity in orderedIdentities {
                if let entry = byIdentity[identity], seen.insert(identity).inserted {
                    reordered.append(entry)
                }
            }
            for entry in file.apps where !seen.contains(entry.identity) && entry.hidden != true {
                reordered.append(entry)
                seen.insert(entry.identity)
            }
            // 隐藏条目不在当前 UI 排序列表中;按原下标插回,避免无意移到末尾。
            for (index, entry) in file.apps.enumerated() where entry.hidden == true && !seen.contains(entry.identity) {
                reordered.insert(entry, at: min(index, reordered.count))
                seen.insert(entry.identity)
            }

            guard reordered.map(\.identity) != file.apps.map(\.identity) else { return false }
            file.apps = reordered
            return true
        }
    }

    @discardableResult
    static func setHidden(identity: String, hidden: Bool) -> Bool {
        setHiddenWithResult(identity: identity, hidden: hidden) == .written
    }

    @discardableResult
    static func setHiddenWithResult(identity: String, hidden: Bool) -> AppConfigWriteResult {
        switch loadConfig() {
        case .failure(let error):
            nlLog("配置读取失败,放弃修改可见性:\(error.localizedDescription)")
            return .failed
        case .success(var file):
            guard let index = file.apps.firstIndex(where: { $0.identity == identity }),
                  (file.apps[index].hidden ?? false) != hidden else { return .noChange }
            if !hidden, visibleAppCount(in: file) >= visibleAppLimit { return .limitReached }
            file.apps[index].hidden = hidden
            return save(file) ? .written : .failed
        }
    }

    private static func visibleAppCount(in file: AppConfigFile) -> Int {
        file.apps.reduce(into: 0) { count, entry in
            if entry.hidden != true { count += 1 }
        }
    }

    /// 写入设置;保留现有 apps 列表。
    @discardableResult
    static func saveSettings(_ settings: LauncherSettings) -> Bool {
        update { file in
            guard file.settings != settings else { return false }
            file.settings = settings
            return true
        }
    }

    /// 恢复延迟和网格默认值;保留 apps 与登录项选择。
    @discardableResult
    static func resetInteractionSettings() -> Bool {
        update { file in
            var reset = LauncherSettings()
            reset.loginItemEnabled = file.settings?.loginItemEnabled
            let current = file.settings ?? LauncherSettings()
            guard current != reset else { return false }
            file.settings = reset
            return true
        }
    }

    /// 导出原始配置,即使当前 JSON 已损坏也允许用户备份抢救。
    static func exportConfig(to destination: URL) throws {
        ensureExists()
        let data = try Data(contentsOf: fileURL)
        try data.write(to: destination, options: .atomic)
    }

    /// 先完整解码校验,再备份并原子替换;任一步失败都不会主动清除原配置。
    static func importConfig(from source: URL) throws {
        let data = try Data(contentsOf: source)
        _ = try JSONDecoder().decode(AppConfigFile.self, from: data)
        ensureExists()
        _ = try backupCurrentConfig()
        try data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .launcherConfigDidWrite, object: nil)
    }

    @discardableResult
    static func backupCurrentConfig() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "apps-\(formatter.string(from: Date()))-\(UUID().uuidString).json"
        let destination = backupsDirectoryURL.appendingPathComponent(name)
        try fm.copyItem(at: fileURL, to: destination)
        return destination
    }

    /// 读取-变更-原子写回。返回是否发生了实际写盘:无变更不写盘且返回 false。
    private static func update(_ mutate: (inout AppConfigFile) -> Bool) -> Bool {
        switch loadConfig() {
        case .failure(let error):
            nlLog("配置读取失败,放弃写回:\(error.localizedDescription)")
            return false
        case .success(var file):
            guard mutate(&file) else { return false }
            return save(file)
        }
    }

    private static func save(_ file: AppConfigFile) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
            NotificationCenter.default.post(name: .launcherConfigDidWrite, object: nil)
            return true
        } catch {
            nlLog("配置写回失败:\(error.localizedDescription)")
            return false
        }
    }

    static func resolve(_ entry: AppEntry) -> ResolvedApp {
        var url: URL?
        if let bundleID = entry.bundleID {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        if url == nil, let path = entry.path, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        }

        let name = entry.name
            ?? url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? url?.deletingPathExtension().lastPathComponent
            ?? entry.bundleID ?? entry.path ?? "未知应用"

        let icon: NSImage
        if let url {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 48, height: 48)
            icon = image
        } else {
            icon = NSImage(named: NSImage.cautionName) ?? NSImage()
        }

        var running = false
        if let url, let bundleID = Bundle(url: url)?.bundleIdentifier {
            running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        return ResolvedApp(name: name, url: url, icon: icon, isRunning: running)
    }
}
