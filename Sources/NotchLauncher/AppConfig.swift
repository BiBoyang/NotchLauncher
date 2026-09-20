import Cocoa

struct AppEntry: Codable {
    var name: String?
    var bundleID: String?
    var path: String?

    /// 条目身份:bundleID 优先,否则 path。去重与删除都按此匹配。
    var identity: String {
        if let bundleID, !bundleID.isEmpty { return "bundleID:" + bundleID }
        return "path:" + (path ?? "")
    }
}

struct AppConfigFile: Codable {
    var apps: [AppEntry]
}

struct ResolvedApp {
    let name: String
    let url: URL?
    let icon: NSImage
    let isRunning: Bool
}

enum LauncherAction {
    case activate(ResolvedApp)
    case dragBegan
    case dragEnded
    case appsChanged
    case removeRequest(identity: String, dropPoint: NSPoint)
    case addApps
    case openConfig
    case reload
    case quit
}

enum AppConfig {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchLauncher", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("apps.json")
    }

    static func ensureExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? #"{"apps": []}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func load() -> Result<[AppEntry], Error> {
        ensureExists()
        do {
            let data = try Data(contentsOf: fileURL)
            return .success(try JSONDecoder().decode(AppConfigFile.self, from: data).apps)
        } catch {
            return .failure(error)
        }
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

    /// 添加条目;已在列表中(按 identity 去重)则跳过,不报错。
    @discardableResult
    static func add(_ entry: AppEntry) -> Bool {
        update { apps in
            guard !apps.contains(where: { $0.identity == entry.identity }) else { return false }
            apps.append(entry)
            return true
        }
    }

    /// 按 identity 删除条目;不存在则视为成功(幂等)。
    @discardableResult
    static func remove(identity: String) -> Bool {
        update { apps in
            let before = apps.count
            apps.removeAll { $0.identity == identity }
            return apps.count != before
        }
    }

    /// 读取-变更-原子写回。mutate 返回是否有实际变更;无变更不写盘。
    private static func update(_ mutate: (inout [AppEntry]) -> Bool) -> Bool {
        switch load() {
        case .failure(let error):
            nlLog("配置读取失败,放弃写回:\(error.localizedDescription)")
            return false
        case .success(var apps):
            guard mutate(&apps) else { return true }
            return save(apps)
        }
    }

    private static func save(_ apps: [AppEntry]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AppConfigFile(apps: apps))
            try data.write(to: fileURL, options: .atomic)
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
