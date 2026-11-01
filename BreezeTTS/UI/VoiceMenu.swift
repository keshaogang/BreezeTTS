import SwiftUI

/// The second-level menu behind the toolbar's voice button: one single-select
/// list (neutral default + saved voices), then a way into full management.
struct VoiceMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: VoiceStore
    @Binding var isPresented: Bool
    var onManage: () -> Void

    init(model: AppModel, isPresented: Binding<Bool>, onManage: @escaping () -> Void) {
        self.model = model
        self._isPresented = isPresented
        self.onManage = onManage
        self.store = model.voices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            voiceSection

            if model.canRestoreInstruction {
                separator
                restoreRow
            }

            separator
            manageRow
        }
        .padding(.vertical, 9)
        .frame(width: 298)
    }

    // MARK: - Single-select voice list

    private var voiceList: [VoiceMeta] {
        let stored = store.voices
        if stored.isEmpty, RenderMode.isPreview {
            // The snapshot harness needs a populated list to check the layout.
            return [
                VoiceMeta(name: "我的声音", audioPath: "/tmp/preview-a.wav",
                          refText: "这是参考音频。", durationSeconds: 6.4),
                VoiceMeta(name: "旁白男声", audioPath: "/tmp/preview-b.wav",
                          refText: "夜色渐深。", durationSeconds: 8.1),
                VoiceMeta(name: "温柔女声", audioPath: "",
                          refText: "", durationSeconds: 0,
                          instruction: "语速偏慢，低声，带一点笑意。"),
            ]
        }
        return stored
    }

    /// 统一的单选状态：克隆/文字音色/中性默认三选一。
    private func isSelected(_ voice: VoiceMeta) -> Bool {
        if voice.isTextVoice {
            return model.selectedVoiceID == nil && model.activeTextVoice?.id == voice.id
        }
        return model.selectedVoiceID == voice.id
    }

    private var neutralSelected: Bool {
        model.selectedVoiceID == nil && model.activeTextVoice == nil
            && model.settings.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "音色")
                .padding(.horizontal, 12)
                .padding(.bottom, 3)

            neutralRow

            ForEach(voiceList) { voice in
                voiceRow(voice)
            }

            if voiceList.count > 7 {
                Text("还有 \(voiceList.count - 7) 个，见音色管理")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
    }

    private var neutralRow: some View {
        Button {
            model.resetToNeutralVoice()
            isPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text("中性自然")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("不加修饰的默认声线")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if neutralSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(neutralSelected ? Theme.softFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func voiceRow(_ voice: VoiceMeta) -> some View {
        let selected = isSelected(voice)
        return Button {
            if selected {
                // 再点一次回到中性默认。
                model.resetToNeutralVoice()
            } else if voice.isTextVoice {
                model.applyTextVoice(voice)
            } else {
                model.selectCloneVoice(voice)
            }
            isPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: voice.isTextVoice
                        ? "wand.and.stars"
                        : (selected ? "person.crop.circle.fill" : "person.crop.circle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(voice.isTextVoice
                         ? ((voice.instruction ?? "").isEmpty ? "文字音色" : String((voice.instruction ?? "").prefix(18)))
                         : ((voice.instruction ?? "").isEmpty
                            ? String(format: "克隆 · %.1fs", voice.durationSeconds)
                            : String((voice.instruction ?? "").prefix(18))))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.softFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Chrome

    private var separator: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    /// Shown only when a preset replaced hand-written wording.
    private var restoreRow: some View {
        Button {
            model.restoreCustomInstruction()
            isPresented = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 15)
                Text("恢复自定义指令")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 6)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var manageRow: some View {
        Button {
            isPresented = false
            onManage()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                Text("音色管理")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
