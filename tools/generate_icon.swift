// Renders the BreezeTTS app icon without any external asset pipeline.
//   swiftc -O tools/generate_icon.swift -o build-static/makeicon && ./build-static/makeicon
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build-static/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons live inside a rounded square with a generous margin.
    let inset = size * 0.085
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.235
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(red: 0.36, green: 0.88, blue: 0.84, alpha: 1.0),
        CGColor(red: 0.20, green: 0.56, blue: 0.97, alpha: 1.0),
        CGColor(red: 0.36, green: 0.30, blue: 0.86, alpha: 1.0)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors,
                             locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])

    // soft highlight in the top-left corner
    let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.42),
                                       CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                              locations: [0.0, 1.0])!
    ctx.drawRadialGradient(highlight,
                           startCenter: CGPoint(x: body.minX + body.width * 0.28,
                                                y: body.maxY - body.height * 0.22),
                           startRadius: 0,
                           endCenter: CGPoint(x: body.minX + body.width * 0.28,
                                              y: body.maxY - body.height * 0.22),
                           endRadius: body.width * 0.72,
                           options: [])

    // waveform bars
    let heights: [CGFloat] = [0.18, 0.38, 0.62, 0.88, 0.62, 1.0, 0.72, 0.46, 0.26]
    let barWidth = body.width * 0.052
    let spacing = body.width * 0.036
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    var x = body.midX - totalWidth / 2
    let centerY = body.midY
    let maxBar = body.height * 0.62

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    for h in heights {
        let height = maxBar * h
        let barRect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: barRect,
                           cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2,
                           transform: nil))
        x += barWidth + spacing
    }
    ctx.fillPath()
    ctx.restoreGState()

    // subtle inner rim
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let cache = NSMutableDictionary()
for (name, size) in specs {
    let image: NSImage
    if let cached = cache[size] as? NSImage {
        image = cached
    } else {
        image = makeIcon(size: CGFloat(size))
        cache[size] = image
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: (iconset as NSString).appendingPathComponent(name)))
}

print("iconset written to \(iconset)")
