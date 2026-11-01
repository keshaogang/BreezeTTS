import Foundation
import Network

/// Discovers and talks to the Mac over the LAN (or the internet via port
/// forwarding). All synthesis happens on the Mac; the phone only sends text,
/// mirrors settings, watches progress and downloads the finished WAV.
final class RemoteClient: ObservableObject {
    @Published var servers: [DiscoveredMac] = []
    @Published var state: State = .disconnected
    @Published var statusText = ""
    @Published var progress: Double?
    @Published var remaining: Double?
    /// Mirrors of the Mac's state, refreshed on connect and after changes.
    @Published var macVoice = ""
    @Published var macInstruction = ""
    @Published var macStreaming = false
    @Published var macModel = ""
    @Published var voiceCatalog: [RemoteVoice] = []
    @Published var historyItems: [RemoteHistoryItem] = []
    /// Audiobook mirror state.
    @Published var abStatus = ""
    @Published var abAnalyzing = false
    @Published var abGenerating = false
    @Published var abProgress: Double = 0
    @Published var abCharacters: [ABCharacter] = []
    @Published var abSegments = 0
    /// Finished book: Mac history id + duration, surfaced by /audiobook/state.
    @Published var abAudioID: String?
    @Published var abAudioDuration: Double = 0
    /// Download state: nil = not started; 0…1 while running; 1 = cached.
    @Published var abDownloadProgress: Double?
    @Published var abDownloadedData: Data?
    /// Mac 设置镜像：对话功能开关（关闭时底栏不显示对话）。
    @Published var macChatEnabled = false
    /// 对话消息镜像（role/text/time）。
    @Published var chatMessages: [ChatEntry] = []
    @Published var chatThinking = false
    @Published var chatError = ""

    struct ChatEntry: Identifiable, Equatable {
        let id: UUID
        let role: String
        let text: String
        var isUser: Bool { role == "user" }
    }

    struct DiscoveredMac: Identifiable, Equatable {
        let id: String       // endpoint name
        let host: String
        let port: Int
        /// Bonjour 浏览结果里的完整端点，直接用它连接（手工构造 .service
        /// 端点会在 Network 框架内闪退）。
        var endpoint: NWEndpoint?
    }

    struct RemoteVoice: Identifiable {
        let id: String
        let name: String
        let kind: String   // "text" | "clone"
        var isClone: Bool { kind == "clone" }
    }

    struct RemoteHistoryItem: Identifiable {
        let id: String
        let title: String
        let duration: Double
        let date: String
        let voice: String
        let hasAudio: Bool
    }

    struct ABCharacter: Identifiable {
        let id: String
        let name: String
        let age: String
        let personality: String
        let lines: Int
    }

    enum State: Equatable { case disconnected, connecting, ready, generating, done, failed(String) }

    private var browser: NWBrowser?
    private var pollTimer: Timer?
    private var abTimer: Timer?
    private var token: String {
        get { UserDefaults.standard.string(forKey: "remote.token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "remote.token") }
    }
    /// External actions (Shortcuts) read the saved base + token directly.
    static var sharedBase: URL? {
        guard let saved = UserDefaults.standard.string(forKey: "remote.base"), !saved.isEmpty else { return nil }
        return URL(string: saved)
    }
    static var sharedToken: String { UserDefaults.standard.string(forKey: "remote.token") ?? "" }

    var base: URL? { Self.sharedBase }

    func setToken(_ t: String) { token = t }

    private func requestFor(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        guard let base else { return URLRequest(url: URL(string: "http://127.0.0.1:1")!) }
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        if !token.isEmpty { r.setValue(token, forHTTPHeaderField: "X-Breeze-Token") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Build a safe http URL from a resolved host (handles IPv6 / interface zones).
    static func makeBaseURL(host rawHost: String, port: Int) -> URL? {
        var host = rawHost
        // Strip interface zone, e.g. "fe80::1%en0"
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        // IPv6 needs brackets in a URL
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        return URL(string: "http://\(host):\(port)")
    }

    func setBase(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: "remote.base")
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        abTimer?.invalidate()
        abTimer = nil
        UserDefaults.standard.set("", forKey: "remote.base")
        state = .disconnected
        statusText = ""
        voiceCatalog = []
        historyItems = []
    }

    // MARK: - Bonjour

    func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: "_breezettts._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredMac(id: name, host: name, port: 4747, endpoint: result.endpoint)
            }
            DispatchQueue.main.async { self?.servers = found }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    /// 用 Bonjour 浏览结果的端点直接连接（修复手构造端点的闪退）。
    func connect(to mac: DiscoveredMac) {
        guard let endpoint = mac.endpoint else {
            state = .failed("服务信息不完整，请重新搜索或扫码绑定")
            return
        }
        state = .connecting
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let hostStr = "\(host)"
                    DispatchQueue.main.async {
                        if let url = RemoteClient.makeBaseURL(host: hostStr, port: Int(port.rawValue)) {
                            self?.setBase(url)
                            self?.state = .ready
                            self?.checkStatus()
                        } else {
                            self?.state = .failed("无法解析 Mac 地址（\(hostStr)），请扫码绑定或手动输入 IP")
                        }
                    }
                } else {
                    DispatchQueue.main.async { self?.state = .failed("连接建立但未获取到地址，请扫码绑定或手动输入 IP") }
                }
                connection.cancel()
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    if let s = self, s.state == .connecting { s.state = .failed("发现服务连接失败，请扫码绑定或手动输入 IP") }
                }
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    /// 解析 Mac 端二维码内容（JSON：host/hosts/port/token）并连接。
    /// 二维码可能带多个候选 IP（Mac 有线 + Wi-Fi + 热点），逐个探测直到有应答。
    func connectWithPairPayload(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let host = object["host"] as? String, !host.isEmpty else {
            state = .failed("二维码内容无效，请确认扫的是 Mac 端「绑定二维码」")
            return false
        }
        let port = object["port"] as? Int ?? 4747
        if let pairToken = object["token"] as? String { setToken(pairToken) }
        // 候选地址：hosts 列表优先，host 兜底，去重保序。
        var hosts = (object["hosts"] as? [String]) ?? []
        if !hosts.contains(host) { hosts.insert(host, at: 0) }
        hosts = hosts.filter { !$0.isEmpty }
        guard let first = hosts.first,
              let url = RemoteClient.makeBaseURL(host: first, port: port) else {
            state = .failed("二维码里的地址无效（\(host)）")
            return false
        }
        setBase(url)
        state = .connecting
        // 从第二个候选开始逐个换地址探测，全部失败才算连不上。
        tryStatus(hosts: Array(hosts.dropFirst()), port: port)
        return true
    }

    /// 依次探测候选地址：当前 base 失败就换下一个，成功即 ready。
    private func tryStatus(hosts: [String], port: Int) {
        guard let base else { return }
        var request = URLRequest(url: base.appendingPathComponent("status"))
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   (try? JSONSerialization.jsonObject(with: data ?? Data())) != nil {
                    self.state = .ready
                    self.statusText = "已连接 Mac"
                    self.fetchSettings()
                    self.fetchHistory()
                    return
                }
                if let next = hosts.first, let url = RemoteClient.makeBaseURL(host: next, port: port) {
                    self.setBase(url)
                    self.tryStatus(hosts: Array(hosts.dropFirst()), port: port)
                } else {
                    self.state = .failed("Mac 没有应答：确认手机和 Mac 在同一网络（手机热点最稳妥）、Mac 端 App 在运行且已开启「允许 iPhone 遥控」")
                }
            }
        }.resume()
    }

    func connectDirect(host: String, port: Int = 4747) {
        guard let url = RemoteClient.makeBaseURL(host: host, port: port) else {
            state = .failed("地址格式无效，请检查后重试")
            return
        }
        setBase(url)
        checkStatus()
    }

    // MARK: - API

    func checkStatus() {
        guard let base else { return }
        var request = URLRequest(url: base.appendingPathComponent("status"))
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] {
                    self.state = .ready
                    self.statusText = "已连接 Mac"
                    self.macModel = object["model"] as? String ?? ""
                    self.macVoice = object["voice"] as? String ?? ""
                    self.fetchSettings()
                    self.fetchHistory()
                } else {
                    self.state = .failed("Mac 没有应答：确认 Mac 端 App 在运行、设置里已开启「允许 iPhone 遥控」；外网连接需填配对码")
                }
            }
        }.resume()
    }

    // MARK: Settings mirror

    func fetchSettings() {
        URLSession.shared.dataTask(with: requestFor("settings")) { [weak self] data, _, _ in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.macVoice = object["voice"] as? String ?? self.macVoice
                self.macInstruction = object["instruction"] as? String ?? ""
                self.macStreaming = object["streaming"] as? Bool ?? false
                self.macChatEnabled = object["chatEnabled"] as? Bool ?? false
                if let voices = object["voices"] as? [[String: Any]] {
                    self.voiceCatalog = voices.compactMap {
                        guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
                        return RemoteVoice(id: id, name: name, kind: $0["kind"] as? String ?? "text")
                    }
                }
            }
        }.resume()
    }

    /// Apply voice / instruction / streaming on the Mac, then refresh the mirror.
    func applySettings(body: [String: Any]) {
        URLSession.shared.dataTask(with: requestFor("settings", method: "POST", body: body)) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode == 401 {
                    self?.state = .failed("配对码不对")
                } else {
                    self?.fetchSettings()
                }
            }
        }.resume()
    }

    func applyVoice(_ voice: RemoteVoice) {
        applySettings(body: ["voiceID": voice.id])
        macVoice = voice.name
    }

    func applyStreaming(_ on: Bool) {
        applySettings(body: ["streaming": on])
        macStreaming = on
    }

    // MARK: History

    func fetchHistory() {
        URLSession.shared.dataTask(with: requestFor("history")) { [weak self] data, _, _ in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                self.historyItems = items.compactMap {
                    guard let id = $0["id"] as? String, let title = $0["title"] as? String else { return nil }
                    return RemoteHistoryItem(id: id,
                                             title: title,
                                             duration: $0["duration"] as? Double ?? 0,
                                             date: $0["date"] as? String ?? "",
                                             voice: $0["voice"] as? String ?? "",
                                             hasAudio: $0["hasAudio"] as? Bool ?? false)
                }
            }
        }.resume()
    }

    /// Downloads a history clip (also used by 下载/分享).
    func fetchHistoryAudio(id: String, completion: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: requestFor("audio/h/\(id)")) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok ? data : nil) }
        }.resume()
    }

    // MARK: Generate

    /// Full round trip: submit → poll (with the Mac's real progress) → download.
    func generate(text: String, instruction: String?) {
        guard let base else { return }
        state = .generating
        progress = nil
        remaining = nil
        statusText = "已发送，等待 Mac 合成…"
        var body: [String: Any] = ["text": text]
        if let instruction, !instruction.isEmpty { body["instruction"] = instruction }
        let request = requestFor("generate", method: "POST", body: body)
        var mutable = request
        mutable.timeoutInterval = 15

        URLSession.shared.dataTask(with: mutable) { [weak self] data, response, _ in
            guard let self else { return }
            if (response as? HTTPURLResponse)?.statusCode == 409 {
                DispatchQueue.main.async { self.state = .failed("Mac 正在忙别的合成，稍后再试") }
                return
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else {
                DispatchQueue.main.async { self.state = .failed("发送失败：无法连接 Mac") }
                return
            }
            self.startPolling(job: id, start: Date())
        }.resume()
    }

    private func startPolling(job id: String, start: Date) {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let base = self.base else { timer.invalidate(); return }
            var request = URLRequest(url: base.appendingPathComponent("job/\(id)"))
            request.timeoutInterval = 5
            if !self.token.isEmpty { request.setValue(self.token, forHTTPHeaderField: "X-Breeze-Token") }
            URLSession.shared.dataTask(with: request) { data, _, _ in
                let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
                let jobState = object["state"] as? String ?? "running"
                DispatchQueue.main.async {
                    if let fraction = object["fraction"] as? Double {
                        self.progress = fraction
                    }
                    self.remaining = object["remaining"] as? Double
                    if jobState == "running", Date().timeIntervalSince(start) < 1800 { return }
                    timer.invalidate()
                    if jobState == "done" {
                        self.download(id: id, start: start)
                    } else {
                        self.state = .failed("Mac 端合成失败或超时")
                    }
                }
            }.resume()
        }
        pollTimer = timer
    }

    private func download(id: String, start: Date) {
        guard let base else { return }
        var request = URLRequest(url: base.appendingPathComponent("audio/\(id)"))
        request.timeoutInterval = 60
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Breeze-Token") }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.progress = 1
                    self.state = .done
                    self.statusText = "完成，耗时 \(Int(Date().timeIntervalSince(start))) 秒"
                    NotificationCenter.default.post(name: .remoteAudioReady, object: data)
                    self.fetchHistory()
                } else {
                    self.state = .failed("取回音频失败")
                }
            }
        }.resume()
    }

    // MARK: - Chat（对话，Mac 端 LLM 计算）

    /// 发一条消息给 Mac；阻塞至回复返回（LLM 思考可能需要几秒到几十秒）。
    func sendChat(_ text: String, completion: ((String?) -> Void)? = nil) {
        guard base != nil, !chatThinking else { return }
        chatThinking = true
        chatError = ""
        chatMessages.append(ChatEntry(id: UUID(), role: "user", text: text))
        var request = requestFor("chat", method: "POST", body: ["text": text])
        request.timeoutInterval = 300
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.chatThinking = false
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any],
                   let reply = object["reply"] as? String {
                    self.chatMessages.append(ChatEntry(id: UUID(), role: "assistant", text: reply))
                    completion?(reply)
                } else if let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any],
                          let error = object["error"] as? String {
                    self.chatError = error
                    completion?(nil)
                } else {
                    self.chatError = "发送失败：无法连接 Mac"
                    completion?(nil)
                }
            }
        }.resume()
    }

    /// 拉取 Mac 端的会话历史（进对话页时同步一次）。
    func fetchChatHistory() {
        URLSession.shared.dataTask(with: requestFor("chat/history")) { [weak self] data, _, _ in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                self.chatMessages = messages.compactMap {
                    guard let role = $0["role"] as? String,
                          let text = $0["text"] as? String else { return nil }
                    return ChatEntry(id: UUID(), role: role, text: text)
                }
            }
        }.resume()
    }

    /// 朗读某条回复：发文本到 Mac 合成、轮询、下载并播放（复用生成管线）。
    func speakChatReply(_ text: String) {
        generate(text: text, instruction: nil)
    }

    // MARK: Audiobook remote flow

    func audiobookAnalyze(text: String) {
        abStatus = "已发送到 Mac，正在分析人物…"
        abAnalyzing = true
        abCharacters = []
        URLSession.shared.dataTask(with: requestFor("audiobook/analyze", method: "POST", body: ["text": text])) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode != 200 {
                    self?.abStatus = "发送失败"
                    self?.abAnalyzing = false
                } else {
                    self?.watchAudiobook(untilAnalyzingDone: true)
                }
            }
        }.resume()
    }

    func audiobookGenerate() {
        abGenerating = true
        abProgress = 0
        abAudioID = nil
        abDownloadedData = nil
        abDownloadProgress = nil
        abStatus = "已发送到 Mac，开始逐段合成…"
        URLSession.shared.dataTask(with: requestFor("audiobook/generate", method: "POST", body: [:])) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if (response as? HTTPURLResponse)?.statusCode != 200 {
                    self?.abStatus = "发送失败"
                    self?.abGenerating = false
                }
                // state polling already running; keep watching
            }
        }.resume()
    }

    /// Polls /audiobook/state until the requested phase settles.
    private func watchAudiobook(untilAnalyzingDone: Bool) {
        abTimer?.invalidate()
        var waited = 0.0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let base = self.base else { timer.invalidate(); return }
            URLSession.shared.dataTask(with: URLRequest(url: base.appendingPathComponent("audiobook/state"))) { data, _, _ in
                let object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
                DispatchQueue.main.async {
                    self.abStatus = object["status"] as? String ?? ""
                    self.abAnalyzing = object["analyzing"] as? Bool ?? false
                    self.abGenerating = object["generating"] as? Bool ?? false
                    self.abProgress = object["progress"] as? Double ?? 0
                    self.abSegments = object["segments"] as? Int ?? 0
                    self.abAudioID = object["audio_id"] as? String ?? self.abAudioID
                    if let d = object["audio_duration"] as? Double { self.abAudioDuration = d }
                    if let chars = object["characters"] as? [[String: Any]] {
                        self.abCharacters = chars.compactMap {
                            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
                            return ABCharacter(id: id, name: name,
                                               age: $0["age"] as? String ?? "",
                                               personality: $0["personality"] as? String ?? "",
                                               lines: $0["lines"] as? Int ?? 0)
                        }
                    }
                    waited += 1.5
                    if untilAnalyzingDone {
                        if !self.abAnalyzing, waited > 4 {
                            timer.invalidate()
                        }
                    } else if !self.abGenerating {
                        timer.invalidate()
                        self.fetchHistory()
                    }
                    if waited > 7200 { timer.invalidate() }
                }
            }.resume()
        }
        abTimer = timer
    }

    /// Keeps the audiobook mirror fresh while its sheet is open.
    func startAudiobookWatching() {
        watchAudiobook(untilAnalyzingDone: false)
    }

    func stopAudiobookWatching() {
        abTimer?.invalidate()
        abTimer = nil
    }

    // MARK: Audiobook download (streamed, real progress)

    /// Streams the finished WAV from the Mac, reporting 0…1 as bytes land.
    func downloadAudiobook() {
        guard base != nil, abAudioID != nil, !abDownloadingNow else { return }
        abDownloadingNow = true
        abDownloadProgress = 0
        let delegate = DownloadProgressSession(
            onProgress: { [weak self] fraction in
                DispatchQueue.main.async { self?.abDownloadProgress = min(0.99, fraction) }
            },
            onDone: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.abDownloadingNow = false
                    switch result {
                    case .success(let file):
                        self.abDownloadedData = (try? Data(contentsOf: file))
                        self.abDownloadProgress = 1
                        try? FileManager.default.removeItem(at: file)
                    case .failure(let error):
                        self.abDownloadProgress = nil
                        self.abStatus = "下载失败：\(error.localizedDescription)"
                    }
                }
            })
        dlSession = delegate
        dlURL = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        dlURL?.downloadTask(with: requestFor("audio/h/\(abAudioID!)")).resume()
    }

    private var abDownloadingNow = false
    private var dlSession: DownloadProgressSession?
    private var dlURL: URLSession?

    /// Writes the downloaded book to a temp file for sharing / saving to Files.
    func audiobookFileURL() -> URL? {
        guard let data = abDownloadedData else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreezeTTS-听书-\(Int(Date().timeIntervalSince1970)).wav")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// m:ss clock used across the audiobook UI.
    func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Notification.Name {
    static let remoteAudioReady = Notification.Name("remoteAudioReady")
}

/// URLSessionDownloadDelegate bridge giving byte-accurate progress callbacks.
private final class DownloadProgressSession: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onDone: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Double) -> Void, onDone: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onDone = onDone
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onDone(.success(dest))
        } catch {
            onDone(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onDone(.failure(error)) }
    }
}
