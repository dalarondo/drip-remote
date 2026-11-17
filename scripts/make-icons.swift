// Draws the app icon and the menu bar glyph.
// Usage: swift scripts/make-icons.swift DripRemote/Resources/Assets.xcassets/AppIcon.appiconset DripRemote/Resources
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// Drip Remote mark, in a 1024 × 1024 design space (y grows downwards): the camera island as a
// pill, and a drop pouring out of it on a funnel-shaped neck.
func markPaths() -> [CGPath] {
    let pill = CGPath(roundedRect: CGRect(x: 362, y: 190, width: 300, height: 84), cornerWidth: 42, cornerHeight: 42, transform: nil)
    // A teardrop: round at the bottom, tapering up into the stream.
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: 512, y: 372))
    drop.addCurve(to: CGPoint(x: 680, y: 650), control1: CGPoint(x: 548, y: 452), control2: CGPoint(x: 680, y: 520))
    drop.addArc(center: CGPoint(x: 512, y: 650), radius: 168, startAngle: 0, endAngle: .pi, clockwise: false)
    drop.addCurve(to: CGPoint(x: 512, y: 372), control1: CGPoint(x: 344, y: 520), control2: CGPoint(x: 476, y: 452))
    drop.closeSubpath()
    // The stream: as wide as the island's flat bottom where it leaves it, thinning to a trickle.
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 440, y: 262))
    neck.addCurve(to: CGPoint(x: 499, y: 392), control1: CGPoint(x: 440, y: 330), control2: CGPoint(x: 499, y: 344))
    neck.addLine(to: CGPoint(x: 499, y: 440))
    neck.addLine(to: CGPoint(x: 525, y: 440))
    neck.addLine(to: CGPoint(x: 525, y: 392))
    neck.addCurve(to: CGPoint(x: 584, y: 262), control1: CGPoint(x: 525, y: 344), control2: CGPoint(x: 584, y: 330))
    neck.closeSubpath()
    return [pill, neck, drop]
}

func render(size: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    draw(ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(path)")
}

let red = CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)

func appIcon(_ ctx: CGContext) {
    // macOS icon grid: an 824-pt rounded square inside the 1024 canvas.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1))
    ctx.fillPath()
    ctx.addPath(tile)
    ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    ctx.setLineWidth(6)
    ctx.strokePath()
    for path in markPaths() {
        ctx.addPath(path)
        ctx.setFillColor(red)
        ctx.fillPath()
    }
    // A soft highlight so the drop reads as liquid.
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 414, y: 580, width: 58, height: 96), transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.fillPath()
}

// Menu bar glyph: the same mark, black on transparent (used as a template image).
func menuBarGlyph(_ ctx: CGContext) {
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.55, y: 1.55)
    ctx.translateBy(x: -512, y: -505)
    for path in markPaths() {
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
    }
}

let args = CommandLine.arguments
let iconDir = args[1], resources = args[2]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(size: size, draw: appIcon), to: "\(iconDir)/icon_\(size)x\(size).png")
}
// One 36-px image; the app shows it at 18 pt, so it is sharp on Retina displays.
write(render(size: 36, draw: menuBarGlyph), to: "\(resources)/MenuBarIcon.png")
print("icons written")
