// Рисует иконку приложения и собирает AppIcon.iconset
// Использование: make_icon <папка-вывода>
import Cocoa

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)

    // фон
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    let darkRed = NSColor(red: 0.74, green: 0.07, blue: 0.12, alpha: 1)
    NSGradient(colors: [darkRed,
                        NSColor(red: 1.00, green: 0.33, blue: 0.28, alpha: 1)])!
        .draw(in: body, angle: 90)

    let c = NSPoint(x: 512, y: 512)
    let r: CGFloat = 255

    // две дуги-стрелки синхронизации
    NSColor.white.setStroke(); NSColor.white.setFill()
    for start in [CGFloat(25), 205] {
        let end = start + 120
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: end)
        arc.lineWidth = 58; arc.lineCapStyle = .round
        arc.stroke()
        // наконечник в конце дуги (движение против часовой стрелки)
        let a = end * .pi / 180
        let p = NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        let t = NSPoint(x: -sin(a), y: cos(a))   // касательная
        let n = NSPoint(x: cos(a), y: sin(a))    // радиус
        let head = NSBezierPath()
        head.move(to: NSPoint(x: p.x + t.x * 105, y: p.y + t.y * 105))
        head.line(to: NSPoint(x: p.x + n.x * 85,  y: p.y + n.y * 85))
        head.line(to: NSPoint(x: p.x - n.x * 85,  y: p.y - n.y * 85))
        head.close(); head.fill()
    }

    // диск в центре
    let drive = NSBezierPath(roundedRect: NSRect(x: c.x - 125, y: c.y - 80, width: 250, height: 160),
                             xRadius: 36, yRadius: 36)
    NSColor.white.setFill(); drive.fill()
    NSColor(red: 0.74, green: 0.07, blue: 0.12, alpha: 0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: c.x - 95, y: c.y - 52, width: 120, height: 22),
                 xRadius: 11, yRadius: 11).fill()
    darkRed.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x + 55, y: c.y - 55, width: 30, height: 30)).fill()

    // буква «Я» в правом нижнем углу
    let badge = NSRect(x: 712, y: 128, width: 180, height: 180)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badge).fill()
    let letter = "Я" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 135, weight: .heavy),
        .foregroundColor: darkRed]
    let ls = letter.size(withAttributes: attrs)
    letter.draw(at: NSPoint(x: badge.midX - ls.width / 2, y: badge.midY - ls.height / 2),
                withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in files {
    try render(px).write(to: set.appendingPathComponent(name + ".png"))
}
