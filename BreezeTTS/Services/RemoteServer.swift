import Foundation
import Network

/// Tiny LAN HTTP server so the iPhone can drive the Mac: POST text, poll,
/// download the finished WAV and play it locally. The iPhone never computes —
/// this is the only bridge. Listens on port 4747 and advertises itself over
/// Bonjour as `_breezettts._tcp` so the iOS app can auto-discover the Mac.
final class RemoteServer {
    static let shared = RemoteServer()

    static let serviceType = "_breezettts._tcp"
    static let port: NWEndpoint.Port = 4747

    private var listener: NWListener?
    private(set) var isRunning = false
    /// Actually bound port (4747 normally; 4748 when the always-on helper owns 4747).
    private(set) var boundPort: UInt16 = 0

    private let lock = NSLock()
    private var jobID = ""
    private var jobState = "idle"          // idle | running | done | failed
    private var jobFile: URL?

    // MARK: - Paired devices

    struct Client {
        var name: String
        var address: String
        var lastSeen: Date
        /// 两分钟内有请求就算在线；离线的保留在列表里，方便用户手动移除。
        var isOnline: Bool { Date().timeIntervalSince(lastSeen) < 120 }
    }

    private var clients: [String: Client] = [:]

    var pairedDevices: [Client] {
        lock.lock()
        defer { lock.unlock() }
        return clients.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func forgetDevices() {
        lock.lock()
        clients.removeAll()
        lock.unlock()
    }

    private func noteClient(connection: NWConnection, header: String) {
        let address: String
        if case let .hostPort(host, _) = connection.endpoint {
            address = "\(host)"
        } else {
            address = "unknown"
        }
        let device = header.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("x-breeze-device") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let name = device.isEmpty ? "iPhone / iPad" : device

        lock.lock()
        clients[address] = Client(name: name, address: address, lastSeen: Date())
        lock.unlock()
    }

    var statusProvider: (() -> [String: Any])?
    var generateHandler: ((String, String?, @escaping (Result<URL, Error>) -> Void) -> Void)?
    /// Settings mirror for the phone: current voice/instruction/streaming + the
    /// voice catalog so iOS can pick one.
    var settingsProvider: (() -> [String: Any])?
    /// Applies {voiceID|voice, instruction, streaming} sent from the phone.
    var settingsApplyHandler: (([String: Any]) -> Void)?
    /// Live run progress merged into /job and /progress responses.
    var progressProvider: (() -> [String: Any])?
    /// Recent generations for the phone's history list.
    var historyProvider: (() -> [[String: Any]])?
    /// Resolves a history item UUID to its WAV file, if it still exists.
    var historyAudioHandler: ((String) -> URL?)?
    /// Remote audiobook flow: analyze text → characters, then generate.
    var audiobookStartHandler: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var audiobookStateProvider: (() -> [String: Any])?
    var audiobookGenerateHandler: ((@escaping (Result<URL, Error>) -> Void) -> Void)?
    /// 手机上改角色档案（年龄/性别/音色特征/名字）。
    var audiobookRoleHandler: (([String: Any]) -> Void)?
    /// 手机上给某个角色生成基准参考音色。
    var audiobookRefHandler: ((String) -> Void)?
    /// 对话：iPhone 发一条消息，Mac 的 LLM 回复（回复同时在 Mac 端生成）。
    var chatHandler: ((String, @escaping (Result<String, Error>) -> Void) -> Void)?
    /// 对话历史镜像（iOS 首次进入时拉取）。
    var chatHistoryProvider: (() -> [[String: Any]])?

    // MARK: - Lifecycle

    /// Ports we try in order. The LaunchAgent helper owns 4747 when the app is
    /// closed; when both are up the app falls through to 4748 and the helper
    /// proxies 4747 → 4748. Binding failure only surfaces asynchronously, so
    /// each candidate gets a short watchdog before moving on.
    private static let candidatePorts: [UInt16] = [4747, 4748]

    func start() {
        guard !isRunning else { return }
        bindCandidate(0)
    }

    private func bindCandidate(_ index: Int) {
        guard index < Self.candidatePorts.count else {
            NSLog("BreezeTTS: remote server failed — no free port")
            return
        }
        let port = NWEndpoint.Port(rawValue: Self.candidatePorts[index])!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let candidate: NWListener
        do { candidate = try NWListener(using: parameters, on: port) }
        catch { bindCandidate(index + 1); return }

        let once = Once()
        candidate.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        candidate.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard once.fire() else { return }
                self?.listener = candidate
                self?.boundPort = UInt16(port.rawValue)
                self?.isRunning = true
                candidate.service = NWListener.Service(name: "BreezeTTS Mac",
                                                       type: Self.serviceType)
                NSLog("BreezeTTS: remote server up on port \(port)")
            case .failed(let error):
                NSLog("BreezeTTS: remote port \(port) failed: \(error)")
                guard once.fire() else { return }
                candidate.cancel()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    self?.bindCandidate(index + 1)
                }
            case .cancelled:
                guard once.fire() else { return }
                self?.isRunning = false
                self?.listener = nil
            default: break
            }
        }
        candidate.start(queue: .global(qos: .userInitiated))

        // Watchdog: a port stolen by another process can stay silent forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            guard once.fire() else { return }
            candidate.cancel()
            NSLog("BreezeTTS: remote port \(port) silent — trying next")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.bindCandidate(index + 1)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = 0
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = Self.headerValue(header, key: "Content-Length")
                let bodyStart = headerEnd.upperBound
                let have = buffer.count - bodyStart
                if have >= contentLength {
                    let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
                    self.route(connection: connection, header: header, body: body)
                    return
                }
            }
            if error == nil && !isComplete && buffer.count < (8 << 20) {
                self.receiveRequest(connection: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    /// 6 位配对码。第一次需要配对时生成，之后固定下来；二维码和界面上显示
    /// 的都是它，iPhone 连接时要带上同一个值，别的设备猜不到就进不来。
    static let pairingCode: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "remote.token")?
            .trimmingCharacters(in: .whitespaces), !existing.isEmpty {
            return existing
        }
        let code = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        defaults.set(code, forKey: "remote.token")
        return code
    }()

    /// Pairing code for non-LAN access.
    static func tokenOK(header: String) -> Bool {
        let expected = pairingCode
        let got = header.split(separator: "\r\n").first { $0.lowercased().hasPrefix("x-breeze-token") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return got == expected
    }

    private static func headerValue(_ header: String, key: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    // MARK: - Routing

    private func route(connection: NWConnection, header: String, body: Data) {
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let rawPath = parts.count > 1 ? parts[1] : "/"
        let path = rawPath.components(separatedBy: "?").first ?? "/"

        noteClient(connection: connection, header: header)

        lock.lock()
        let currentID = jobID
        let currentState = jobState
        lock.unlock()

        switch (method, path) {
        case ("GET", "/status"):
            let payload = statusProvider?() ?? [:]
            respond(connection, json: payload)

        /// 配对握手：iPhone 扫码后先打这里，码对了才继续。
        /// `edition` 让手机能确认对面是完整版——精简版根本没有这台服务器。
        case ("GET", "/pair"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            respond(connection, json: [
                "ok": true,
                "edition": "full",
                "app": "BreezeTTS",
                "api": 2,
                "name": Host.current().localizedName ?? "Mac",
                "port": Int(boundPort),
            ])

        case ("GET", "/settings"):
            respond(connection, json: settingsProvider?() ?? [:])

        case ("POST", "/settings"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                respond(connection, code: "400 Bad Request", json: ["error": "json required"])
                return
            }
            settingsApplyHandler?(object)
            respond(connection, json: ["ok": true])

        case ("GET", "/progress"):
            var payload = progressProvider?() ?? [:]
            payload["state"] = currentState
            respond(connection, json: payload)

        case ("GET", "/history"):
            respond(connection, json: ["items": historyProvider?() ?? []])

        case ("POST", "/audiobook/analyze"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = object["text"] as? String, !text.isEmpty else {
                respond(connection, code: "400 Bad Request", json: ["error": "text required"])
                return
            }
            respond(connection, json: ["ok": true])
            audiobookStartHandler?(text) { _ in }

        case ("GET", "/audiobook/state"):
            respond(connection, json: audiobookStateProvider?() ?? [:])

        case ("POST", "/audiobook/role"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                respond(connection, code: "400 Bad Request", json: ["error": "json required"])
                return
            }
            audiobookRoleHandler?(object)
            respond(connection, json: ["ok": true])

        case ("POST", "/audiobook/ref"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty else {
                respond(connection, code: "400 Bad Request", json: ["error": "id required"])
                return
            }
            audiobookRefHandler?(id)
            respond(connection, json: ["ok": true])

        case ("GET", "/chat/history"):
            respond(connection, json: ["messages": chatHistoryProvider?() ?? []])

        case ("POST", "/chat"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = object["text"] as? String, !text.isEmpty else {
                respond(connection, code: "400 Bad Request", json: ["error": "text required"])
                return
            }
            chatHandler?(text) { [weak self] result in
                switch result {
                case .success(let reply):
                    self?.respond(connection, json: ["reply": reply])
                case .failure(let error):
                    self?.respond(connection, code: "502 Bad Gateway",
                                  json: ["error": error.localizedDescription])
                }
            }

        case ("POST", "/audiobook/generate"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            respond(connection, json: ["ok": true])
            audiobookGenerateHandler? { _ in }

        case ("POST", "/generate"):
            guard Self.tokenOK(header: header) else {
                respond(connection, code: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = object["text"] as? String, !text.isEmpty else {
                respond(connection, code: "400 Bad Request", json: ["error": "text required"])
                return
            }
            lock.lock()
            if currentState == "running" {
                lock.unlock()
                respond(connection, code: "409 Conflict", json: ["error": "busy", "job": currentID])
                return
            }
            let id = UUID().uuidString.prefix(8).lowercased()
            jobID = id
            jobState = "running"
            jobFile = nil
            lock.unlock()

            let instruction = object["instruction"] as? String
            generateHandler?(text, instruction) { [weak self] result in
                guard let self else { return }
                self.lock.lock()
                switch result {
                case .success(let url):
                    self.jobState = "done"
                    self.jobFile = url
                case .failure:
                    self.jobState = "failed"
                    self.jobFile = nil
                }
                self.lock.unlock()
            }
            respond(connection, json: ["id": id])

        case ("GET", let p) where p == "/job/\(currentID)":
            var payload: [String: Any] = ["id": currentID, "state": currentState]
            for (k, v) in progressProvider?() ?? [:] { payload[k] = v }
            respond(connection, json: payload)

        case ("GET", let p) where p.hasPrefix("/audio/h/"):
            let id = String(p.dropFirst("/audio/h/".count))
            if let url = historyAudioHandler?(id), let data = try? Data(contentsOf: url) {
                respond(connection, bytes: data, contentType: "audio/wav")
            } else {
                respond(connection, code: "404 Not Found", json: ["error": "no audio"])
            }

        case ("GET", let p) where p.hasPrefix("/audio/"):
            let id = String(p.dropFirst("/audio/".count))
            lock.lock()
            let url = (id == currentID && currentState == "done") ? jobFile : nil
            lock.unlock()
            if let url, let data = try? Data(contentsOf: url) {
                respond(connection, bytes: data, contentType: "audio/wav")
            } else {
                respond(connection, code: "404 Not Found", json: ["error": "not ready"])
            }

        default:
            respond(connection, code: "404 Not Found", json: ["error": "not found"])
        }
    }

    // MARK: - Responses

    private func respond(_ connection: NWConnection, code: String = "200 OK", json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(connection, bytes: data, contentType: "application/json", code: code)
    }

    private func respond(_ connection: NWConnection, bytes: Data, contentType: String, code: String = "200 OK") {
        var head = "HTTP/1.1 \(code)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bytes)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// One-shot latch so a listener whose state resolves twice is only handled once.
private final class Once {
    private let lock = NSLock()
    private var fired = false
    /// Returns true exactly once.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
