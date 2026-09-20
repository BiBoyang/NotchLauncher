import Cocoa

_ = NSApplication.shared
guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
      let left = screen.auxiliaryTopLeftArea,
      let right = screen.auxiliaryTopRightArea else {
    print("NO_NOTCH")
    exit(1)
}
let centerX = screen.frame.origin.x + (left.maxX + right.minX) / 2
let nsY = screen.frame.maxY - 5
let mainHeight = NSScreen.screens[0].frame.maxY
let target = CGPoint(x: centerX, y: mainHeight - nsY)
let original = CGEvent(source: nil)?.location
print("warp to \(target)")
CGWarpMouseCursorPosition(target)
Thread.sleep(forTimeInterval: 1.5)
if let original {
    CGWarpMouseCursorPosition(original)
}
Thread.sleep(forTimeInterval: 1.0)
print("done")
