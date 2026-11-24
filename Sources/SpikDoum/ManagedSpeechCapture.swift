import Foundation
import AVFoundation
import AudioToolbox

/// Converts either microphone or ScreenCaptureKit buffers into bounded 16kHz PCM batches,
/// preferring natural silence boundaries over hard mid-word cuts.
final class ManagedAudioBufferer: @unchecked Sendable {
    private static let sampleRate = 16000
    private static let bytesPerSecond = sampleRate * 2
    private static let minPauseSplitBytes = bytesPerSecond * 16 / 10   // 1.6s minimum before splitting on pause
    private static let maxChunkBytes = bytesPerSecond * 3              // 3.0s hard upper bound for continuous speech
    private static let pauseFramesThreshold = 12                       // 12 * 20ms = 240ms trailing silence
    private static let frameSamples = 320                              // 20ms at 16kHz
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "SpikDoum.ManagedSTT.PCM", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pcm = Data()
    private var voiced = false
    private var trailingSilentFrames = 0
    private var frameEnergySum: Double = 0
    private var frameSampleCount = 0
    private var active = false
    private var onChunk: ((Data) -> Void)?
    func start(onChunk: @escaping (Data) -> Void) {
        queue.async {
            self.active = true
            self.resetBuffer()
            self.converter = nil
            self.sourceFormat = nil
            self.onChunk = onChunk
        }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        // Audio engine buffers are reused after the tap returns; own the samples first.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(source, target) {
            if let from = input.mData, let to = output.mData { memcpy(to, from, Int(min(input.mDataByteSize, output.mDataByteSize))) }
        }
        queue.async { self.consume(copy) }
    }
    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard active else { return }
        let format = Self.targetFormat
        if sourceFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format); sourceFormat = buffer.format }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 64)) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { return }
        var values = [Int16](); values.reserveCapacity(Int(output.frameLength))
        for i in 0..<Int(output.frameLength) {
            let value = samples[i].isFinite ? samples[i] : 0
            if abs(value) > 0.015 { voiced = true }
            frameEnergySum += Double(value * value)
            frameSampleCount += 1
            if frameSampleCount >= Self.frameSamples {
                let rms = sqrt(frameEnergySum / Double(frameSampleCount))
                if rms > 0.008 { trailingSilentFrames = 0 } else { trailingSilentFrames += 1 }
                frameEnergySum = 0
                frameSampleCount = 0
            }
            values.append(Int16(max(-32768, min(32767, Int(value * 32767)))).littleEndian)
        }
        values.withUnsafeBytes { pcm.append(contentsOf: $0) }
        let hitSilenceBoundary = voiced && pcm.count >= Self.minPauseSplitBytes && trailingSilentFrames >= Self.pauseFramesThreshold
        let hitMaxLength = pcm.count >= Self.maxChunkBytes
        if hitSilenceBoundary || hitMaxLength {
            if voiced { onChunk?(pcm) }
            resetBuffer()
        }
    }
    private func resetBuffer() {
        pcm = Data()
        voiced = false
        trailingSilentFrames = 0
        frameEnergySum = 0
        frameSampleCount = 0
    }
    func finish() async -> Data? {
        await withCheckedContinuation { continuation in queue.async {
            self.active = false
            let final = self.voiced && self.pcm.count >= 16000 ? self.pcm : nil
            self.resetBuffer()
            continuation.resume(returning: final)
        } }
    }
    func stop() { queue.async { self.active = false; self.resetBuffer() } }
}

@MainActor final class ManagedSpeechCapture {
    private var engine: AVAudioEngine?
    private let bufferer = ManagedAudioBufferer()
    private var pending: [Data] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var active = false
    private var consecutiveFailures = 0
    private var text = ""
    private var language = "en"
    private var key = ""
    private var onText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onLatency: ((Int) -> Void)?
    private var routeObserver: NSObjectProtocol?
    func start(language: String, externalAudio: Bool, inputDeviceUID: String, key: String, onText: @escaping (String) -> Void, onError: @escaping (String) -> Void, onLatency: @escaping (Int) -> Void, onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        self.language = language; self.key = key; self.onText = onText; self.onError = onError; self.onLatency = onLatency
        text = ""; active = true; consecutiveFailures = 0
        let token = generation
        bufferer.start { [weak self] data in Task { @MainActor in
            guard let self, self.active, self.generation == token else { return }; self.enqueue(data)
        } }
        if externalAudio { return }
        let configured = try AudioInputDevices.configuredEngine(uid: inputDeviceUID)
        let engine = configured.engine
        let input = engine.inputNode
        let format = configured.format
        let bufferer = bufferer
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            bufferer.append(buffer)
            onAudioBuffer?(buffer)
        }
        self.engine = engine
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in Task { @MainActor in
            guard let self, self.active, self.generation == token else { return }
            self.onError?("[AUDIO_ROUTE_CHANGED] 로컬 STT 마이크 형식이 바뀌었습니다.")
        } }
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
    }
    func updateLanguage(_ newLanguage: String) {
        language = newLanguage
    }
    nonisolated func appendExternalAudio(_ buffer: AVAudioPCMBuffer) { bufferer.append(buffer) }
    private func enqueue(_ pcm: Data) {
        if pending.count >= 24 {
            pending.removeFirst()
        }
        pending.append(pcm)
        if worker == nil { runWorker() }
    }
    private func runWorker() {
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.worker = nil } }
            while !Task.isCancelled && self.generation == token && !self.pending.isEmpty {
                let data = self.pending.removeFirst(); let start = Date()
                do {
                    let result = try await ManagedSTTClient(key: self.key).transcribe(wave: ManagedSTTClient.wave(pcm: data), language: self.language)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.consecutiveFailures = 0
                    self.onLatency?(Int(Date().timeIntervalSince(start) * 1000))
                    if !result.isEmpty {
                        self.text = [self.text, result].filter { !$0.isEmpty }.joined(separator: "\n")
                        self.onText?(self.text)
                    }
                } catch {
                    guard self.generation == token && !Task.isCancelled else { return }
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        self.onError?("로컬 STT 실패: \(error.localizedDescription)")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
    func finish() async {
        stopMicrophone()
        if let tail = await bufferer.finish(), active { enqueue(tail) }
        if let worker { await worker.value }
    }
    private func stopMicrophone() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
    }
    func stop() {
        active = false; generation = UUID(); stopMicrophone(); bufferer.stop()
        worker?.cancel(); worker = nil; pending = []
    }
}
