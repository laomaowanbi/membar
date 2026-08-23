import AppKit

// MemBar 应用图标生成：1024x1024
// 深色圆角底 + 绿→蓝→红渐变进度条（与菜单栏进度条呼应）

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// ---- 背景：深色圆角方形（macOS 风格圆角 ~22.5%）----
let bgRect = NSRect(x: 0, y: 0, width: side, height: side)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: side * 0.225, yRadius: side * 0.225)
let bgGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
])!
bgGrad.draw(in: bg, angle: -90)

// 底部微光
let glowRect = NSRect(x: 140, y: 150, width: 744, height: 520)
let glow = NSBezierPath(roundedRect: glowRect, xRadius: 120, yRadius: 120)
NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.0, alpha: 0.10).setFill()
glow.fill()

// ---- 轨道 ----
let trackRect = NSRect(x: 150, y: 430, width: 724, height: 164)
let track = NSBezierPath(roundedRect: trackRect, xRadius: 82, yRadius: 82)
NSColor(calibratedWhite: 0.30, alpha: 1.0).setFill()
track.fill()
// 轨道内阴影边
let trackIn = NSBezierPath(roundedRect: trackRect.insetBy(dx: 6, dy: 6), xRadius: 78, yRadius: 78)
NSColor(calibratedWhite: 0.24, alpha: 1.0).setFill()
trackIn.fill()

// ---- 填充 65%：绿 → 蓝 → 红 ----
let fillW = trackRect.width * 0.65
let fillRect = NSRect(x: trackRect.minX + 6, y: trackRect.minY + 6, width: fillW - 6, height: trackRect.height - 12)
let fill = NSBezierPath(roundedRect: fillRect, xRadius: 76, yRadius: 76)
let fillGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.90, blue: 0.50, alpha: 1),   // 绿
    NSColor(calibratedRed: 0.10, green: 0.60, blue: 1.00, alpha: 1),   // 蓝
    NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.28, alpha: 1)    // 红
])!
fillGrad.draw(in: fill, angle: 0)

// 填充顶部高光
let hiRect = NSRect(x: fillRect.minX + 18, y: fillRect.minY + 16, width: fillRect.width - 36, height: 26)
let hi = NSBezierPath(roundedRect: hiRect, xRadius: 13, yRadius: 13)
NSColor(calibratedWhite: 1.0, alpha: 0.22).setFill()
hi.fill()

// ---- 底部文字区：三条小刻度线（记忆条风格）----
func tick(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
    let r = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h/2, yRadius: h/2)
    c.setFill()
    r.fill()
}
tick(150, 270, 120, 44, NSColor(calibratedRed: 0.25, green: 0.90, blue: 0.50, alpha: 0.9))
tick(286, 270, 120, 44, NSColor(calibratedRed: 0.10, green: 0.60, blue: 1.00, alpha: 0.9))
tick(422, 270, 120, 44, NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.28, alpha: 0.9))

image.unlockFocus()

// 保存 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("无法生成 PNG")
}
let out = URL(fileURLWithPath: "/tmp/membar_icon/AppIcon-1024.png")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: out)
print("图标已生成: \(out.path)")
