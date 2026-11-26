import Foundation
import AVFoundation
import AudioToolbox

enum ManagedSTTPolicy {
    /// Known standalone Whisper silence/music outro hallucinations (matched only when the entire chunk is just the phrase).
    private static let standaloneHallucinations: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴いただきありがとうございました",
        "チャンネル登録よろしくお願いします",
        "チャンネル登録お願いします",
        "高評価よろしくお願いします",
        "字幕",
        "おやすみなさい",
        "thanks for watching",
        "thank you for watching",
        "thank you for watching!",
        "thanks for watching!",
        "subscribe",
        "please subscribe",
        "subtitles by",
        "시청해주셔서 감사합니다",
        "시청해 주셔서 감사합니다",
        "구독과 좋아요",
        "구독과 좋아요 부탁드립니다",
        "mbc 뉴스"
    ]

    /// Filters Whisper repetition loops (`ん ん ん...`, `И? И? И?...`), single-glyph noise bursts,
    /// standalone silence hallucinations, and back-to-back short duplicate echoes.
    static func sanitize(_ raw: String, previousChunk: String = "") -> String? {
        let meaningful = TranslationPolicy.preparedForTranslation(raw)
        guard !meaningful.isEmpty else { return nil }

        let strippedPunct = meaningful.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        // Reject pure punctuation or single-character glitches like "И?" or "ん".
        if strippedPunct.count <= 1 { return nil }

        let lower = strippedPunct.lowercased()
        if standaloneHallucinations.contains(lower) { return nil }

        // Detect space-delimited token repetition loops (e.g. "ん ん ん ん", "И? И? И? И?").
        let tokens = meaningful
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        if tokens.count >= 4 {
            var counts: [String: Int] = [:]
            var maxRun = 1
            var currentRun = 1
            for (idx, tok) in tokens.enumerated() {
                let key = tok.lowercased()
                counts[key, default: 0] += 1
                if idx > 0 && tokens[idx - 1].lowercased() == key {
                    currentRun += 1
                    maxRun = max(maxRun, currentRun)
                } else {
                    currentRun = 1
                }
            }
            let topCount = counts.values.max() ?? 0
            if maxRun >= 4 || (Double(topCount) / Double(tokens.count) >= 0.6) {
                return nil
            }
        }

        // Detect spaceless CJK / character repetition loops (e.g. "んんんんんんんん" or "ああああああ").
        let compact = meaningful.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
        if compact.count >= 6 {
            let uniqueScalars = Set(compact)
            if uniqueScalars.count <= 2 { return nil }
            let chars = Array(String(String.UnicodeScalarView(compact)))
            for unitLen in 1...4 where chars.count >= unitLen * 4 {
                var run = 1
                var i = unitLen
                while i + unitLen <= chars.count {
                    if chars[i..<(i + unitLen)] == chars[(i - unitLen)..<i] {
                        run += 1
                        if run >= 4 { return nil }
                        i += unitLen
                    } else {
                        run = 1
                        i += 1
                    }
                }
            }
        }

        // Drop identical back-to-back short echoes typical of silence/music loops.
        let prevTrimmed = previousChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prevTrimmed.isEmpty && meaningful.count <= 24 && meaningful.lowercased() == prevTrimmed.lowercased() {
            return nil
        }

        return meaningful
    }

    /// Returns a safe short context prompt only when the previous chunk was genuine, diverse speech.
    static func safePrompt(from lastCleanChunk: String) -> String {
        let trimmed = lastCleanChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return "" }
        let scalars = trimmed.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count >= 8 else { return "" }
        let uniqueRatio = Double(Set(scalars).count) / Double(scalars.count)
        guard uniqueRatio >= 0.45 else { return "" }
        return String(trimmed.suffix(80))
    }
}

/// Converts either microphone or ScreenCaptureKit buffers into bounded 16kHz PCM batches,
/// preferring natural silence boundaries over hard mid-word cuts.
final class ManagedAudioBufferer: @unchecked Sendable {
    private static let sampleRate = 16000
    private static let bytesPerSecond = sampleRate * 2
    private static let minPauseSplitBytes = bytesPerSecond * 9 / 10    // 0.9s minimum before splitting on natural pause
    private static let maxChunkBytes = bytesPerSecond * 25 / 10        // 2.5s hard upper bound for continuous speech
    private static let preRollMaxBytes = bytesPerSecond * 16 / 100     // 160ms pre-roll silence kept before speech onset
    private static let pauseFramesThreshold = 10                       // 10 * 20ms = 200ms trailing silence
    private static let minVoicedFrames = 3                             // 3 * 20ms = 60ms sustained speech energy
    private static let voiceRMSThreshold = 0.012                       // Rejects low-level hum/noise (< 0.012 RMS)
    private static let frameSamples = 320                              // 20ms at 16kHz
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "SpikDoum.ManagedSTT.PCM", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pcm = Data()
    private var voiced = false
    private var voicedFrames = 0
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
            frameEnergySum += Double(value * value)
            frameSampleCount += 1
            if frameSampleCount >= Self.frameSamples {
                let rms = sqrt(frameEnergySum / Double(frameSampleCount))
                if rms >= Self.voiceRMSThreshold {
                    voicedFrames += 1
                    trailingSilentFrames = 0
                    if voicedFrames >= Self.minVoicedFrames { voiced = true }
                } else {
                    trailingSilentFrames += 1
                }
                frameEnergySum = 0
                frameSampleCount = 0
            }
            values.append(Int16(max(-32768, min(32767, Int(value * 32767)))).littleEndian)
        }
        values.withUnsafeBytes { pcm.append(contentsOf: $0) }
        // Trim excess leading silence before speech starts so Whisper doesn't waste time or hallucinate on silent gaps.
        if !voiced && pcm.count > Self.preRollMaxBytes {
            pcm = Data(pcm.suffix(Self.preRollMaxBytes))
            return
        }
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
        voicedFrames = 0
        trailingSilentFrames = 0
        frameEnergySum = 0
        frameSampleCount = 0
    }
    func finish() async -> Data? {
        await withCheckedContinuation { continuation in queue.async {
            self.active = false
            let final = self.voiced && self.pcm.count >= 9600 ? self.pcm : nil
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
    private var lastCleanChunk = ""
    private var lastCleanChunkAt = Date.distantPast
    private var language = "en"
    private var key = ""
    private var onText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onLatency: ((Int) -> Void)?
    private var routeObserver: NSObjectProtocol?
    private var audioStartedAt = Date.distantPast
    func start(language: String, externalAudio: Bool, inputDeviceUID: String, key: String, onText: @escaping (String) -> Void, onError: @escaping (String) -> Void, onLatency: @escaping (Int) -> Void, onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        self.language = language; self.key = key; self.onText = onText; self.onError = onError; self.onLatency = onLatency
        text = ""; lastCleanChunk = ""; lastCleanChunkAt = .distantPast; active = true; consecutiveFailures = 0
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
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
        audioStartedAt = Date()
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in Task { @MainActor in
            guard let self, self.active, self.generation == token, self.engine === engine else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard self.active, self.generation == token, self.engine === engine else { return }
            if engine.isRunning && Date().timeIntervalSince(self.audioStartedAt) < 1.5 { return }
            if engine.isRunning { return }
            self.onError?("[AUDIO_ROUTE_CHANGED] 로컬 STT 마이크 형식이 바뀌었습니다.")
        } }
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
                    let contextPrompt = Date().timeIntervalSince(self.lastCleanChunkAt) <= 3.5
                        ? ManagedSTTPolicy.safePrompt(from: self.lastCleanChunk)
                        : ""
                    let result = try await ManagedSTTClient(key: self.key).transcribe(
                        wave: ManagedSTTClient.wave(pcm: data),
                        language: self.language,
                        prompt: contextPrompt
                    )
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.consecutiveFailures = 0
                    self.onLatency?(Int(Date().timeIntervalSince(start) * 1000))
                    if let cleaned = ManagedSTTPolicy.sanitize(result, previousChunk: self.lastCleanChunk) {
                        self.lastCleanChunk = cleaned
                        self.lastCleanChunkAt = Date()
                        self.text = [self.text, cleaned].filter { !$0.isEmpty }.joined(separator: "\n")
                        self.onText?(self.text)
                    } else {
                        // Reset prompt context after filtered silence/hallucination so it cannot poison the next chunk.
                        self.lastCleanChunk = ""
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
