import Cocoa

// 冒烟探针:warp 鼠标到刘海触发展开,从 CGWindowList 读面板窗口真实 bounds 做几何断言。
// 单脚本完成 warp + sleep + 断言,避免多脚本并行的时序问题。
//
// usage: smoke-probe.swift <pid> <label> <expectedWidth> <expectedHeight>

_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count == 5,
    let pid = Int(args[1]),
    let expectedW = Double(args[3]),
    let expectedH = Double(args[4])
else {
    print("usage: smoke-probe.swift <pid> <label> <expectedWidth> <expectedHeight>")
    exit(2)
}
let label = args[2]

// ---------- 几何基线(规格常量,独立于实现,勿从源码反推) ----------
// cell 84×92、行距 10、面板 padding:水平 36 / 顶部 notchHeight+12 / 底部 16、刘海 185×32 居中于屏顶。
// 1 app:宽 = max(84+36, 185+140) = 325;高 = 32+12+92+16 = 152
// 7 app:每行最多 6 个,折 2 行;宽 = 6×84+5×10+36 = 590;高 = 32+12+(92+10+92)+16 = 254
// 期望宽高由 smoke.sh 传入;此处固定层级与容差:
let expectedLayer = 33 // NSWindow.Level.statusBar(25) + 8
let tolerance = 2.0 // 断言容差 ±2pt
let settleOpen = 1.2 // 展开收敛:0.15s 延迟 + 0.25s 动画,留足余量
let settleClose = 1.2 // 收起收敛:0.35s 延迟 + 0.2s 动画,留足余量

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print("[\(label)] \(ok ? "PASS" : "FAIL")  \(message)")
    if !ok { failures += 1 }
}

// ---------- 刘海屏探测与 warp 目标(刘海中心动态计算,不写死坐标) ----------
guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
    let left = screen.auxiliaryTopLeftArea,
    let right = screen.auxiliaryTopRightArea
else {
    print("[\(label)] FAIL  未找到刘海屏(safeAreaInsets.top == 0)")
    exit(1)
}
let notchCenterX = screen.frame.origin.x + (left.maxX + right.minX) / 2
// CG 全局坐标原点在主屏左上,Y 轴与 Cocoa 相反
let primaryHeight = NSScreen.screens[0].frame.maxY
let warpTarget = CGPoint(x: notchCenterX, y: primaryHeight - (screen.frame.maxY - 5))

guard let original = CGEvent(source: nil)?.location else {
    print("[\(label)] FAIL  无法读取当前鼠标位置")
    exit(1)
}

// ---------- 触发展开,等动画完成后读窗口 ----------
CGWarpMouseCursorPosition(warpTarget)
Thread.sleep(forTimeInterval: settleOpen)

guard
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
    print("[\(label)] FAIL  CGWindowListCopyWindowInfo 返回空")
    CGWarpMouseCursorPosition(original)
    exit(1)
}

let owned = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
guard let panel = owned.first(where: { ($0[kCGWindowLayer as String] as? Int) == expectedLayer })
    ?? owned.first,
    let boundsDict = panel[kCGWindowBounds as String] as? [String: Any],
    let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
else {
    print("[\(label)] FAIL  未找到 pid=\(pid) 的面板窗口(该 pid 屏上窗口数=\(owned.count))")
    CGWarpMouseCursorPosition(original)
    exit(1)
}

// ---------- 断言:层级 / 尺寸 / 刘海居中 ----------
let layer = panel[kCGWindowLayer as String] as? Int ?? -1
check(layer == expectedLayer, "layer=\(layer)(期望 \(expectedLayer))")

let dw = abs(rect.width - expectedW)
let dh = abs(rect.height - expectedH)
check(
    dw <= tolerance && dh <= tolerance,
    "尺寸 \(Int(rect.width))×\(Int(rect.height))(期望 \(Int(expectedW))×\(Int(expectedH)),容差 ±\(Int(tolerance)))"
)

let dc = abs(rect.midX - notchCenterX)
check(
    dc <= tolerance,
    "水平中心 \(rect.midX) vs 刘海中心 \(notchCenterX),Δ=\(String(format: "%.1f", dc))(容差 ±\(Int(tolerance)))"
)

// ---------- 收尾:鼠标 warp 回原位,等面板收起 ----------
CGWarpMouseCursorPosition(original)
Thread.sleep(forTimeInterval: settleClose)

if failures == 0 {
    print("[\(label)] RESULT: PASS")
    exit(0)
} else {
    print("[\(label)] RESULT: FAIL(\(failures) 项断言未通过)")
    exit(1)
}
