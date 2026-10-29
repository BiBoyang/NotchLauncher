// AppConfig 数据层断言:settings 容错/clamp、reorder 语义、默认值、apps 保留。
//
// 运行:
//   swiftc Sources/NotchLauncher/AppConfig.swift scripts/verify-config.swift \
//     -o /tmp/nl-verify-config && /tmp/nl-verify-config
//
// 通过 exit 0;任一断言失败 exit 1。全部操作在临时目录,不碰真实 apps.json。

import Foundation

func nlLog(_ message: String) {
    FileHandle.standardError.write(Data(("[verify] \(message)\n").utf8))
}

@main
enum VerifyConfig {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print(ok ? "PASS  \(message)" : "FAIL  \(message)")
            if !ok { failures += 1 }
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nl-verify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        AppConfig.directoryOverride = tempDir

        // ---------- 1. 首次运行:空文件 + 默认设置 ----------
        AppConfig.ensureExists()
        guard case .success(let initial) = AppConfig.loadConfig() else {
            print("FAIL  初始加载失败"); exit(1)
        }
        check(initial.apps.isEmpty, "初始 apps 为空")
        check(initial.settings == nil, "初始无 settings 节点")
        check((initial.settings?.resolvedIconsPerRow ?? 6) == 6, "默认每行 6 个")
        check((initial.settings?.resolvedOpenDelay ?? 0.15) == 0.15, "默认展开延迟 0.15s")

        // ---------- 2. 添加 / 去重 ----------
        let safari = AppEntry(name: "Safari", bundleID: "com.apple.Safari", path: "/A/Safari.app")
        let notes = AppEntry(name: "备忘录", bundleID: "com.apple.Notes", path: "/A/Notes.app")
        let music = AppEntry(name: "音乐", bundleID: "com.apple.Music", path: "/A/Music.app")
        check(AppConfig.add(safari), "添加 Safari 成功")
        check(AppConfig.add(notes), "添加备忘录成功")
        check(AppConfig.add(music), "添加音乐成功")
        check(!AppConfig.add(safari), "重复添加被跳过")

        // ---------- 3. reorder:按 identity 全量重排 ----------
        let reversed = [music.identity, notes.identity, safari.identity]
        check(AppConfig.reorder(orderedIdentities: reversed), "reorder 有变化返回 true")
        if case .success(let reordered) = AppConfig.loadConfig() {
            check(reordered.apps.map(\.identity) == reversed, "落盘顺序 = 音乐,备忘录,Safari")
        } else { check(false, "reorder 后加载失败") }

        check(!AppConfig.reorder(orderedIdentities: reversed), "相同顺序 reorder 返回 false 且不写盘")

        // reorder 漏传的条目安全追加末尾,不丢失
        check(AppConfig.reorder(orderedIdentities: [safari.identity, music.identity]), "漏传条目的 reorder 执行")
        if case .success(let partial) = AppConfig.loadConfig() {
            check(
                partial.apps.map(\.identity) == [safari.identity, music.identity, notes.identity],
                "漏传的备忘录被追加到末尾"
            )
        } else { check(false, "漏传 reorder 后加载失败") }

        // ---------- 4. saveSettings 保留 apps ----------
        let settings = LauncherSettings(openDelay: 0.3, closeDelay: 0.6, iconsPerRow: 4)
        check(AppConfig.saveSettings(settings), "saveSettings 写入成功")
        if case .success(let withSettings) = AppConfig.loadConfig() {
            check(withSettings.apps.count == 3, "写设置不影响 apps")
            check(withSettings.settings?.resolvedOpenDelay == 0.3, "展开延迟读回 0.3s")
            check(withSettings.settings?.resolvedIconsPerRow == 4, "每行读回 4 个")
        } else { check(false, "saveSettings 后加载失败") }

        check(!AppConfig.saveSettings(settings), "相同设置不重复写盘")

        // ---------- 5. 手编 JSON:逐字段容错 + clamp ----------
        let malformed = """
        {
          "apps": [{"name":"Safari","bundleID":"com.apple.Safari"}],
          "settings": { "openDelay": "fast", "closeDelay": 5, "iconsPerRow": 2 }
        }
        """
        try? malformed.write(to: AppConfig.fileURL, atomically: true, encoding: .utf8)
        if case .success(let file) = AppConfig.loadConfig() {
            check(file.apps.count == 1, "settings 部分字段非法不影响 apps 加载")
            check(file.settings != nil, "settings 节点仍被解析(逐字段容错)")
            check(file.settings?.resolvedOpenDelay == 0.15, "非法 openDelay(字符串)回退默认 0.15")
            check(file.settings?.resolvedCloseDelay == 2.0, "超范围 closeDelay(5)clamp 到上限 2.0")
            check(file.settings?.resolvedIconsPerRow == 6, "超范围 iconsPerRow(2)回退默认 6")
        } else { check(false, "含非法 settings 字段的文件应能加载") }

        // settings 节点整体类型错误:整体降级,不炸
        let brokenSettings = #"{ "apps": [], "settings": "oops" }"#
        try? brokenSettings.write(to: AppConfig.fileURL, atomically: true, encoding: .utf8)
        if case .success(let file) = AppConfig.loadConfig() {
            check(file.settings == nil, "settings 节点类型错误时降级为 nil")
        } else { check(false, "settings 整体类型错误不应导致加载失败") }

        // 边界值合法:下限 0、每行 10
        let boundary = #"{ "apps": [], "settings": { "openDelay": 0, "iconsPerRow": 10 } }"#
        try? boundary.write(to: AppConfig.fileURL, atomically: true, encoding: .utf8)
        if case .success(let file) = AppConfig.loadConfig() {
            check(file.settings?.resolvedOpenDelay == 0, "openDelay=0 合法(立即展开)")
            check(file.settings?.resolvedIconsPerRow == 10, "iconsPerRow=10 合法(上限)")
        } else { check(false, "边界值文件加载失败") }

        // ---------- 6. 删除幂等 ----------
        AppConfig.ensureExists()
        _ = AppConfig.add(safari)
        check(AppConfig.remove(identity: safari.identity), "删除存在的条目返回 true")
        check(!AppConfig.remove(identity: safari.identity), "重复删除不报错且无变更(幂等)")
        if case .success(let file) = AppConfig.loadConfig() {
            check(file.apps.isEmpty, "删除后 apps 为空且设置结构仍可解析")
        } else { check(false, "删除后加载失败") }

        print(failures == 0 ? "\n===== 数据层验证:ALL PASS =====" : "\n===== 数据层验证:FAIL(\(failures)) =====")
        exit(failures == 0 ? 0 : 1)
    }
}
