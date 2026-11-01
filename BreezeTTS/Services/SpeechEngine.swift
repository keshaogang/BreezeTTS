import Foundation

/// Owns the C context for the whole app lifetime.
///
/// Rules taken straight from the engine docs:
/// * a context is not reentrant, so every generate call runs on one serial queue
///   and the ObjC wrapper holds a lock as a second line of defence;
/// * `breeze_generate` blocks, so it never touches the main thread;
/// * audio buffers are only valid inside the callback, so they are copied in the
///   bridge before Swift sees them;
/// * the context holds several GB of weights, so it is built once and reused.
final class SpeechEngine {
    static let shared = SpeechEngine()

    private let loadQueue = DispatchQueue(label: "breeze.load", qos: .userInitiated)
    private let genQueue = DispatchQueue(label: "breeze.generate", qos: .userInitiated)
    private let stateLock = NSLock()

    private var engine: BreezeEngine?
    private var cancelFlag = false

    private(set) var loadedPath: String?
    private(set) var sampleRate: Double = 24_000
    /// Compute backend ggml resolved to ("Metal" / "CPU"). Empty until a model loads.
    private(set) var backendName: String = ""

    private init() {}

    var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engine != nil
    }

    /// Loads (or reloads) a model. Completion always fires on the main thread.
    func load(path: String, useGPU: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        loadQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let alreadyLoaded = (self.engine != nil && self.loadedPath == path)
            self.stateLock.unlock()

            if alreadyLoaded {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            self.stateLock.lock()
            let previous = self.engine
            self.engine = nil
            self.loadedPath = nil
            self.stateLock.unlock()
            previous?.shutdown()

            let started = Date()
            let created = BreezeEngine(modelPath: path, useGPU: useGPU)
            let elapsed = Date().timeIntervalSince(started)

            if let created {
                self.stateLock.lock()
                self.engine = created
                self.loadedPath = path
                self.sampleRate = Double(created.sampleRate)
                self.backendName = created.backendName
                self.stateLock.unlock()
                NSLog("BreezeTTS: model loaded in \(String(format: "%.1f", elapsed))s, \(Int(created.sampleRate)) Hz, backend \(created.backendName)")
                DispatchQueue.main.async { completion(.success(())) }
            } else {
                let detail = BreezeEngine.lastErrorMessage()
                let err = NSError(domain: "BreezeTTS.Engine", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "加载模型失败" : detail])
                DispatchQueue.main.async { completion(.failure(err)) }
            }
        }
    }

    func unload() {
        stateLock.lock()
        let old = engine
        engine = nil
        loadedPath = nil
        backendName = ""
        stateLock.unlock()
        old?.shutdown()
    }

    /// Streams audio chunks (24 kHz mono float) back on the main thread.
    /// `completion` also fires on the main thread with every sample collected.
    ///
    /// `streaming = false` decodes the whole clip in one vocoder flush: measured
    /// ~40% faster end to end (RTF 8.9 → 5.1) because the sliding-window overlap
    /// is no longer recomputed per flush, at the cost of no audio until done.
    func generate(text: String,
                  params: GenParams,
                  refAudio: [Float]?,
                  refText: String?,
                  streaming: Bool = true,
                  onChunk: @escaping ([Float]) -> Void,
                  completion: @escaping (Result<[Float], Error>) -> Void) {
        stateLock.lock()
        cancelFlag = false
        let current = engine
        stateLock.unlock()

        guard let current else {
            completion(.failure(NSError(domain: "BreezeTTS.Engine", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "尚未加载模型"])))
            return
        }

        let refData: Data?
        if let refAudio, !refAudio.isEmpty {
            refData = refAudio.withUnsafeBufferPointer { Data(buffer: $0) }
        } else {
            refData = nil
        }

        genQueue.async { [weak self] in
            guard let self else { return }
            var collected: [Float] = []
            var failure: NSError?

            let ok = current.generate(
                withText: text,
                instruction: params.instruction,
                refText: refText,
                refAudioSamples: refData,
                cfgScale: params.cfgScale,
                seed: params.seed,
                maxNewTokens: params.maxNewTokens,
                splitChars: params.splitChars,
                temperature: params.temperature,
                topK: params.topK,
                topP: params.topP,
                repetitionPenalty: params.repetitionPenalty,
                chunkFirst: streaming ? 0 : 200,
                chunkMax: streaming ? 0 : 200,
                onChunk: { payload, stop in
                    let count = payload.count / MemoryLayout<Float>.size
                    guard count > 0 else { return }
                    var chunk = [Float](repeating: 0, count: count)
                    chunk.withUnsafeMutableBytes { raw in
                        _ = payload.copyBytes(to: raw)
                    }
                    collected.append(contentsOf: chunk)
                    if self.isCancelled {
                        stop.pointee = true
                    }
                    DispatchQueue.main.async {
                        onChunk(chunk)
                    }
                }
            )

            if !ok && !self.isCancelled {
                let message = BreezeEngine.lastErrorMessage()
                failure = NSError(domain: "BreezeTTS.Engine", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "生成失败" : message])
            }

            let result = collected
            DispatchQueue.main.async {
                if let failure {
                    completion(.failure(failure))
                } else {
                    completion(.success(result))
                }
            }
        }
    }

    func cancel() {
        stateLock.lock()
        cancelFlag = true
        stateLock.unlock()
    }

    var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelFlag
    }

    /// Whole-file export path, useful for batch work without playback.
    func generateToWAV(text: String,
                       params: GenParams,
                       refAudio: [Float]?,
                       refText: String?,
                       outURL: URL,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        stateLock.lock()
        let current = engine
        stateLock.unlock()
        guard let current else {
            completion(.failure(NSError(domain: "BreezeTTS.Engine", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "尚未加载模型"])))
            return
        }
        let refData = refAudio.flatMap { $0.isEmpty ? nil : $0.withUnsafeBufferPointer { Data(buffer: $0) } }

        genQueue.async {
            let ok = current.generateWAV(
                withText: text,
                instruction: params.instruction,
                refText: refText,
                refAudioSamples: refData,
                cfgScale: params.cfgScale,
                seed: params.seed,
                maxNewTokens: params.maxNewTokens,
                splitChars: params.splitChars,
                temperature: params.temperature,
                topK: params.topK,
                topP: params.topP,
                repetitionPenalty: params.repetitionPenalty,
                outPath: outURL.path
            )
            DispatchQueue.main.async {
                if ok {
                    completion(.success(()))
                } else {
                    let detail = BreezeEngine.lastErrorMessage()
                    completion(.failure(NSError(domain: "BreezeTTS.Engine", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "导出失败" : detail])))
                }
            }
        }
    }
}
