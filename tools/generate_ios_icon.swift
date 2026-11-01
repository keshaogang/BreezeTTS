// Renders the iOS app icon set (light / dark / tinted) with no external asset pipeline.
//   swiftc -O tools/generate_ios_icon.swift -o /tmp/makeiosicon && /tmp/makeiosicon BreezeTTS-iOS/Assets.xcassets
//
// iOS icons must be full-bleed squares with no corner radius and no alpha channel:
// the system applies its own mask, and any transparency renders as black.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BreezeTTS-iOS/Assets.xcassets"
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

enum Style { case light, dark, tinted }

func gradientColors(_ style: Style) -> [CGColor] {
    switch style {
    case .light:
        return [
            CGColor(red: 0.36, green: 0.88, blue: 0.84, alpha: 1.0),
            CGColor(red: 0.20, green: 0.56, blue: 0.97, alpha: 1.0),
            CGColor(red: 0.36, green: 0.30, blue: 0.86, alpha: 1.0),
        ]
    case .dark:
        return [
            CGColor(red: 0.13, green: 0.30, blue: 0.58, alpha: 1.0),
            CGColor(red: 0.09, green: 0.16, blue: 0.36, alpha: 1.0),
            CGColor(red: 0.20, green: 0.16, blue: 0.42, alpha: 1.0),
        ]
    case .tinted:
        return [
            CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1.0),
            CGColor(red: 0.56, green: 0.56, blue: 0.56, alpha: 1.0),
            CGColor(red: 0.34, green: 0.34, blue: 0.34, alpha: 1.0),
        ]
    }
}

func makeIcon(size: Int, style: Style) -> CGImage? {
    let width = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: width, height: width)

    let gradient = CGGradient(colorsSpace: space,
                              colors: gradientColors(style) as CFArray,
                              locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    let highlight = CGGradient(colorsSpace: space,
                               colors: [CGColor(red: 1, green: 1, blue: 1, alpha: style == .dark ? 0.18 : 0.38),
                                        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                               locations: [0.0, 1.0])!
    let center = CGPoint(x: width * 0.28, y: width * 0.78)
    ctx.drawRadialGradient(highlight,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: width * 0.78,
                           options: [])

    // Waveform, slightly larger than the macOS icon because iOS has no outer margin.
    let heights: [CGFloat] = [0.18, 0.38, 0.62, 0.88, 0.62, 1.0, 0.72, 0.46, 0.26]
    let barWidth = width * 0.058
    let spacing = width * 0.040
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    var x = rect.midX - totalWidth / 2
    let maxBar = width * 0.56
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    for h in heights {
        let height = maxBar * h
        let barRect = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: barRect,
                           cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                           transform: nil))
        x += barWidth + spacing
    }
    ctx.fillPath()

    return ctx.makeImage()
}

func write(_ style: Style, name: String, size: Int = 1024) {
    guard let image = makeIcon(size: size, style: style) else {
        print("failed to render \(name)")
        return
    }
    let url = URL(fileURLWithPath: (iconset as NSString).appendingPathComponent(name))
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("failed to open \(name)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name)")
}

write(.light, name: "icon-light.png")
write(.dark, name: "icon-dark.png")
write(.tinted, name: "icon-tinted.png")

let contents = """
{
  "images" : [
    {
      "filename" : "icon-light.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "icon-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "icon-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try? contents.write(toFile: (iconset as NSString).appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8)
print("iconset written to \(iconset)")
