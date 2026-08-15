// Renders Herald's app icon: a serifed "H" on white, pre-masked to the macOS squircle.
// usage: swift scripts/generate-app-icon.swift Herald/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset"
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }
    // macOS icon grid: the artwork occupies ~80% of the canvas; squircle radius ≈ 22.37% of that.
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft shadow like system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s*0.012), blur: s*0.03, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // Hairline edge for contrast on white desktops.
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(max(1, s*0.004)); ctx.strokePath()
    // The H — a heavy serif, near-black, optically centred.
    let fontSize = rect.height * 0.74
    let font = NSFont(name: "TimesNewRomanPS-BoldMT", size: fontSize)
        ?? NSFont(name: "Times-Bold", size: fontSize)!
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 1)]
    let str = NSAttributedString(string: "H", attributes: attrs)
    let size = str.size()
    // Optically centre the cap height (not the full line box) in the tile.
    let capHeight = font.capHeight
    let baselineY = rect.midY - capHeight / 2
    let x = rect.midX - size.width / 2
    // NSAttributedString.draw(at:) places the line box's bottom (baseline + descender) at y.
    str.draw(at: NSPoint(x: x, y: baselineY + font.descender))
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scale) in sizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! render(px: px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(outDir)")
