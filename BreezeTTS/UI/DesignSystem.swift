import SwiftUI

/// Rendering switches shared by the snapshot harness.
enum RenderMode {
    /// `ImageRenderer` cannot rasterise Liquid Glass or material blur, so the
    /// offscreen snapshot path flips this and every surface falls back to the
    /// plain-material look used on macOS 13–15.
    static var useGlass = true
    /// True only for the offscreen snapshot harness (seeds sample content and
    /// swaps AppKit-backed views for drawable equivalents).
    static var isPreview = false
}

/// 外观偏好，由 `AppSettings` 在读写时同步进来。视图随 settings 重绘时
/// 这些值已经更新，所以不需要额外的观察机制。
enum Appearance {
    /// macOS 26+ 是否启用液态玻璃。低版本系统只有毛玻璃，此项无意义。
    static var liquidGlassEnabled = true
    /// 强调色是否跟随系统「外观 → 强调色」。
    static var followSystemAccent = true

    /// 主按钮、选中态、开关与滑块的着色。
    static var accent: Color { followSystemAccent ? Color.accentColor : Color.primary }
    /// 压在强调色块上的文字颜色。
    static var onAccent: Color { followSystemAccent ? Color.white : Theme.inverse }

    /// 当前系统是否有液态玻璃可用。
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 液态玻璃真正生效的条件：系统支持 + 快照可用 + 用户没关。
    static var usesLiquidGlass: Bool {
        supportsLiquidGlass && RenderMode.useGlass && liquidGlassEnabled
    }
}

/// Monochrome design language: system background, label colours and hairline
/// separators only. Everything adapts to light/dark automatically because no
/// colour is hard-coded.
enum Theme {    static let radius: CGFloat = 26
    static let controlRadius: CGFloat = 15

    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var hairline: Color { Color.primary.opacity(0.09) }
    static var faintFill: Color { Color.primary.opacity(0.05) }
    static var softFill: Color { Color.primary.opacity(0.08) }
    /// Inverse of the window background: used for primary buttons and the
    /// active selection, so "black on white" simply flips in dark mode.
    static var inverse: Color { Color(nsColor: .windowBackgroundColor) }
}

// MARK: - Liquid Glass surfaces

@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if interactive { glass = glass.interactive() }
    if let tint { glass = glass.tint(tint) }
    return glass
}

extension View {
    /// Rounded glass card. Liquid Glass on macOS 26+, material elsewhere.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.radius,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), Appearance.usesLiquidGlass {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.10), radius: 26, y: 12)
        }
    }

    /// Capsule glass used for the floating toolbar and chips.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *), Appearance.usesLiquidGlass {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: Capsule())
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        }
    }
}

/// Groups glass shapes so they can morph into each other (macOS 26 only).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *), Appearance.usesLiquidGlass {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// `glassEffectID` is macOS 26 only; this keeps the morphing animation on
    /// new systems and degrades to nothing elsewhere.
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *), Appearance.usesLiquidGlass {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Buttons

struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Appearance.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Appearance.accent)
                    .opacity(isEnabled ? 1 : 0.28)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct QuietPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.9 : 0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(Theme.faintFill))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func primaryPill() -> some View { buttonStyle(PrimaryPillStyle()) }

    /// Secondary actions: native Liquid Glass buttons on macOS 26, material
    /// pills everywhere else.
    @ViewBuilder
    func quietPill() -> some View {
        if #available(macOS 26.0, *), Appearance.usesLiquidGlass {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(QuietPillStyle())
        }
    }

    /// Compact glass icon button, used in the window toolbar and toolbars.
    func glassIconButton(size: CGFloat = 30) -> some View {
        self
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassCapsule()
            .foregroundStyle(.primary)
    }
}

// MARK: - Small building blocks

struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

struct Pill: View {
    var icon: String? = nil
    let text: String
    var emphasis: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(emphasis ? Theme.inverse : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(emphasis ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Theme.faintFill))
        )
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Minimal waveform meter: bars light up as the level rises.
struct LevelMeter: View {
    var level: Float
    var bars: Int = 22

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index) / Float(bars)
                Capsule()
                    .fill(threshold < level ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.16)))
                    .frame(width: 2.5, height: CGFloat(5.0 + Double(index % 6) * 2.5))
            }
        }
        .animation(.easeOut(duration: 0.18), value: level)
    }
}

/// `ScrollView` measures to zero height inside `ImageRenderer`, so the snapshot
/// harness renders the same content through a plain stack.
struct ScrollHost<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if RenderMode.isPreview {
            content()
        } else {
            ScrollView { content() }
        }
    }
}

/// Determinate hairline bar for the live generation estimate. Thin on purpose:
/// it must not compete with the text being written.
struct SlimProgress: View {
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: width, height: 3)
                Capsule()
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: max(2, width * min(1, max(0, fraction))), height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// Liquid Glass progress card for long runs (audiobook synthesis). On macOS 26
/// the whole card is one glass surface with a tinted fill; older systems get a
/// material card with the same layout.
struct GlassProgress: View {
    var fraction: Double
    let title: String
    var detail: String? = nil
    var icon: String = "waveform"
    var onCancel: (() -> Void)? = nil

    private var percentText: String { "\(Int((min(1, max(0, fraction))) * 100))%" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(percentText)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(Color.primary.opacity(0.65))
                            .frame(width: max(3, width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.3), value: fraction)
            }

            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .glassIconButton(size: 26)
                .help("停止生成")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 15)
    }
}

/// Drawable stand-in for `TextEditor` inside the snapshot harness.
struct TextBlock: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - macOS 12 compatibility

extension View {
    /// `scrollContentBackground(.hidden)` 是 macOS 13 的 API。12 上没有等价
    /// 修饰符，用一个隐藏探针把 TextEditor 内部的 NSTextView 背景刷透明。
    @ViewBuilder
    func transparentTextBackground() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self.background(TextEditorBackgroundProbe())
        }
    }
}

/// 沿视图层级向上找到 TextEditor 的 NSTextView，去掉它自带的不透明底。
struct TextEditorBackgroundProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { Self.clear(around: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.clear(around: nsView) }
    }

    private static func clear(around probe: NSView) {
        var node: NSView? = probe.superview
        while let current = node {
            if let textView = current as? NSTextView {
                textView.drawsBackground = false
                textView.backgroundColor = .clear
                return
            }
            if let scroll = current as? NSScrollView,
               let textView = scroll.documentView as? NSTextView {
                textView.drawsBackground = false
                textView.backgroundColor = .clear
                return
            }
            node = current.superview
        }
    }
}
