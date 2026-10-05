// 앱 아이콘 생성 스크립트 (macOS 전용). 사용: swift Tools/make-icon.swift build/AppIcon.icns
// 그라디언트 배경 위에 눈 모양을 그려 .iconset 을 만들고 iconutil 로 .icns 로 묶는다.
import AppKit
import Foundation

let outPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.04, dy: s * 0.04)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.55, blue: 0.62, alpha: 1),
    ])!.draw(in: bg, angle: -60)

    // 눈 (아몬드): 두 개의 곡선
    let w = s * 0.62, h = s * 0.34
    let cx = s / 2, cy = s / 2
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - w / 2, y: cy))
    eye.curve(to: NSPoint(x: cx + w / 2, y: cy),
              controlPoint1: NSPoint(x: cx - w / 5, y: cy + h),
              controlPoint2: NSPoint(x: cx + w / 5, y: cy + h))
    eye.curve(to: NSPoint(x: cx - w / 2, y: cy),
              controlPoint1: NSPoint(x: cx + w / 5, y: cy - h),
              controlPoint2: NSPoint(x: cx - w / 5, y: cy - h))
    eye.close()
    NSColor(white: 1, alpha: 0.95).setFill()
    eye.fill()

    // 홍채 + 동공 + 하이라이트
    NSColor(srgbRed: 0.10, green: 0.14, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - s * 0.13, y: cy - s * 0.13, width: s * 0.26, height: s * 0.26)).fill()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - s * 0.06, y: cy - s * 0.06, width: s * 0.12, height: s * 0.12)).fill()
    NSColor(white: 1, alpha: 0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx + s * 0.02, y: cy + s * 0.04, width: s * 0.05, height: s * 0.05)).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BlinkReminder-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    guard let data = render(px) else { fputs("render failed: \(name)\n", stderr); exit(1) }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}
let out = URL(fileURLWithPath: outPath)
try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
if p.terminationStatus != 0 { fputs("iconutil failed\n", stderr); exit(1) }
print("wrote \(out.path)")
