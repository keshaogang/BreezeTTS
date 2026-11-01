import SwiftUI

/// Everything that has been generated so far, with one-tap replay.
struct HistorySheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        self.history = model.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            if history.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("生成的音频会留在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollHost {
                    VStack(spacing: 6) {
                        ForEach(history.items) { item in
                            row(item)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 460, height: 520)
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack {
            Text("历史")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if !history.items.isEmpty {
                Button {
                    history.clear()
                } label: {
                    Text("清空").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .glassIconButton(size: 26)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func row(_ item: HistoryItem) -> some View {
        let isCurrent = item.url != nil && model.playback.currentURL == item.url
        let isPlaying = isCurrent && model.playback.isPlaying

        return HStack(spacing: 10) {
            Button {
                model.playHistory(item)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(isCurrent ? 0.16 : 0.08)))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "暂停" : "播放")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(isCurrent
                     ? "\(item.timeLabel) · \(model.playback.timeLabel)"
                     : "\(item.timeLabel) · \(item.durationLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            if let url = item.url {
                Button {
                    Paths.reveal(url)
                } label: {
                    Image(systemName: "folder").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                if isCurrent { model.playback.unload() }
                history.delete(item)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.faintFill)
        )
    }
}
