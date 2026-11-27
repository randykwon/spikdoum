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

/// UFAL LocalAgreement-2 inspired stabilizer for sliding-window Whisper interim hypotheses:
/// keeps the agreed leading prefix steady across consecutive hypotheses while showing live tail updates.
struct LocalAgreementTracker: Equatable, Sendable {
    private(set) var previousHypothesis = ""
    private(set) var confirmedPrefix = ""

    mutating func update(hypothesis raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return confirmedPrefix }
        if !previousHypothesis.isEmpty {
            let agreed = Self.longestAgreedPrefix(previousHypothesis, trimmed)
            if agreed.count > confirmedPrefix.count {
                confirmedPrefix = agreed
            }
        }
        previousHypothesis = trimmed
        if !confirmedPrefix.isEmpty && trimmed.count < confirmedPrefix.count {
            return confirmedPrefix
        }
        return trimmed
    }

    mutating func reset() {
        previousHypothesis = ""
        confirmedPrefix = ""
    }

    static func longestAgreedPrefix(_ a: String, _ b: String) -> String {
        let aWords = a.split(separator: " ")
        let bWords = b.split(separator: " ")
        if aWords.count >= 2 && bWords.count >= 2 {
            var matched: [Substring] = []
            for (w1, w2) in zip(aWords, bWords) {
                if w1.lowercased() == w2.lowercased() { matched.append(w2) }
                else { break }
            }
            return matched.joined(separator: " ")
        }
        // Spaceless CJK character-level agreement
        var chars: [Character] = []
        for (c1, c2) in zip(a, b) {
            if c1 == c2 { chars.append(c2) } else { break }
        }
        return String(chars)
    }
}

/// Converts either microphone or ScreenCaptureKit buffers into bounded 16kHz PCM batches,
/// preferring natural silence boundaries over hard mid-word cuts.
final class ManagedAudioBufferer: @unchecked Sendable {
    private static let sampleRate = 16000
    private static let bytesPerSecond = sampleRate * 2
    private static let minInterimBytes = bytesPerSecond * 32 / 100     // 0.32s minimum speech before first live interim
    private static let minPauseSplitBytes = bytesPerSecond * 65 / 100  // 0.65s minimum before splitting on natural pause
    private static let streamingMaxChunkBytes = bytesPerSecond * 2     // 2.0s upper bound for snappy live streaming commits
    private static let batchMaxChunkBytes = bytesPerSecond * 25 / 10   // 2.5s upper bound for max-accuracy batch mode
    private static let preRollMaxBytes = bytesPerSecond * 14 / 100     // 140ms pre-roll silence kept before speech onset
    private static let pauseFramesThreshold = 7                        // 7 * 20ms = 140ms trailing silence
    private static let minVoicedFrames = 2                             // 2 * 20ms = 40ms sustained speech energy
    private static let voiceRMSThreshold = 0.011                       // Rejects low-level hum/noise (< 0.011 RMS)
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
    private var muted = false
    private var interimIntervalSeconds: TimeInterval? = nil
    private var lastInterimAt = Date.distantPast
    private var onChunk: ((Data) -> Void)?
    private var onInterim: ((Data) -> Void)?
    func setMuted(_ value: Bool) {
        queue.async {
            self.muted = value
            if value { self.resetBuffer() }
        }
    }
    func start(
        interimInterval: TimeInterval? = nil,
        onInterim: ((Data) -> Void)? = nil,
        onChunk: @escaping (Data) -> Void
    ) {
        queue.async {
            self.active = true
            self.resetBuffer()
            self.converter = nil
            self.sourceFormat = nil
            self.interimIntervalSeconds = interimInterval
            self.onInterim = onInterim
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
        guard active, !muted else { return }
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
        let maxBytes = interimIntervalSeconds != nil ? Self.streamingMaxChunkBytes : Self.batchMaxChunkBytes
        let hitSilenceBoundary = voiced && pcm.count >= Self.minPauseSplitBytes && trailingSilentFrames >= Self.pauseFramesThreshold
        let hitMaxLength = pcm.count >= maxBytes
        if hitSilenceBoundary || hitMaxLength {
            if voiced { onChunk?(pcm) }
            resetBuffer()
        } else if voiced,
                  let interval = interimIntervalSeconds,
                  let onInterim,
                  pcm.count >= Self.minInterimBytes {
            let now = Date()
            if now.timeIntervalSince(lastInterimAt) >= interval {
                lastInterimAt = now
                onInterim(Data(pcm))
            }
        }
    }
    /// Triggers an immediate interim snapshot if voiced speech is already accumulating (eliminates dead gap right after a chunk commits).
    func requestImmediateInterimIfVoiced() {
        queue.async {
            guard self.active, !self.muted, self.voiced,
                  self.interimIntervalSeconds != nil,
                  let onInterim = self.onInterim,
                  self.pcm.count >= Self.minInterimBytes else { return }
            self.lastInterimAt = Date()
            onInterim(Data(self.pcm))
        }
    }
    private func resetBuffer() {
        pcm = Data()
        voiced = false
        voicedFrames = 0
        trailingSilentFrames = 0
        frameEnergySum = 0
        frameSampleCount = 0
        lastInterimAt = .distantPast
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

final class AudioMuteFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    func set(_ value: Bool) {
        lock.lock()
        muted = value
        lock.unlock()
    }

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }
}

@MainActor final class ManagedSpeechCapture {
    private var engine: AVAudioEngine?
    private let bufferer = ManagedAudioBufferer()
    private var pending: [Data] = []
    private var worker: Task<Void, Never>?
    private var interimTask: Task<Void, Never>?
    private var agreement = LocalAgreementTracker()
    private var interimText = ""
    private var warmCandidateLang: String?
    private var warmDetectedLang: String?
    private var warmLangStreak = 0
    private var allowWarmLanguageLock = false
    private var generation = UUID()
    private var active = false
    private let muteFlag = AudioMuteFlag()
    private var consecutiveFailures = 0
    private var text = ""
    private var lastCleanChunk = ""
    private var lastCleanChunkAt = Date.distantPast
    private var language = "en"
    private var key = ""
    private var onText: ((String) -> Void)?
    private var onInterimText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onLatency: ((Int) -> Void)?
    private var onDetectedLanguage: ((LanguageDetectionResult) -> Void)?
    private var routeObserver: NSObjectProtocol?
    private var audioStartedAt = Date.distantPast
    func start(
        language: String,
        externalAudio: Bool,
        inputDeviceUID: String,
        key: String,
        interimInterval: TimeInterval? = nil,
        allowWarmLanguageLock: Bool = false,
        onText: @escaping (String) -> Void,
        onInterim: ((String) -> Void)? = nil,
        onError: @escaping (String) -> Void,
        onLatency: @escaping (Int) -> Void,
        onDetectedLanguage: ((LanguageDetectionResult) -> Void)? = nil,
        onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        self.language = language; self.key = key; self.allowWarmLanguageLock = allowWarmLanguageLock
        self.onText = onText; self.onInterimText = onInterim; self.onError = onError; self.onLatency = onLatency; self.onDetectedLanguage = onDetectedLanguage
        text = ""; interimText = ""; agreement.reset(); warmCandidateLang = nil; warmDetectedLang = nil; warmLangStreak = 0
        lastCleanChunk = ""; lastCleanChunkAt = .distantPast; active = true; consecutiveFailures = 0
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
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in Task { @MainActor in
            guard let self, self.active, self.generation == token, self.engine === engine else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard self.active, self.generation == token, self.engine === engine else { return }
            if engine.isRunning && Date().timeIntervalSince(self.audioStartedAt) < 1.5 { return }
            if engine.isRunning { return }
            self.onError?("[AUDIO_ROUTE_CHANGED] 로컬 STT 마이크 형식이 바뀌었습니다.")
        } }
    }
    func setMuted(_ value: Bool) {
        muteFlag.set(value)
        bufferer.setMuted(value)
    }
    nonisolated var isMuted: Bool { muteFlag.isMuted }
    func updateLanguage(_ newLanguage: String) {
        language = newLanguage
        warmCandidateLang = nil
        warmDetectedLang = nil
        warmLangStreak = 0
    }
    func setAllowWarmLanguageLock(_ enabled: Bool) {
        allowWarmLanguageLock = enabled
        if !enabled {
            warmCandidateLang = nil
            warmDetectedLang = nil
            warmLangStreak = 0
        }
    }
    nonisolated func appendExternalAudio(_ buffer: AVAudioPCMBuffer) { bufferer.append(buffer) }

    private var effectiveRequestLanguage: String {
        if language == LanguageCatalog.autoCode {
            if allowWarmLanguageLock,
               let warm = warmDetectedLang,
               Date().timeIntervalSince(lastCleanChunkAt) <= 8.0 {
                return warm
            }
            return LanguageCatalog.autoCode
        }
        return language
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
        // Never queue or compete with finalized utterances or another in-flight interim request.
        guard interimTask == nil, pending.isEmpty, worker == nil else { return }
        let reqLang = effectiveRequestLanguage
        let contextPrompt = Date().timeIntervalSince(lastCleanChunkAt) <= 3.5
            ? ManagedSTTPolicy.safePrompt(from: lastCleanChunk)
            : ""
        let key = self.key
        interimTask = Task { [weak self] in
            defer { Task { @MainActor in self?.interimTask = nil } }
            let start = Date()
            do {
                let result = try await ManagedSTTClient(key: key).transcribe(
                    wave: ManagedSTTClient.wave(pcm: pcm),
                    language: reqLang,
                    prompt: contextPrompt
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.active, self.generation == token, self.pending.isEmpty else { return }
                    self.onLatency?(Int(Date().timeIntervalSince(start) * 1000))
                    if let cleaned = ManagedSTTPolicy.sanitize(result, previousChunk: self.lastCleanChunk) {
                        let stabilized = self.agreement.update(hypothesis: cleaned)
                        if !stabilized.isEmpty && stabilized != self.interimText {
                            self.interimText = stabilized
                            self.publishInterimText()
                        }
                    }
                }
            } catch {
                // Interim misses are harmless; the final chunk will deliver the authoritative transcription.
            }
        }
    }

    private func enqueue(_ pcm: Data) {
        interimTask?.cancel()
        interimTask = nil
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
            defer {
                if self.generation == token {
                    self.worker = nil
                    if self.active && self.pending.isEmpty {
                        self.bufferer.requestImmediateInterimIfVoiced()
                    }
                }
            }
            while !Task.isCancelled && self.generation == token && !self.pending.isEmpty {
                let data = self.pending.removeFirst(); let start = Date()
                do {
                    let contextPrompt = Date().timeIntervalSince(self.lastCleanChunkAt) <= 3.5
                        ? ManagedSTTPolicy.safePrompt(from: self.lastCleanChunk)
                        : ""
                    // Use fast `json` response format (2.1x faster than `verbose_json` on M5 Metal)
                    // and run instant local script/NLLanguageRecognizer detection (<0.1ms) on the transcript.
                    let rawText = try await ManagedSTTClient(key: self.key).transcribe(
                        wave: ManagedSTTClient.wave(pcm: data),
                        language: self.effectiveRequestLanguage,
                        prompt: contextPrompt
                    )
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.consecutiveFailures = 0
                    self.onLatency?(Int(Date().timeIntervalSince(start) * 1000))
                    self.interimText = ""
                    self.agreement.reset()
                    if let cleaned = ManagedSTTPolicy.sanitize(rawText, previousChunk: self.lastCleanChunk) {
                        self.lastCleanChunk = cleaned
                        self.lastCleanChunkAt = Date()
                        if self.language == LanguageCatalog.autoCode,
                           let textResult = LanguageCatalog.detectLanguageDetailed(for: cleaned) {
                            self.onDetectedLanguage?(textResult)
                            if self.allowWarmLanguageLock {
                                if self.warmCandidateLang == textResult.language.code {
                                    self.warmLangStreak += 1
                                    if self.warmLangStreak >= 2 {
                                        self.warmDetectedLang = textResult.language.code
                                    }
                                } else {
                                    self.warmCandidateLang = textResult.language.code
                                    self.warmLangStreak = 1
                                    self.warmDetectedLang = nil
                                }
                            }
                        }
                        self.text = [self.text, cleaned].filter { !$0.isEmpty }.joined(separator: "\n")
                        self.onText?(self.text)
                    } else {
                        self.onInterimText?("")
                        // Reset prompt context after filtered silence/hallucination so it cannot poison the next chunk.
                        self.lastCleanChunk = ""
                        if self.onInterimText == nil && !self.text.isEmpty { self.onText?(self.text) }
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
        interimTask?.cancel(); interimTask = nil
        if let tail = await bufferer.finish(), active { enqueue(tail) }
        if let worker { await worker.value }
    }
    private func stopMicrophone() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil }
    }
    func stop() {
        active = false; generation = UUID(); stopMicrophone(); bufferer.stop()
        interimTask?.cancel(); interimTask = nil; interimText = ""; agreement.reset()
        worker?.cancel(); worker = nil; pending = []
    }
}
