import Foundation
import Network

// BreezeRemoteHelper — tiny always-on LaunchAgent (event-driven, ~0 power idle).
// Listens on 4747; every request wakes the full app via `open`, then proxies
// HTTP to the app's own server on port 4748 with retry (model load takes ~20 s).
let appPort: UInt16 = 4748
var listener: NWListener?

// Bind 4747; if the app itself took the port (it was launched first), poll
// every 5 s until the app quits and the port frees up, then take over.
func tryBind() {
    guard listener == nil else { return }
    let l: NWListener
    do { l = try NWListener(using: .tcp, on: 4747) } catch {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { tryBind() }
        return
    }
    l.newConnectionHandler = { conn in
        conn.start(queue: .global())
        recv(conn: conn, buf: Data())
    }
    l.stateUpdateHandler = { s in
        switch s {
        case .ready:
            listener = l
        case .failed(let e):
            print("listener failed: \(e)")
            listener = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { tryBind() }
        default: break
        }
    }
    l.start(queue: .global())
}
tryBind()

func recv(conn: NWConnection, buf: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, err in
        var buf = buf
        if let data { buf.append(data) }
        if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(data: buf[..<r.lowerBound], encoding: .utf8) ?? ""
            let len = Int(head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length") }?
                .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            if buf.count - r.upperBound >= len {
                let body = Data(buf[r.upperBound..<(r.upperBound + len)])
                handle(conn: conn, head: head, body: body)
                return
            }
        }
        if err == nil && !complete && buf.count < (8 << 20) { recv(conn: conn, buf: buf) } else { conn.cancel() }
    }
}

func handle(conn: NWConnection, head: String, body: Data) {
    let first = head.components(separatedBy: "\r\n").first ?? ""
    let parts = first.components(separatedBy: " ")
    let method = parts.count > 0 ? parts[0] : "GET"
    let path = parts.count > 1 ? parts[1] : "/"
    // Any request wakes the app (idempotent if already running). NO `-n`:
    // that forces a brand-new instance every request and floods the dock;
    // the app itself now single-instances, but don't rely on it.
    // /Applications/BreezeTTS.app is the canonical install — deploy.sh
    // refreshes it after every build, so wake only ever opens that one.
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-g", "/Applications/BreezeTTS.app"]
    try? task.run()

    proxy(conn: conn, method: method, path: path, body: body, attempt: 0)
}

func proxy(conn: NWConnection, method: String, path: String, body: Data, attempt: Int) {
    let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: appPort)!, using: .tcp)
    c.stateUpdateHandler = { state in
        if state == .ready {
            var req = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(req.utf8); payload.append(body)
            c.send(content: payload, completion: .contentProcessed { err in
                var out = Data()
                func readAll() {
                    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, _ in
                        if let data { out.append(data) }
                        if complete || data == nil { conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() }) }
                        else { readAll() }
                    }
                }
                readAll()
            })
        } else if case .failed = state, attempt < 60 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                proxy(conn: conn, method: method, path: path, body: body, attempt: attempt + 1)
            }
        } else if case .failed = state {
            let msg = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\n\r\n{\"error\":\"app not reachable\"}"
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
    c.start(queue: .global())
}
dispatchMain()
