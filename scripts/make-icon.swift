import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.88, alpha: 1).setStroke()
        let wave = NSBezierPath(); wave.lineWidth = 60; wave.lineCapStyle = .round; wave.lineJoinStyle = .round
        wave.move(to: NSPoint(x: 200, y: 512))
        for (x, y) in [(320,512),(400,700),(500,300),(600,620),(680,512),(820,512)] { wave.line(to: NSPoint(x:x, y:y)) }
        wave.stroke()
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 730, y: 710, width: 100, height: 100)).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
