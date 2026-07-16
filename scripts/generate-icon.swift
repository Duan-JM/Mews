import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift <iconset-dir> <preview-png>\n".utf8))
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let preview = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)

let ink = CGColor(red: 0.122, green: 0.161, blue: 0.216, alpha: 1)
let accent = CGColor(red: 0.851, green: 0.467, blue: 0.024, alpha: 1)
let paper = CGColor(red: 0.969, green: 0.945, blue: 0.910, alpha: 1)

func stroke(_ context: CGContext, color: CGColor, width: CGFloat, draw: (CGMutablePath) -> Void) {
    let path = CGMutablePath()
    draw(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()
}

func writePNG(size: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "MewsIcon", code: 1)
    }

    let scale = CGFloat(size) / 256.0
    context.scaleBy(x: scale, y: scale)

    context.setFillColor(paper)
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256), cornerWidth: 56, cornerHeight: 56, transform: nil))
    context.fillPath()

    stroke(context, color: ink, width: 14) { path in
        path.move(to: CGPoint(x: 72, y: 118))
        path.addCurve(to: CGPoint(x: 128, y: 55), control1: CGPoint(x: 72, y: 80), control2: CGPoint(x: 96, y: 55))
        path.addCurve(to: CGPoint(x: 184, y: 118), control1: CGPoint(x: 160, y: 55), control2: CGPoint(x: 184, y: 80))
        path.addLine(to: CGPoint(x: 184, y: 149))
        path.addCurve(to: CGPoint(x: 128, y: 203), control1: CGPoint(x: 184, y: 181), control2: CGPoint(x: 160, y: 203))
        path.addCurve(to: CGPoint(x: 72, y: 149), control1: CGPoint(x: 96, y: 203), control2: CGPoint(x: 72, y: 181))
        path.closeSubpath()
    }
    stroke(context, color: ink, width: 14) { path in
        path.move(to: CGPoint(x: 83, y: 84))
        path.addLine(to: CGPoint(x: 67, y: 46))
        path.addLine(to: CGPoint(x: 105, y: 64))
        path.move(to: CGPoint(x: 173, y: 84))
        path.addLine(to: CGPoint(x: 189, y: 46))
        path.addLine(to: CGPoint(x: 151, y: 64))
    }
    context.setFillColor(ink)
    context.fillEllipse(in: CGRect(x: 105, y: 120, width: 16, height: 16))
    context.fillEllipse(in: CGRect(x: 135, y: 120, width: 16, height: 16))
    stroke(context, color: ink, width: 10) { path in
        path.move(to: CGPoint(x: 128, y: 144))
        path.addLine(to: CGPoint(x: 128, y: 153))
        path.move(to: CGPoint(x: 112, y: 164))
        path.addCurve(to: CGPoint(x: 144, y: 164), control1: CGPoint(x: 122, y: 173), control2: CGPoint(x: 134, y: 173))
    }
    stroke(context, color: ink, width: 8) { path in
        path.move(to: CGPoint(x: 88, y: 149))
        path.addLine(to: CGPoint(x: 55, y: 149))
        path.move(to: CGPoint(x: 90, y: 169))
        path.addLine(to: CGPoint(x: 60, y: 169))
        path.move(to: CGPoint(x: 168, y: 149))
        path.addLine(to: CGPoint(x: 201, y: 149))
        path.move(to: CGPoint(x: 166, y: 169))
        path.addLine(to: CGPoint(x: 196, y: 169))
    }
    stroke(context, color: accent, width: 12) { path in
        path.move(to: CGPoint(x: 184, y: 151))
        path.addCurve(to: CGPoint(x: 215, y: 186), control1: CGPoint(x: 209, y: 153), control2: CGPoint(x: 220, y: 169))
        path.addCurve(to: CGPoint(x: 173, y: 197), control1: CGPoint(x: 210, y: 205), control2: CGPoint(x: 187, y: 211))
    }

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "MewsIcon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) {
        throw NSError(domain: "MewsIcon", code: 3)
    }
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in files {
    try writePNG(size: size, to: iconset.appendingPathComponent(name))
}
try writePNG(size: 256, to: preview)
