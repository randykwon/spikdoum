import Foundation
import AVFoundation
import FluidAudio

/// Manages NVIDIA Parakeet TDT v3 CoreML model lifecycle on the Apple Neural Engine (ANE).
/// Delivers ~60–150ms transcription latency across English and 24 European languages with zero HTTP overhead.
@MainActor
final class ParakeetModelManager: ObservableObject {
    @Published private(set) var isCachedOnDisk = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isPreparing = false
    @Published private(set) var statusMessage = "미설치"
    @Published private(set) var lastLatencyMS: Int? = nil
    @Published var lastError: String? = nil

    private var asrManager: AsrManager?
    private var decoderLayers = 2
    private var prepareTask: Task<AsrManager, Error>?

    init() {
        refreshCacheStatus()
    }

    func refreshCacheStatus() {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        isCachedOnDisk = AsrModels.modelsExist(at: dir, version: .v3)
        if isLoaded {
            statusMessage = "ANE 준비 완료"
        } else if isCachedOnDisk {
            statusMessage = "설치됨 (첫 시작 시 ANE 로드)"
        } else {
            statusMessage = "미설치 (~600MB CoreML)"
        }
    }

    @discardableResult
    func ensureReady() async throws -> AsrManager {
        if let existing = asrManager, isLoaded {
            return existing
        }
        if let running = prepareTask {
            return try await running.value
        }
        isPreparing = true
        lastError = nil
        statusMessage = isCachedOnDisk ? "Parakeet ANE 모델 로딩 중…" : "Parakeet CoreML 다운로드 · ANE 컴파일 중…"
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let mgr = AsrManager(config: .default, models: models)
            return mgr
        }
        prepareTask = task
        defer {
            prepareTask = nil
            isPreparing = false
        }
        do {
            let mgr = try await task.value
            asrManager = mgr
            decoderLayers = await mgr.decoderLayerCount
            isCachedOnDisk = true
            isLoaded = true
            statusMessage = "ANE 준비 완료"
            return mgr
        } catch {
            lastError = "Parakeet ANE 준비 실패: \(error.localizedDescription)"
            statusMessage = "준비 실패"
            throw error
        }
    }

    func transcribe(pcm16Data: Data) async throws -> String {
        let mgr = try await ensureReady()
        let samples = Self.pcm16ToFloats(pcm16Data)
        guard samples.count >= 1600 else { return "" }
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await mgr.transcribe(samples, decoderState: &state)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        lastLatencyMS = elapsed
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func pcm16ToFloats(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                floats[i] = Float(Int16(littleEndian: ints[i])) / 32768.0
            }
        }
        return floats
    }
}

/// Real-time ANE capture pipeline powered by FluidAudio's Parakeet TDT v3 CoreML model.
/// Supports microphone, Mac playback (externalAudio), sliding-window live interim captions, and instant zero-interruption mute.
@MainActor
final class ParakeetSpeechCapture {
    private var engine: AVAudioEngine?
    private let bufferer = ManagedAudioBufferer()
    private let muteFlag = AudioMuteFlag()
    private var pending: [Data] = []
    private var worker: Task<Void, Never>?
    private var interimTask: Task<Void, Never>?
    private var agreement = LocalAgreementTracker()
    private var generation = UUID()
    private var active = false
    private var text = ""
    private var interimText = ""
    private var lastCleanChunk = ""
    private var onText: ((String) -> Void)?
    private var onInterimText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onLatency: ((Int) -> Void)?
    private var routeObserver: NSObjectProtocol?
    private var audioStartedAt = Date.distantPast
    private weak var modelManager: ParakeetModelManager?

    func start(
        modelManager: ParakeetModelManager,
        externalAudio: Bool,
        inputDeviceUID: String,
        interimInterval: TimeInterval? = 0.28,
        onText: @escaping (String) -> Void,
        onInterim: ((String) -> Void)? = nil,
        onError: @escaping (String) -> Void,
        onLatency: @escaping (Int) -> Void,
        onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        _ = try await modelManager.ensureReady()

        self.modelManager = modelManager
        self.onText = onText
        self.onInterimText = onInterim
        self.onError = onError
        self.onLatency = onLatency
        text = ""
        interimText = ""
        lastCleanChunk = ""
        agreement.reset()
        active = true
        let token = generation

        bufferer.start(interimInterval: interimInterval, onInterim: interimInterval == nil ? nil : { [weak self] data in
            Task { @MainActor in
                guard let self, self.active, self.generation == token else { return }
                self.runInterim(data, token: token)
            }
        }, onChunk: { [weak self] data in
            Task { @MainActor in
                guard let self, self.active, self.generation == token else { return }
                self.enqueue(data)
            }
        })

        if externalAudio { return }
        let configured = try AudioInputDevices.configuredEngine(uid: inputDeviceUID)
        let engine = configured.engine
        let input = engine.inputNode
        let format = configured.format
        let bufferer = bufferer
        let muteFlag = muteFlag
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard !muteFlag.isMuted else { return }
            bufferer.append(buffer)
            onAudioBuffer?(buffer)
        }
        self.engine = engine
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
        audioStartedAt = Date()
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.generation == token, self.engine === engine else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard self.active, self.generation == token, self.engine === engine else { return }
                if engine.isRunning && Date().timeIntervalSince(self.audioStartedAt) < 1.5 { return }
                if engine.isRunning { return }
                self.onError?("[AUDIO_ROUTE_CHANGED] Parakeet 마이크 입력 형식이 변경되었습니다.")
            }
        }
    }

    func setMuted(_ value: Bool) {
        muteFlag.set(value)
        bufferer.setMuted(value)
    }

    nonisolated func appendExternalAudio(_ buffer: AVAudioPCMBuffer) {
        bufferer.append(buffer)
    }

    private func publishInterimText() {
        if let onInterimText {
            onInterimText(interimText)
        } else {
            let combined = [text, interimText].filter { !$0.isEmpty }.joined(separator: "\n")
            if !combined.isEmpty { onText?(combined) }
        }
    }

    private func runInterim(_ pcm: Data, token: UUID) {
        guard interimTask == nil, pending.isEmpty, worker == nil, let mgr = modelManager else { return }
        interimTask = Task { [weak self] in
            defer { Task { @MainActor in self?.interimTask = nil } }
            let started = Date()
            do {
                let raw = try await mgr.transcribe(pcm16Data: pcm)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.active, self.generation == token, self.pending.isEmpty else { return }
                    self.onLatency?(Int(Date().timeIntervalSince(started) * 1000))
                    if let cleaned = ManagedSTTPolicy.sanitize(raw, previousChunk: self.lastCleanChunk) {
                        let stabilized = self.agreement.update(hypothesis: cleaned)
                        if !stabilized.isEmpty && stabilized != self.interimText {
                            self.interimText = stabilized
                            self.publishInterimText()
                        }
                    }
                }
            } catch {
                // Interim miss is non-fatal.
            }
        }
    }

    private func enqueue(_ pcm: Data) {
        interimTask?.cancel()
        interimTask = nil
        if pending.count >= 24 { pending.removeFirst() }
        pending.append(pcm)
        if worker == nil { runWorker() }
    }

    private func runWorker() {
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.worker = nil
                    if self.active && self.pending.isEmpty {
                        self.bufferer.requestImmediateInterimIfVoiced()
                    }
                }
            }
            while !Task.isCancelled && self.generation == token && !self.pending.isEmpty {
                let data = self.pending.removeFirst()
                guard let mgr = self.modelManager else { return }
                let started = Date()
                do {
                    let raw = try await mgr.transcribe(pcm16Data: data)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.onLatency?(Int(Date().timeIntervalSince(started) * 1000))
                    self.interimText = ""
                    self.agreement.reset()
                    self.onInterimText?("")
                    if let cleaned = ManagedSTTPolicy.sanitize(raw, previousChunk: self.lastCleanChunk) {
                        self.lastCleanChunk = cleaned
                        self.text = [self.text, cleaned].filter { !$0.isEmpty }.joined(separator: "\n")
                        self.onText?(self.text)
                    } else if self.onInterimText == nil && !self.text.isEmpty {
                        self.onText?(self.text)
                    }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.onError?("Parakeet ANE STT 실패: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    func finish() async {
        stopMicrophone()
        interimTask?.cancel(); interimTask = nil
        if let tail = await bufferer.finish(), active { enqueue(tail) }
        if let worker { await worker.value }
    }

    private func stopMicrophone() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
    }

    func stop() {
        active = false
        generation = UUID()
        stopMicrophone()
        bufferer.stop()
        interimTask?.cancel(); interimTask = nil
        interimText = ""
        agreement.reset()
        worker?.cancel(); worker = nil
        pending = []
    }
}
