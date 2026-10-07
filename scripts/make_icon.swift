import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int, destination: URL) throws {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let scale = side / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.39, blue: 0.34, alpha: 1),
                              ending: NSColor(srgbRed: 0.16, green: 0.65, blue: 0.53, alpha: 1))!
    gradient.draw(in: background, angle: 55)
    NSColor(white: 1, alpha: 0.15).setFill()
    NSBezierPath(roundedRect: NSRect(x: 254, y: 232, width: 514, height: 572), xRadius: 58, yRadius: 58).fill()
    NSColor(srgbRed: 0.96, green: 0.97, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 214, y: 194, width: 514, height: 572), xRadius: 58, yRadius: 58).fill()
    NSColor(srgbRed: 0.08, green: 0.44, blue: 0.37, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 281, y: 278, width: 19, height: 404), xRadius: 9, yRadius: 9).fill()
    for (index, width) in [266.0, 204.0, 242.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 345, y: 607 - Double(index) * 83, width: width, height: 26), xRadius: 13, yRadius: 13).fill()
    }
    let circle = NSBezierPath(ovalIn: NSRect(x: 558, y: 245, width: 168, height: 168))
    NSColor(srgbRed: 0.94, green: 0.73, blue: 0.35, alpha: 1).setFill()
    circle.fill()
    let lens = NSBezierPath(ovalIn: NSRect(x: 597, y: 296, width: 66, height: 66))
    lens.lineWidth = 14
    NSColor(srgbRed: 0.08, green: 0.30, blue: 0.26, alpha: 1).setStroke()
    lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 653, y: 305)); handle.line(to: NSPoint(x: 681, y: 277))
    handle.lineWidth = 14; handle.lineCapStyle = .round; handle.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}
for base in [16, 32, 128, 256, 512] {
    try draw(size: base, destination: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2, destination: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
