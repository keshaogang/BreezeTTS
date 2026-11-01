import AppKit
import SwiftUI

/// 配对卡片：首次引导和设置里共用。
///
/// 完整版把 Mac 当作 iPhone / iPad 的算力，扫码后手机上就有同一套音色、
/// 历史、听书和对话。精简版没有这些能力，也就没有这台服务器——所以
/// 「能配对」本身就是完整版的标识。
struct PairingCard: View {
    @ObservedObject var model: AppModel
    /// 引导页里空间有限，收得紧一点。
    var compact = false

    @State private var tick = 0
    @State private var copied = false

    private var port: UInt16 {
        RemoteServer.shared.boundPort == 0 ? 4747 : RemoteServer.shared.boundPort
    }

    private var payload: String {
        LANAddress.bindPayload(port: port)
    }

    private var devices: [RemoteServer.Client] {
        _ = tick
        return RemoteServer.shared.pairedDevices
    }

    private var onlineCount: Int {
        devices.filter(\.isOnline).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header

            if model.settings.remoteServer {
                HStack(alignment: .top, spacing: compact ? 16 : 22) {
                    qrCode
                    details
                }
                devicesSection
                actions
            } else {
                disabledHint
            }
        }
        .padding(compact ? 0 : 18)
        .background {
            if compact {
                EmptyView()
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.faintFill)
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            tick &+= 1
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Appearance.accent)
                Text(compact ? "让 iPhone / iPad 加入" : "连接 iPhone / iPad")
                    .font(.system(size: compact ? 20 : 14, weight: .semibold))
                if onlineCount > 0 {
                    Pill(text: "\(onlineCount) 台在线", emphasis: true)
                }
            }
            Text(compact
                 ? "用手机上的 BreezeSpeak 扫这个码，就能共用这台 Mac 的音色、历史、听书和对话。暂时不连也行，之后在设置里随时补上。"
                 : "手机上打开 BreezeSpeak →「连接 Mac」→ 扫下面这个码。连上以后，音色、历史、听书和对话都跟这台 Mac 保持一致。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    private var qrCode: some View {
        QRCodeView(content: payload, size: compact ? 150 : 168)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("配对码")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(groupedCode)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .tracking(2)
                    Button {
                        copy("\(LANAddress.primaryIPv4() ?? ""):\(port)  配对码 \(RemoteServer.pairingCode)")
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("复制地址和配对码")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("本机地址")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let ip = LANAddress.primaryIPv4() {
                    // 用 verbatim：否则 SwiftUI 会按本地化把端口写成 "4,747"。
                    Text(verbatim: "\(ip):\(port)")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("未检测到局域网地址")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if LANAddress.primaryIPv4() == nil {
                Text("连上 Wi-Fi 或插上网线后再试一次。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var devicesSection: some View {
        if devices.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "hourglass")
                    .font(.system(size: 10))
                Text("还没有设备连上来。等待扫码…")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(devices, id: \.address) { client in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(client.isOnline ? Appearance.accent : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text(client.name)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(client.address)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(client.isOnline ? "在线" : "已离线")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                copy(payload)
                model.statusLine = "配对信息已复制"
            } label: {
                Text(copied ? "已复制" : "复制配对信息")
            }
            .quietPill()

            Button {
                RemoteServer.shared.forgetDevices()
                model.statusLine = "已清除这台 Mac 上记录的设备"
            } label: {
                Text("清除记录")
            }
            .quietPill()
            .disabled(devices.isEmpty)
            .opacity(devices.isEmpty ? 0.4 : 1)

            Spacer(minLength: 0)
        }
    }

    private var disabledHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("iPhone 连接已关闭")
                    .font(.system(size: 12.5, weight: .medium))
                Text("打开后手机才能连上这台 Mac。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                model.settings.remoteServer = true
            } label: {
                Text("打开")
            }
            .quietPill()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill))
    }

    // MARK: - Helpers

    private var groupedCode: String {
        let code = RemoteServer.pairingCode
        guard code.count == 6 else { return code }
        let head = code.prefix(3)
        let tail = code.suffix(3)
        return "\(head) \(tail)"
    }

    private func copy(_ string: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(string, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}
