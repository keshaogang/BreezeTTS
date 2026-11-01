// Capture a single window by owner name, straight from the window server.
// Used because the offscreen ImageRenderer path cannot rasterise AppKit-backed
// views (TextEditor) or Liquid Glass.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let ownerMatch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BreezeTTS"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/window.png"

func windows(onScreenOnly: Bool) -> [[String: Any]] {
    let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}

var candidate: CGWindowID?
for entry in windows(onScreenOnly: true) + windows(onScreenOnly: false) {
    guard let owner = entry[kCGWindowOwnerName as String] as? String,
          owner.contains(ownerMatch),
          let number = entry[kCGWindowNumber as String] as? Int,
          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 400 else { continue }
    let layer = entry[kCGWindowLayer as String] as? Int ?? 0
    if layer != 0 { continue }
    print("window #\(number) bounds=\(bounds)")
    candidate = CGWindowID(number)
    break
}

guard let id = candidate else {
    FileHandle.standardError.write(Data("no window found for \(ownerMatch)\n".utf8))
    exit(2)
}

print("WINDOW_ID=\(id)")
exit(0)
