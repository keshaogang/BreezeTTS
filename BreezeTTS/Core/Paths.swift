import AppKit
import Foundation

/// Every on-disk location the app touches. The app is not sandboxed, so these
/// live under `~/Library/Application Support/<folderName>`.
///
/// 精简版和完整版必须各用各的目录，否则两个 App 会共用模型、音色和历史，
/// 装在一起时互相污染，也没法模拟「新用户第一次打开」。
enum Paths {
    static let folderName: String = {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".lite") ? "BreezeTTS Lite" : "BreezeTTS"
    }()

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static var models: URL { appSupport.appendingPathComponent("models", isDirectory: true) }
    static var exports: URL { appSupport.appendingPathComponent("exports", isDirectory: true) }
    static var voices: URL { appSupport.appendingPathComponent("voices", isDirectory: true) }
    static var recordings: URL { appSupport.appendingPathComponent("recordings", isDirectory: true) }
    /// Scratch space for the file the transport plays when an export failed.
    static var cache: URL { appSupport.appendingPathComponent("cache", isDirectory: true) }
    /// 听书角色的基准参考音色（每个角色一段 wav）。
    static var refs: URL { appSupport.appendingPathComponent("story-refs", isDirectory: true) }

    static var historyFile: URL { appSupport.appendingPathComponent("history.json") }
    static var voicesFile: URL { appSupport.appendingPathComponent("voices.json") }

    static var defaultModelDirectory: URL { models }

    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for url in [appSupport, models, exports, voices, recordings, cache, refs] {
            if !fm.fileExists(atPath: url.path) {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } catch {
                    NSLog("BreezeTTS: cannot create \(url.path): \(error.localizedDescription)")
                    return false
                }
            }
        }
        return true
    }

    static func size(of url: URL) -> Int64 {
        // 别用 url.resourceValues(forKeys:)：NSURL 会缓存取到的属性，
        // 下载过程中反复取同一个 URL 的大小会一直返回首次的值（0），
        // 表现出来就是「文件在长、进度条永远 0% · 0 KB」。
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? NSNumber else { return 0 }
        return bytes.int64Value
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension Int64 {
    var humanBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: self)
    }

    var humanGB: String {
        String(format: "%.1f GB", Double(self) / 1_073_741_824.0)
    }
}

extension Double {
    /// "3.2 MB/s"
    var humanSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(max(0, self))) + "/s"
    }

    /// "12 分" / "1 小时 8 分"
    var humanDuration: String {
        let total = Int(max(0, self).rounded())
        if total < 60 { return "不到 1 分钟" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
