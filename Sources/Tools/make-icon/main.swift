import AppKit

// Draws the RematchBridge icon: a deep-space gradient tile with a white controller glyph.
// Usage: make-icon <output dir>  → AppIcon.iconset/*.png and extension icon16/48/128.png
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/icon")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int, macTile: Bool) -> Data {
  let s = CGFloat(size)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  // macOS icons sit inside a ~80% tile with transparent margin; browser icons fill the square.
  let inset = macTile ? s * 0.1 : 0
  let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
  let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
  if macTile {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
  }
  path.addClip()
  NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.06, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.13, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.75, alpha: 1),
  ])!.draw(in: tile, angle: -50)
  // A few "stars".
  NSColor.white.withAlphaComponent(0.55).setFill()
  for (x, y, r) in [(0.22, 0.78, 0.012), (0.80, 0.82, 0.009), (0.70, 0.22, 0.010), (0.30, 0.25, 0.007), (0.86, 0.50, 0.006)] {
    let c = CGPoint(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y)
    NSBezierPath(ovalIn: CGRect(x: c.x - tile.width * r, y: c.y - tile.width * r, width: tile.width * r * 2, height: tile.width * r * 2)).fill()
  }
  let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.42, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
  if let glyph = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config)
  {
    let g = glyph.size
    glyph.draw(in: CGRect(x: tile.midX - g.width / 2, y: tile.midY - g.height / 2, width: g.width, height: g.height))
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try render(base, macTile: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2, macTile: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
for size in [16, 48, 128] {
  try render(size, macTile: false).write(to: out.appendingPathComponent("icon\(size).png"))
}
print("icons written to \(out.path)")
