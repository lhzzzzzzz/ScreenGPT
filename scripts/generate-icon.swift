import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon() {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let paper = rounded(CGRect(x: 64, y: 64, width: 896, height: 896), radius: 232)
    NSGradient(colors: [color(0xf8fffd), color(0xe8f6f4)])!
        .draw(in: paper, angle: -45)

    color(0xffffff, alpha: 0.72).setFill()
    NSBezierPath(ovalIn: CGRect(x: 287, y: 287, width: 450, height: 450)).fill()

    let corners = NSBezierPath()
    corners.lineWidth = 30
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    // Top-left, top-right, bottom-left, and bottom-right capture brackets.
    corners.move(to: CGPoint(x: 405, y: 670)); corners.line(to: CGPoint(x: 368, y: 670)); corners.curve(to: CGPoint(x: 344, y: 646), controlPoint1: CGPoint(x: 344, y: 670), controlPoint2: CGPoint(x: 344, y: 658)); corners.line(to: CGPoint(x: 344, y: 609))
    corners.move(to: CGPoint(x: 619, y: 670)); corners.line(to: CGPoint(x: 656, y: 670)); corners.curve(to: CGPoint(x: 680, y: 646), controlPoint1: CGPoint(x: 680, y: 658), controlPoint2: CGPoint(x: 680, y: 670)); corners.line(to: CGPoint(x: 680, y: 609))
    corners.move(to: CGPoint(x: 344, y: 405)); corners.line(to: CGPoint(x: 344, y: 368)); corners.curve(to: CGPoint(x: 368, y: 344), controlPoint1: CGPoint(x: 344, y: 344), controlPoint2: CGPoint(x: 356, y: 344)); corners.line(to: CGPoint(x: 405, y: 344))
    corners.move(to: CGPoint(x: 680, y: 405)); corners.line(to: CGPoint(x: 680, y: 368)); corners.curve(to: CGPoint(x: 656, y: 344), controlPoint1: CGPoint(x: 680, y: 344), controlPoint2: CGPoint(x: 668, y: 344)); corners.line(to: CGPoint(x: 619, y: 344))
    color(0x0c8589).setStroke()
    corners.stroke()

    let sparkle = NSBezierPath()
    sparkle.move(to: CGPoint(x: 512, y: 642))
    sparkle.curve(to: CGPoint(x: 382, y: 512), controlPoint1: CGPoint(x: 488, y: 536), controlPoint2: CGPoint(x: 463, y: 536))
    sparkle.curve(to: CGPoint(x: 512, y: 382), controlPoint1: CGPoint(x: 488, y: 488), controlPoint2: CGPoint(x: 488, y: 463))
    sparkle.curve(to: CGPoint(x: 642, y: 512), controlPoint1: CGPoint(x: 536, y: 488), controlPoint2: CGPoint(x: 561, y: 488))
    sparkle.curve(to: CGPoint(x: 512, y: 642), controlPoint1: CGPoint(x: 536, y: 536), controlPoint2: CGPoint(x: 536, y: 561))
    let teal = NSGradient(colors: [color(0x16b8b2), color(0x087f89)])!
    teal.draw(in: sparkle, angle: -45)

    let glint = NSBezierPath()
    glint.move(to: CGPoint(x: 694, y: 747))
    glint.curve(to: CGPoint(x: 646, y: 699), controlPoint1: CGPoint(x: 685, y: 708), controlPoint2: CGPoint(x: 685, y: 708))
    glint.curve(to: CGPoint(x: 694, y: 651), controlPoint1: CGPoint(x: 685, y: 738), controlPoint2: CGPoint(x: 685, y: 738))
    glint.curve(to: CGPoint(x: 742, y: 699), controlPoint1: CGPoint(x: 703, y: 690), controlPoint2: CGPoint(x: 703, y: 690))
    glint.curve(to: CGPoint(x: 694, y: 747), controlPoint1: CGPoint(x: 703, y: 708), controlPoint2: CGPoint(x: 703, y: 708))
    color(0x48c9c0).setFill(); glint.fill()

    color(0x57cfc4).setFill()
    NSBezierPath(ovalIn: CGRect(x: 393, y: 383, width: 24, height: 24)).fill()
    _ = canvas
}

func pngData(size: Int) -> Data {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create bitmap context at \(size) px")
    }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = context.makeImage() else {
        fatalError("Could not render icon at \(size) px")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon at \(size) px")
    }
    return data
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let data = pngData(size: size)
    try data.write(to: resources.appendingPathComponent("AppIcon-\(size).png"))
}

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in iconSizes {
    try pngData(size: size).write(to: iconset.appendingPathComponent(name))
}

// ICNS stores standard PNG payloads in size-tagged chunks. Building this small
// container directly keeps generation self-contained on fresh macOS systems.
var icns = Data("icns".utf8)
func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
}
let icnsEntries: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)
]
var chunks = Data()
for (type, size) in icnsEntries {
    let payload = try Data(contentsOf: resources.appendingPathComponent("AppIcon-\(size).png"))
    chunks.append(Data(type.utf8))
    appendUInt32(UInt32(payload.count + 8), to: &chunks)
    chunks.append(payload)
}
appendUInt32(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)
try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
