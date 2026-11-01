import Foundation

// MARK: - 下载源

/// 一个可用的下载源。`base` 是不含文件名的 resolve 前缀。
struct ModelSource: Equatable {
    let base: String
    let label: String

    func url(for fileName: String) -> URL? {
        URL(string: base + "/" + fileName)
    }
}

/// 找到并挑选下载源。
///
/// 三个层次：
/// 1. **内置源**——镜像站与上游站；
/// 2. **实测排序**——并发拉每个源的前 128 KB，按真实速度从快到慢排；
/// 3. **自动搜索**——内置源全部失效（模型被删、仓库改名、分支变更）时，
///    调用镜像站上的 HuggingFace 兼容 API 搜索同名仓库，再逐个检查文件树，
///    找到谁还存着这个 `.gguf` 就把它当新源。这样源失效不用等新版本发布。
enum ModelSourceFinder {
    static let mirror = "https://hf-mirror.com"
    static let upstream = "https://huggingface.co"

    static var builtin: [ModelSource] {
        [
            ModelSource(base: "\(mirror)/HoppouAI/Breeze-TTS-2.cpp/resolve/main", label: "hf-mirror"),
            ModelSource(base: "\(upstream)/HoppouAI/Breeze-TTS-2.cpp/resolve/main", label: "huggingface"),
            ModelSource(base: "\(mirror)/HoppouAI/Breeze-TTS-2.cpp/resolve/master", label: "hf-mirror/master")
        ]
    }

    private static func makeSession(_ timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 2
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 12
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    private static func decorate(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("BreezeTTS/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return req
    }

    /// 并发探测，按实测速度降序。返回 `ok`（已确认可下载）与 `dead`（兜底）。
    static func rank(sources: [ModelSource], fileName: String)
        -> (ok: [ModelSource], dead: [ModelSource]) {
        guard !sources.isEmpty else { return ([], []) }
        let session = makeSession(10)
        defer { session.invalidateAndCancel() }

        let lock = NSLock()
        var scored: [(ModelSource, Double)] = []
        var dead: [ModelSource] = []
        let group = DispatchGroup()

        for src in sources {
            guard let url = src.url(for: fileName) else { continue }
            group.enter()
            var req = decorate(url)
            req.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
            let started = Date()
            session.dataTask(with: req) { data, resp, err in
                defer { group.leave() }
                guard err == nil,
                      let http = resp as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let data, data.count > 4096 else {
                    lock.lock(); dead.append(src); lock.unlock()
                    return
                }
                let elapsed = max(0.2, Date().timeIntervalSince(started))
                lock.lock()
                scored.append((src, Double(data.count) / elapsed))
                lock.unlock()
            }.resume()
        }
        _ = group.wait(timeout: .now() + 14)

        let ordered = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        let leftovers = dead.filter { !ordered.contains($0) }
        return (ordered, leftovers)
    }

    /// 自动搜索：内置源全挂时，去镜像站的 API 找还有谁存着这个文件。
    /// 全异步回调，不用信号量等待——App 内首次握手偏慢，同步等待会误判成「搜不到」。
    static func discover(fileName: String, excluding: Set<String>,
                         completion: @escaping ([ModelSource]) -> Void) {
        let session = makeSession(15)

        searchRepos(api: mirror, query: "Breeze-TTS", session: session) { repos in
            let list = repos ?? []
            let candidates = Array(list.prefix(6))
            guard !candidates.isEmpty else {
                session.invalidateAndCancel()
                completion([])
                return
            }

            let lock = NSLock()
            var hits: [(repo: String, branch: String)] = []
            let group = DispatchGroup()

            for repo in candidates {
                for branch in ["main", "master"] {
                    group.enter()
                    treeFiles(repo: repo, branch: branch, session: session) { files in
                        defer { group.leave() }
                        guard let files, files.contains(fileName) else { return }
                        lock.lock()
                        if !hits.contains(where: { $0.repo == repo }) {
                            hits.append((repo, branch))
                        }
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .global(qos: .utility)) {
                session.invalidateAndCancel()
                guard !hits.isEmpty else {
                    completion([])
                    return
                }
                // 官方仓库排最前，第三方转存留作后备；都只用镜像域名，
                // 上游 huggingface 在国内基本连不上，放进队列只会白白耗时间。
                let ordered = hits.sorted { a, b in
                    let ao = a.repo.lowercased().contains("hoppou")
                    let bo = b.repo.lowercased().contains("hoppou")
                    return ao && !bo
                }
                var sources: [ModelSource] = []
                for hit in ordered.prefix(4) {
                    let base = "\(mirror)/\(hit.repo)/resolve/\(hit.branch)"
                    guard !excluding.contains(base) else { continue }
                    let short = hit.repo.split(separator: "/").last.map(String.init) ?? hit.repo
                    sources.append(ModelSource(base: base,
                                               label: short.lowercased().contains("hoppou")
                                                   ? "官方镜像" : short))
                }
                completion(sources)
            }
        }
    }

    private static func searchRepos(api: String, query: String, session: URLSession,
                                    completion: @escaping ([String]?) -> Void) {
        guard let url = URL(string: "\(api)/api/models?search=\(query)&limit=20") else {
            completion(nil)
            return
        }
        session.dataTask(with: decorate(url)) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil)
                return
            }
            completion(arr.compactMap { $0["id"] as? String })
        }.resume()
    }

    private static func treeFiles(repo: String, branch: String, session: URLSession,
                                  completion: @escaping (Set<String>?) -> Void) {
        guard let url = URL(string: "\(mirror)/api/models/\(repo)/tree/\(branch)") else {
            completion(nil)
            return
        }
        session.dataTask(with: decorate(url)) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil)
                return
            }
            completion(Set(arr.compactMap { $0["path"] as? String }))
        }.resume()
    }
}

// MARK: - 下载器

/// 多连接分段下载器。
///
/// 为什么这么做：镜像把 `/resolve/` 302 到境外 CDN，单连接实测只有几十 KB/s，
/// 而 CDN 对单连接限速、对并发连接相对宽松——实测 16 连接能把吞吐拉高 5 倍。
/// 所以这里把文件切成 16 MB 的段，最多 12 个并发拉取，每个连接独立 Range。
///
/// 两个「过期」问题都在这里兜住：
/// * **签名过期**——302 得到的 CDN 地址带 `X-Amz-Expires=3600`（1 小时）。
///   每个分片请求都重新走一次 `resolve`，永远拿新签名，不会因为下载超过一小时而 403。
/// * **源失效**——某个源连续失败就换下一个；全部用尽后调用
///   `ModelSourceFinder.discover` 自动搜索别的仓库，找到再继续，随后端服务无感。
final class ModelDownloader: NSObject, ObservableObject {

    struct TaskState: Equatable {
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var isDownloading = false
        var errorMessage: String?
        /// 最近几秒的平均速度（字节/秒）。
        var bytesPerSecond: Double = 0
        /// 自动重试/换源次数。
        var attempt: Int = 0
        /// 当前使用的源，例如 `hf-mirror`。
        var sourceLabel: String = ""
        /// 并行连接数。
        var parallel: Int = 0
        /// 已完成 / 总段数。
        var segmentsDone: Int = 0
        var segmentsTotal: Int = 0
        /// 内置源全挂、正在联网搜索新源。
        var isSearching = false

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(receivedBytes) / Double(totalBytes))
        }

        /// 已发出请求但一个字节都还没到——通常是在连 CDN 或等首包。
        var isConnecting: Bool { isDownloading && receivedBytes == 0 }

        var etaSeconds: Double? {
            guard isDownloading, bytesPerSecond > 4096, totalBytes > receivedBytes else { return nil }
            return Double(totalBytes - receivedBytes) / bytesPerSecond
        }
    }

    /// 同时拉取的段数。CDN 对并发相对宽松，12 路在实测中比单路快 5 倍。
    static let maxParallel = 12
    /// 每段大小。
    static let segmentSize: Int64 = 16 * 1024 * 1024
    /// 单段最少 4 MB，避免小文件被切成碎片。
    static let minSegmentSize: Int64 = 4 * 1024 * 1024
    /// 单段在同源上重试次数，超过就换源。
    static let retriesPerSegment = 4
    /// 同一源累计失败这么多次且毫无进展，判定该源失效。
    static let failuresBeforeRotate = 6

    @Published private(set) var states: [String: TaskState] = [:]

    private var session: URLSession!
    private var transfers: [String: Transfer] = [:]
    private var taskIndex: [Int: TaskRef] = [:]
    private let indexLock = NSLock()
    private var ticker: DispatchSourceTimer?

    // MARK: 内部类型

    fileprivate final class Segment {
        let start: Int64
        let end: Int64          // inclusive
        private(set) var received: Int64 = 0
        var failures = 0
        var handle: FileHandle?
        private let lock = NSLock()

        init(start: Int64, end: Int64) { self.start = start; self.end = end }

        var length: Int64 { end - start + 1 }
        var remaining: Int64 { max(0, length - received) }
        var complete: Bool { received >= length }
        var nextOffset: Int64 { start + received }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard let handle, received < length else { return }
            let take = Int(min(Int64(data.count), length - received))
            guard take > 0 else { return }
            let chunk = take == data.count ? data : Data(data.prefix(take))
            do {
                try handle.seek(toOffset: UInt64(start + received))
                try handle.write(contentsOf: chunk)
                received += Int64(take)
            } catch {
                // 磁盘写失败：不再推进 offset，交由上层按失败处理。
            }
        }

        func snapshot() -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return received
        }

        func closeHandle() {
            lock.lock(); defer { lock.unlock() }
            try? handle?.close()
            handle = nil
        }

        /// 从 manifest 恢复：直接标记为已完成，不再联网。
        func markComplete() {
            lock.lock(); defer { lock.unlock() }
            received = length
        }
    }

    fileprivate final class TaskRef {
        let specID: String
        let segment: Segment
        var httpError: String?
        var unsupportedRange = false
        init(specID: String, segment: Segment) {
            self.specID = specID
            self.segment = segment
        }
    }

    private final class Transfer {
        let spec: ModelSpec
        let total: Int64
        let tempURL: URL
        let manifestURL: URL
        var sources: [ModelSource]
        var sourceIndex = 0
        var segments: [Segment] = []
        var pending: [Segment] = []
        var active: [Int: Segment] = [:]
        var samples: [(Date, Int64)] = []
        var rotating = false
        var discovering = false
        var finished = false
        var started = false
        var cancelled = false
        var activeURL: URL?
        /// 当前源下累计失败次数（换源时清零）。
        var failuresThisSource = 0
        /// 切到当前源时已经下载的字节数，用来判断「有没有进展」。
        var bytesAtSourceStart: Int64 = 0
        var note: String?
        var searchingNote = false

        init(spec: ModelSpec, sources: [ModelSource]) {
            self.spec = spec
            self.total = spec.bytes
            self.tempURL = Paths.models.appendingPathComponent(spec.fileName + ".download")
            self.manifestURL = Paths.models.appendingPathComponent(spec.fileName + ".download.json")
            self.sources = sources
        }

        var sourceLabel: String {
            guard sourceIndex < sources.count else { return sources.last?.label ?? "" }
            return sources[sourceIndex].label
        }

        var receivedTotal: Int64 { segments.reduce(0) { $0 + $1.received } }
        var doneCount: Int { segments.filter { $0.complete }.count }
    }

    private struct Manifest: Codable {
        var total: Int64
        var done: [Int64]
    }

    // MARK: 生命周期

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        // 30 秒内连不上/收不到任何数据就判失败，交给重试逻辑；
        // 绝不用 waitsForConnectivity，那样会永久静默挂起。
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 关键：默认同 host 只有 6 条连接，会卡住 12 路并发。
        config.httpMaximumConnectionsPerHost = ModelDownloader.maxParallel + 4
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.35)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    deinit { ticker?.cancel() }

    func state(for spec: ModelSpec) -> TaskState {
        states[spec.id] ?? TaskState(receivedBytes: min(spec.installedSize, spec.bytes), totalBytes: spec.bytes)
    }

    /// 供「复制下载链接」用的直链。
    func directLink(for spec: ModelSpec) -> String {
        spec.downloadURL?.absoluteString ?? ""
    }

    // MARK: 开始 / 暂停 / 删除

    func start(_ spec: ModelSpec) {
        DispatchQueue.main.async { self.begin(spec) }
    }

    private func begin(_ spec: ModelSpec) {
        if let existing = transfers[spec.id], existing.started, !existing.finished { return }

        Paths.ensureDirectories()

        if Paths.size(of: spec.fileURL) == spec.bytes {
            publish(spec, TaskState(receivedBytes: spec.bytes, totalBytes: spec.bytes, isDownloading: false))
            return
        }

        let transfer = Transfer(spec: spec, sources: ModelSourceFinder.builtin)
        prepare(transfer)
        transfers[spec.id] = transfer

        publish(spec, TaskState(receivedBytes: transfer.receivedTotal, totalBytes: spec.bytes,
                                isDownloading: true, errorMessage: nil, bytesPerSecond: 0,
                                attempt: 0, sourceLabel: "连接中", parallel: 0,
                                segmentsDone: transfer.doneCount, segmentsTotal: transfer.segments.count))

        // 源速度实测放后台，别卡住主线程；探测完再开跑。
        DispatchQueue.global(qos: .utility).async {
            let ranked = ModelSourceFinder.rank(sources: transfer.sources, fileName: spec.fileName)
            DispatchQueue.main.async {
                guard self.transfers[spec.id] === transfer, !transfer.finished else { return }
                let merged = ranked.ok + ranked.dead
                if !merged.isEmpty { transfer.sources = merged }
                transfer.started = true
                self.activateSource(transfer)
            }
        }
    }

    /// 建立文件、恢复已完成段、生成分段计划。
    private func prepare(_ transfer: Transfer) {
        let fm = FileManager.default

        // 旧版单流下载留下的是正式文件名但不完整，直接清掉避免与新流程混淆。
        if Paths.exists(transfer.spec.fileURL), Paths.size(of: transfer.spec.fileURL) != transfer.total {
            try? fm.removeItem(at: transfer.spec.fileURL)
        }

        var done = Set<Int64>()
        if let data = try? Data(contentsOf: transfer.manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.total == transfer.total {
            done = Set(manifest.done)
        } else {
            done = []
            try? fm.removeItem(at: transfer.tempURL)
        }

        if !fm.fileExists(atPath: transfer.tempURL.path) {
            fm.createFile(atPath: transfer.tempURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: transfer.tempURL) {
            try? handle.truncate(atOffset: UInt64(transfer.total))
            try? handle.close()
        }

        transfer.segments = Self.makeSegments(total: transfer.total)
        for segment in transfer.segments where done.contains(segment.start) {
            segment.markComplete()
        }
        transfer.pending = transfer.segments.filter { !$0.complete }
    }

    private static func makeSegments(total: Int64) -> [Segment] {
        guard total > 0 else { return [] }
        var count = Int((total + segmentSize - 1) / segmentSize)
        let maxCount = max(1, Int(total / minSegmentSize))
        count = max(1, min(max(count, 1), maxCount))
        let per = (total + Int64(count) - 1) / Int64(count)
        var segments: [Segment] = []
        var offset: Int64 = 0
        while offset < total {
            let end = min(total - 1, offset + per - 1)
            segments.append(Segment(start: offset, end: end))
            offset = end + 1
        }
        return segments
    }

    func cancel(_ spec: ModelSpec) {
        DispatchQueue.main.async {
            guard let transfer = self.transfers[spec.id] else { return }
            transfer.cancelled = true
            self.cancelActive(transfer)
            for segment in transfer.segments { segment.closeHandle() }
            self.persist(transfer)
            self.publish(spec, TaskState(receivedBytes: transfer.receivedTotal,
                                        totalBytes: transfer.total,
                                        isDownloading: false,
                                        errorMessage: "已暂停，可继续",
                                        sourceLabel: transfer.sourceLabel,
                                        segmentsDone: transfer.doneCount,
                                        segmentsTotal: transfer.segments.count))
            self.transfers.removeValue(forKey: spec.id)
        }
    }

    func deleteFile(_ spec: ModelSpec) {
        DispatchQueue.main.async {
            if let transfer = self.transfers[spec.id] {
                self.cancelActive(transfer)
                transfer.finished = true
                for segment in transfer.segments { segment.closeHandle() }
                self.transfers.removeValue(forKey: spec.id)
            }
            try? FileManager.default.removeItem(at: spec.fileURL)
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(spec.fileName + ".download"))
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(spec.fileName + ".download.json"))
            self.publish(spec, TaskState(receivedBytes: 0, totalBytes: spec.bytes))
        }
    }

    // MARK: 调度

    private func pump(_ transfer: Transfer) {
        guard !transfer.finished, !transfer.cancelled, !transfer.rotating,
              let base = transfer.activeURL else { return }

        while transfer.active.count < Self.maxParallel, !transfer.pending.isEmpty {
            let segment = transfer.pending.removeFirst()
            // 换源时同一段可能被多次放回队列，这里去重，避免两个连接写同一块。
            guard !segment.complete,
                  !transfer.active.values.contains(where: { $0 === segment }) else { continue }
            launch(transfer, segment: segment, url: base)
        }

        if transfer.active.isEmpty && transfer.pending.isEmpty {
            completeIfReady(transfer)
        }
    }

    private func launch(_ transfer: Transfer, segment: Segment, url: URL) {
        if segment.handle == nil {
            segment.handle = try? FileHandle(forWritingTo: transfer.tempURL)
        }
        guard segment.handle != nil else {
            fail(transfer, message: "无法写入文件（检查磁盘空间是否充足）")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("BreezeTTS/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // 每次请求都重新走 resolve，302 会给出新的 CDN 签名，天然规避 1 小时过期。
        request.setValue("bytes=\(segment.nextOffset)-\(segment.end)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        let ref = TaskRef(specID: transfer.spec.id, segment: segment)
        indexLock.lock()
        taskIndex[task.taskIdentifier] = ref
        indexLock.unlock()
        transfer.active[task.taskIdentifier] = segment
        task.resume()
    }

    private func tick() {
        for transfer in transfers.values where transfer.started && !transfer.finished {
            publishStats(transfer)
        }
    }

    private func publishStats(_ transfer: Transfer) {
        let received = transfer.receivedTotal
        let now = Date()
        transfer.samples.append((now, received))
        transfer.samples.removeAll { now.timeIntervalSince($0.0) > 5 }

        var speed: Double = 0
        if let first = transfer.samples.first, transfer.samples.count > 1 {
            let span = now.timeIntervalSince(first.0)
            if span > 0.6 { speed = Double(received - first.1) / span }
        }

        var state = TaskState(receivedBytes: received,
                              totalBytes: transfer.total,
                              isDownloading: true,
                              errorMessage: nil,
                              bytesPerSecond: max(0, speed),
                              attempt: transfer.sourceIndex,
                              sourceLabel: transfer.sourceLabel,
                              parallel: transfer.active.count,
                              segmentsDone: transfer.doneCount,
                              segmentsTotal: transfer.segments.count)
        state.isSearching = transfer.searchingNote
        publish(transfer.spec, state)
    }

    private func completeIfReady(_ transfer: Transfer) {
        guard transfer.pending.isEmpty, transfer.active.isEmpty else { return }
        guard transfer.segments.allSatisfy({ $0.complete }) else { return }
        finish(transfer)
    }

    private func finish(_ transfer: Transfer) {
        guard !transfer.finished else { return }
        transfer.finished = true
        for segment in transfer.segments { segment.closeHandle() }

        let size = Paths.size(of: transfer.tempURL)
        guard size == transfer.total else {
            fail(transfer, message: "大小校验失败（\(size.humanBytes) / \(transfer.total.humanBytes)），请重试")
            return
        }

        let fm = FileManager.default
        try? fm.removeItem(at: transfer.spec.fileURL)
        do {
            try fm.moveItem(at: transfer.tempURL, to: transfer.spec.fileURL)
        } catch {
            fail(transfer, message: "无法保存模型文件：\(error.localizedDescription)")
            return
        }
        try? fm.removeItem(at: transfer.manifestURL)
        transfers.removeValue(forKey: transfer.spec.id)

        publish(transfer.spec, TaskState(receivedBytes: transfer.total, totalBytes: transfer.total,
                                         isDownloading: false, sourceLabel: transfer.sourceLabel,
                                         segmentsDone: transfer.segments.count,
                                         segmentsTotal: transfer.segments.count))
    }

    private func fail(_ transfer: Transfer, message: String) {
        transfer.finished = true
        cancelActive(transfer)
        for segment in transfer.segments { segment.closeHandle() }
        persist(transfer)
        transfers.removeValue(forKey: transfer.spec.id)
        publish(transfer.spec, TaskState(receivedBytes: transfer.receivedTotal,
                                         totalBytes: transfer.total,
                                         isDownloading: false,
                                         errorMessage: message,
                                         sourceLabel: transfer.sourceLabel,
                                         segmentsDone: transfer.doneCount,
                                         segmentsTotal: transfer.segments.count))
    }

    // MARK: 失败与换源

    /// 一个分片结束（正常或异常）后回调，主队列。
    private func segmentEnded(_ transfer: Transfer, segment: Segment, ref: TaskRef, error: Error?) {
        guard !transfer.finished else { return }

        if segment.complete {
            segment.closeHandle()
            persist(transfer)
            pump(transfer)
            return
        }

        if transfer.rotating {
            // 换源期间不复位状态，但分片要回到队列，否则会永久丢失。
            if !segment.complete,
               !transfer.pending.contains(where: { $0 === segment }) {
                transfer.pending.insert(segment, at: 0)
            }
            return
        }
        if let error, (error as NSError).code == NSURLErrorCancelled { return }

        let reason = ref.unsupportedRange
            ? "该源不支持分段下载"
            : (ref.httpError ?? error.map { Self.describe($0 as NSError) } ?? "连接被中断")
        transfer.note = reason
        segment.closeHandle()
        reuse(transfer, segment)

        // 源明确不支持 Range：留着只会一直写错位置，直接换。
        if ref.unsupportedRange {
            rotate(transfer, reason: reason)
            return
        }

        transfer.failuresThisSource += 1
        let progressed = transfer.receivedTotal > transfer.bytesAtSourceStart

        // 一堆分片同时失败且一个字节都没进账 —— 这个源基本可以放弃了。
        if transfer.failuresThisSource >= Self.failuresBeforeRotate && !progressed {
            rotate(transfer, reason: reason)
            return
        }

        segment.failures += 1
        if segment.failures <= Self.retriesPerSegment {
            let delay = 1.2 * Double(segment.failures)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.transfers[transfer.spec.id] === transfer,
                      !transfer.finished, !transfer.rotating, !segment.complete else { return }
                self.reuse(transfer, segment)
                self.pump(transfer)
            }
        } else {
            // 单段在同一源上反复失败，说明这个源对这一块就是不行。
            segment.failures = 0
            rotate(transfer, reason: reason)
        }
    }

    /// 把分片放回待下载队列（去重）。
    private func reuse(_ transfer: Transfer, _ segment: Segment) {
        guard !segment.complete,
              !transfer.pending.contains(where: { $0 === segment }),
              !transfer.active.values.contains(where: { $0 === segment }) else { return }
        transfer.pending.insert(segment, at: 0)
    }

    /// 启用当前序号对应的源，直接铺满 12 路分片。
    ///
    /// 这里刻意不做预探测：部分网络建立到 CDN 的连接本身就要 3–10 秒，
    /// 任何短超时的探测都会把好源误判成失效。改用「零进展才换源」——
    /// 源真的坏时 12 个分片会同时快速失败（404 约 3 秒），比探测更准。
    private func activateSource(_ transfer: Transfer) {
        guard !transfer.finished, !transfer.cancelled else { return }
        guard transfer.sourceIndex < transfer.sources.count else {
            discoverSources(transfer)
            return
        }
        let source = transfer.sources[transfer.sourceIndex]
        guard let url = source.url(for: transfer.spec.fileName) else {
            transfer.sourceIndex += 1
            activateSource(transfer)
            return
        }

        transfer.rotating = false
        transfer.searchingNote = false
        transfer.activeURL = url
        transfer.failuresThisSource = 0
        transfer.bytesAtSourceStart = transfer.receivedTotal
        publishStats(transfer)
        pump(transfer)
    }

    /// 换到下一个源。
    private func rotate(_ transfer: Transfer, reason: String?) {
        guard !transfer.rotating, !transfer.finished else { return }
        transfer.rotating = true
        transfer.note = reason
        cancelActive(transfer)
        transfer.sourceIndex += 1
        activateSource(transfer)
    }

    /// 所有候选源都不行，联网搜索还有谁存着这个模型。
    private func discoverSources(_ transfer: Transfer) {
        guard !transfer.discovering, !transfer.finished else { return }
        transfer.discovering = true
        transfer.rotating = true
        transfer.searchingNote = true
        publishStats(transfer)

        let spec = transfer.spec
        let known = Set(transfer.sources.map { $0.base })
        ModelSourceFinder.discover(fileName: spec.fileName, excluding: known) { raw in
            DispatchQueue.global(qos: .utility).async {
                var found = raw
                if !found.isEmpty {
                    let ranked = ModelSourceFinder.rank(sources: found, fileName: spec.fileName)
                    found = ranked.ok + ranked.dead
                }
                DispatchQueue.main.async {
                    guard self.transfers[spec.id] === transfer, !transfer.finished else { return }
                    transfer.discovering = false
                    transfer.searchingNote = false
                    guard !found.isEmpty else {
                        self.fail(transfer, message: Self.giveUpMessage(reason: transfer.note))
                        return
                    }
                    // sourceIndex 此时正好指向追加进来的第一个新源。
                    transfer.sources.append(contentsOf: found)
                    self.publishStats(transfer)
                    self.activateSource(transfer)
                }
            }
        }
    }

    private func cancelActive(_ transfer: Transfer) {
        let ids = Array(transfer.active.keys)
        transfer.active.removeAll()
        // 未完成的段回到队列，从当前偏移续传。
        for id in ids {
            indexLock.lock()
            let ref = taskIndex.removeValue(forKey: id)
            indexLock.unlock()
            if let ref, !ref.segment.complete,
               !transfer.pending.contains(where: { $0 === ref.segment }) {
                transfer.pending.insert(ref.segment, at: 0)
            }
        }
        session.getTasksWithCompletionHandler { _, _, tasks in
            for task in tasks where ids.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }

    private static func describe(_ ns: NSError) -> String {
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed, NSURLErrorCannotFindHost:
            return "连不上模型服务器"
        default:
            return ns.localizedDescription
        }
    }

    private static func giveUpMessage(reason: String?) -> String {
        var text = "所有下载源都不可用"
        if let reason, !reason.isEmpty { text += "（最后一次失败：\(reason)）" }
        text += "。镜像会跳到境外 CDN，部分网络需要挂代理；"
        text += "也可以点「复制下载链接」用浏览器下好 .gguf 再「导入」。"
        return text
    }

    // MARK: 持久化与发布

    private func persist(_ transfer: Transfer) {
        let done = transfer.segments.filter { $0.complete }.map { $0.start }
        let manifest = Manifest(total: transfer.total, done: done)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: transfer.manifestURL, options: .atomic)
    }

    private func publish(_ spec: ModelSpec, _ state: TaskState) {
        states[spec.id] = state
    }

    private func ref(for task: URLSessionTask) -> TaskRef? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return taskIndex[task.taskIdentifier]
    }

    private func takeRef(for task: URLSessionTask) -> TaskRef? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return taskIndex.removeValue(forKey: task.taskIdentifier)
    }
}

// MARK: - URLSession

extension ModelDownloader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let ref = ref(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }

        switch http.statusCode {
        case 206:
            // 校验服务端给的是不是我们要的那一段，防止写错位置。
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let lower = range.split(separator: " ").dropFirst().first,
               let startText = lower.split(separator: "-").first,
               let serverStart = Int64(startText),
               serverStart != ref.segment.nextOffset {
                ref.httpError = "源返回了错误的数据区间"
                completionHandler(.cancel)
                return
            }
            ref.httpError = nil
        case 200:
            // 不支持 Range（直接吐整个文件）会把分片写乱，立即换源。
            ref.unsupportedRange = true
            completionHandler(.cancel)
            return
        case 403:
            // CDN 签名过期或拒绝访问：换一次源并重新 resolve。
            ref.httpError = "源拒绝访问（403，签名可能已过期）"
            completionHandler(.cancel)
            return
        case 404:
            ref.httpError = "该源上找不到这个文件（404）"
            completionHandler(.cancel)
            return
        case 416:
            ref.httpError = "续传位置无效（416）"
            completionHandler(.cancel)
            return
        default:
            ref.httpError = "服务器返回 \(http.statusCode)"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let ref = ref(for: dataTask) else { return }
        ref.segment.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ref = takeRef(for: task) else { return }
        DispatchQueue.main.async {
            guard let transfer = self.transfers[ref.specID] else { return }
            transfer.active.removeValue(forKey: task.taskIdentifier)
            self.segmentEnded(transfer, segment: ref.segment, ref: ref, error: error)
        }
    }
}
