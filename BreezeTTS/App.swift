import AppKit
import SwiftUI

@main
struct BreezeTTSApp: App {
    @MainActor
    init() {
        FreshStart.runIfRequested()
        if Headless.runIfRequested() {
            exit(0)
        }
        // Single instance: a second launch (helper `open`, double click, …)
        // must raise the running window instead of piling up dock icons.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            exit(0)
        }
        IconAppearance.start()
    }

    var body: some Scene {
        WindowGroup("Breeze TTS") {
            RootView()
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// First run goes through onboarding; the composer only appears once a model is
/// available and setup has been finished.
struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView(model: model)
            } else {
                MainView(model: model)
            }
        }
    }
}

/// Sets up the window chrome: transparent titlebar, movable by background, and a
/// sane default size.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .windowBackgroundColor
            // `windowResizability` 是 macOS 13 的 API，这里直接压住最小尺寸。
            window.contentMinSize = NSSize(width: 820, height: 640)
            if window.frame.width < 900 {
                window.setContentSize(NSSize(width: 980, height: 700))
                window.center()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 开发/验收用：把本 App 的本地数据全部清空后再正常启动，效果等同
/// 「刚下载完、第一次双击打开」。只动自己的数据目录，不碰完整版。
enum FreshStart {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let plain = args.contains("--fresh")
        let empty = args.contains("--fresh-empty")
        guard plain || empty else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.appSupport.path) {
            try? fm.removeItem(atPath: Paths.appSupport.path)
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        if empty {
            // 连内置音色都不种，用来看完全没有预设的界面。
            UserDefaults.standard.set(true, forKey: "voices.presetsSeeded.v1")
        }
        UserDefaults.standard.synchronize()
        NSLog("BreezeTTS: fresh start, data wiped at \(Paths.appSupport.path)")
    }
}

/// 图标随系统外观切换：浅色模式用亮色图，深色模式用深空版，
/// 免得在深色 Dock/启动台里图标还是刺眼的亮块。
enum IconAppearance {
    private static var observer: NSObjectProtocol?

    static func start() {
        // App.init 阶段 NSApplication 还没建好，等主循环跑起来再取外观。
        DispatchQueue.main.async { apply() }
        guard observer == nil else { return }
        // 系统主题切换没有 AppKit 通知，只有这条分布式通知。
        observer = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            // 外观值在通知之后才落到 NSApp 上，稍等一拍再取。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { apply() }
        }
    }

    private static func apply() {
        guard let app = NSApp else { return }
        let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = dark ? "IconDark" : "IconLight"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        app.applicationIconImage = image
    }
}
