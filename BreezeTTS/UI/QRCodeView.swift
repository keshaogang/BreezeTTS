import AppKit
import CoreImage
import SwiftUI

/// 局域网 IPv4（优先 en0/en1），给扫码绑定用。
enum LANAddress {
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: String)] = []
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254") { continue }
            candidates.append((name, ip))
        }
        // en0 优先（Wi-Fi/有线主网卡），其次 en1…
        for prefix in ["en0", "en1", "en2"] {
            if let hit = candidates.first(where: { $0.name == prefix }) { address = hit.ip; break }
        }
        if address == nil { address = candidates.first?.ip }
        return address
    }

    /// 所有候选局域网 IPv4（en0 优先）。Mac 可能有多个网卡（有线 + Wi-Fi +
    /// 手机热点），手机不一定在主网段上，所以二维码带上完整候选列表，
    /// iOS 逐个尝试直到有应答。
    static func allIPv4s() -> [String] {
        var candidates: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254") { continue }
            candidates.append((name, ip))
        }
        let order = ["en0", "en1", "en2", "en3", "en4", "en5"]
        return candidates.sorted { a, b in
            let ai = order.firstIndex(of: a.name) ?? order.count
            let bi = order.firstIndex(of: b.name) ?? order.count
            if ai != bi { return ai < bi }
            return a.name < b.name
        }.map { $0.ip }
    }

    /// 扫码绑定内容：host / 候选地址列表 / port / token / 版本标识。
    static func bindPayload(port: UInt16) -> String {
        let hosts = allIPv4s()
        let token = RemoteServer.pairingCode
        var payload: [String: Any] = [
            "host": hosts.first ?? "",
            "port": Int(port),
            "token": token,
            "edition": "full",
            "app": "BreezeTTS",
            "v": 2,
        ]
        if hosts.count > 1 { payload["hosts"] = hosts }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// SwiftUI 二维码（CoreImage 生成，单色自适应明暗主题）。
struct QRCodeView: View {
    let content: String
    var size: CGFloat = 180

    var body: some View {
        if let image = qrImage() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("绑定二维码")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.faintFill)
                .frame(width: size, height: size)
        }
    }

    private func qrImage() -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        // CoreImage 输出是「黑码点 + 透明背景」，直接当模板渲染会在深色主题下
        // 变成白色隐形。显式铺白底再画黑码，任何主题下都保持可扫的黑白对比。
        let margin = 24
        let side = cg.width + margin * 2
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSColor.black.setFill()
        NSBitmapImageRep(cgImage: cg).draw(in: NSRect(x: margin, y: margin,
                                                      width: cg.width, height: cg.height))
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
