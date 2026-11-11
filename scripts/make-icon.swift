import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let background = NSBezierPath(roundedRect: NSRect(x: s * 0.045, y: s * 0.045, width: s * 0.91, height: s * 0.91), xRadius: s * 0.21, yRadius: s * 0.21)
    NSGradient(colors: [NSColor(red: 0.17, green: 0.28, blue: 0.34, alpha: 1), NSColor(red: 0.055, green: 0.1, blue: 0.14, alpha: 1)])!.draw(in: background, angle: -80)
    NSColor(white: 1, alpha: 0.12).setStroke(); background.lineWidth = max(1, s * 0.006); background.stroke()
    let plug = NSBezierPath(roundedRect: NSRect(x: s * 0.365, y: s * 0.64, width: s * 0.27, height: s * 0.20), xRadius: s * 0.025, yRadius: s * 0.025)
    NSGradient(colors: [.white, NSColor(white: 0.61, alpha: 1)])!.draw(in: plug, angle: 0)
    for x: CGFloat in [0.408, 0.525] {
        NSColor(red: 0.10, green: 0.18, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * x, y: s * 0.71, width: s * 0.064, height: s * 0.065), xRadius: s * 0.008, yRadius: s * 0.008).fill()
    }
    let drive = NSBezierPath(roundedRect: NSRect(x: s * 0.285, y: s * 0.18, width: s * 0.43, height: s * 0.49), xRadius: s * 0.065, yRadius: s * 0.065)
    NSGradient(colors: [NSColor(red: 0.40, green: 0.95, blue: 0.77, alpha: 1), NSColor(red: 0.09, green: 0.67, blue: 0.55, alpha: 1)])!.draw(in: drive, angle: -60)
    NSColor(white: 1, alpha: 0.35).setStroke(); drive.lineWidth = s * 0.006; drive.stroke()
    if let symbol = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: s * 0.24, weight: .semibold)) {
        symbol.draw(in: NSRect(x: s * 0.37, y: s * 0.30, width: s * 0.26, height: s * 0.26), from: .zero, operation: .sourceOver, fraction: 0.85)
    }
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [Int: [String]] = [16: ["icon_16x16"], 32: ["icon_16x16@2x", "icon_32x32"], 64: ["icon_32x32@2x"], 128: ["icon_128x128"], 256: ["icon_128x128@2x", "icon_256x256"], 512: ["icon_256x256@2x", "icon_512x512"], 1024: ["icon_512x512@2x"]]
    for name in names[pixels]! { try png.write(to: directory.appendingPathComponent(name + ".png")) }
}
