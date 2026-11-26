import AVFoundation
import CoreMedia
import Speech
import AudioToolbox

enum SpeechRecognitionPolicy {
    /// Apple on-device SFSpeechRecognizer often starts a new utterance with `isFinal == false`,
    /// resetting `formattedString`. Detect that reset across space-delimited and CJK languages
    /// so earlier spoken text is committed instead of overwritten.
    static func shouldCommitBeforeReplacing(previous: String, incoming: String) -> Bool {
        let prevTrim = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let inTrim = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prevTrim.isEmpty, !inTrim.isEmpty else { return false }

        let prevNorm = normalizedText(prevTrim)
        let inNorm = normalizedText(inTrim)
        guard !prevNorm.isEmpty, !inNorm.isEmpty else { return false }
        if prevNorm == inNorm || inNorm.hasPrefix(prevNorm) { return false }

        // A large length drop on a substantial utterance is an on-device utterance reset, never a minor word fix.
        if prevNorm.count >= 25 && inNorm.count < prevNorm.count * 55 / 100 && !prevNorm.hasPrefix(inNorm) {
            return true
        }

        // Prefix divergence check works for both CJK (no spaces) and space-delimited languages.
        let common = zip(prevNorm, inNorm).prefix { $0 == $1 }.count
        guard prevNorm.count >= 12, common < min(6, max(2, prevNorm.count / 2)) else { return false }

        let oldWords = normalizedWords(prevTrim)
        let newWords = normalizedWords(inTrim)
        if oldWords.count >= 2 && newWords.count >= 2 {
            // Normal leading-word correction still shares multiple words or a meaningful (3+ char) word in the opening phrase.
            let oldHead = oldWords.prefix(4)
            let newHead = Set(newWords.prefix(4))
            let shared = oldHead.filter { newHead.contains($0) }
            if shared.count >= 2 { return false }
            if shared.contains(where: { $0.count >= 3 }) { return false }
        }
        return true
    }

    static func isTransientError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let desc = nsError.localizedDescription.lowercased()
        if desc.contains("denied") || desc.contains("restricted") || desc.contains("권한") || desc.contains("허용") {
            return false
        }
        let transientDomains: Set<String> = [
            "kAFAssistantErrorDomain",
            "kLSRErrorDomain",
            "com.apple.speech.localspeechrecognition",
            "SFSpeechErrorDomain"
        ]
        // 1 = Internal/audio glitch, 102/300 = LSR transient, 201 = Server busy, 203 = Retry/empty,
        // 209 = Interrupted, 216/301 = Canceled, 1100/1101/1104/1107 = Local service transient,
        // 1110 = No speech detected. (1700 = permission/Siri disabled, intentionally non-transient.)
        let transientCodes: Set<Int> = [1, 102, 201, 203, 209, 216, 300, 301, 1100, 1101, 1104, 1107, 1110]
        if transientDomains.contains(nsError.domain) && transientCodes.contains(nsError.code) { return true }
        // NSXPCConnectionInterrupted (4097) / NSXPCConnectionInvalidated (4099) when macOS speech daemon restarts.
        if nsError.domain == NSCocoaErrorDomain && (nsError.code == 4097 || nsError.code == 4099) { return true }
        if nsError.domain == NSURLErrorDomain { return true }
        return desc.contains("no speech detected")
            || desc.contains("retry")
            || desc.contains("cancel")
            || desc.contains("interrupt")
            || desc.contains("connection")
            || desc.contains("timed out")
            || desc.contains("timeout")
            || desc.contains("음성이 감지되지")
            || desc.contains("연결")
            || desc.contains("중단")
    }

    static func softBackoffSeconds(attempt: Int) -> Double {
        attempt <= 1 ? 0.5 : min(4.0, Double(attempt))
    }

    private static func normalizedText(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Protects the recognition request / macOS 26 SpeechAnalyzer stream while audio callbacks and MainActor swap sessions.
/// Buffers a brief window (~0.5s) of audio during session rotation so words at boundaries are not dropped.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let convertQueue = DispatchQueue(label: "SpikDoum.SpeechAnalyzer.PCM", qos: .userInteractive)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTargetFormat: AVAudioFormat?
    private var analyzerConverter: AVAudioConverter?
    private var analyzerSourceFormat: AVAudioFormat?
    private var accepting = false
    private var muted = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var lastBuffer = Date()
    private var lastVoice = Date.distantPast

    func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        if value { pendingBuffers.removeAll() }
        lock.unlock()
    }

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func setAccepting(_ value: Bool) {
        lock.lock()
        accepting = value
        let cont = !value ? analyzerContinuation : nil
        if !value {
            pendingBuffers.removeAll()
            request = nil
            analyzerContinuation = nil
            analyzerTargetFormat = nil
        }
        lock.unlock()
        cont?.finish()
        if !value {
            convertQueue.async { [weak self] in
                self?.analyzerConverter = nil
                self?.analyzerSourceFormat = nil
            }
        }
    }

    func replace(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let oldCont = analyzerContinuation
        analyzerContinuation = nil
        analyzerTargetFormat = nil
        self.request = request
        let toDrain: [AVAudioPCMBuffer]
        if request != nil && !pendingBuffers.isEmpty {
            toDrain = pendingBuffers
            pendingBuffers.removeAll()
        } else {
            toDrain = []
        }
        lock.unlock()
        oldCont?.finish()
        if let request {
            for buffer in toDrain { request.append(buffer) }
        }
    }

    func replaceAnalyzer(continuation: AsyncStream<AnalyzerInput>.Continuation?, targetFormat: AVAudioFormat?) {
        lock.lock()
        let oldCont = analyzerContinuation
        self.request = nil
        self.analyzerContinuation = continuation
        self.analyzerTargetFormat = targetFormat
        let toDrain: [AVAudioPCMBuffer]
        if continuation != nil && !pendingBuffers.isEmpty {
            toDrain = pendingBuffers
            pendingBuffers.removeAll()
        } else {
            toDrain = []
        }
        lock.unlock()
        oldCont?.finish()
        convertQueue.async { [weak self] in
            self?.analyzerConverter = nil
            self?.analyzerSourceFormat = nil
            guard let self, let continuation else { return }
            for buffer in toDrain {
                self.deliverToAnalyzer(buffer, continuation: continuation, targetFormat: targetFormat)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for index in stride(from: 0, to: Int(buffer.frameLength), by: 8) { peak = max(peak, abs(samples[index])) }
        }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        lastBuffer = Date()
        if muted { lock.unlock(); return }
        if peak > 0.015 { lastVoice = lastBuffer }
        let request = self.request
        let continuation = self.analyzerContinuation
        let targetFormat = self.analyzerTargetFormat
        if request == nil && continuation == nil {
            if let copy = Self.copy(buffer) {
                pendingBuffers.append(copy)
                if pendingBuffers.count > 25 { pendingBuffers.removeFirst() }
            }
        }
        lock.unlock()
        if let request {
            request.append(buffer)
        } else if let continuation, let copy = Self.copy(buffer) {
            convertQueue.async { [weak self] in
                self?.deliverToAnalyzer(copy, continuation: continuation, targetFormat: targetFormat)
            }
        }
    }

    private func deliverToAnalyzer(
        _ buffer: AVAudioPCMBuffer,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat?
    ) {
        guard let targetFormat, buffer.format != targetFormat else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if analyzerSourceFormat != buffer.format || analyzerConverter == nil {
            analyzerConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            analyzerSourceFormat = buffer.format
        }
        guard let converter = analyzerConverter else { return }
        let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, capacity)) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func resetHealth() { lock.lock(); lastBuffer = Date(); lastVoice = .distantPast; lock.unlock() }
    func health() -> (buffer: Date, voice: Date) { lock.lock(); defer { lock.unlock() }; return (lastBuffer, lastVoice) }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(source, target) {
            if let from = input.mData, let to = output.mData {
                memcpy(to, from, Int(min(input.mDataByteSize, output.mDataByteSize)))
            }
        }
        return copy
    }
}

@MainActor
final class SpeechCapture {
    private var engine = AVAudioEngine()
    private let sink = SpeechAudioSink()
    private var recognizer: SFSpeechRecognizer?
    private var inputDeviceUID = ""
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerResultsTask: Task<Void, Never>?
    private var usingModernAnalyzer = false
    private var rotation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var audioStartedAt = Date.distantPast
    private var generation = UUID()
    private var tapped = false
    private var active = false
    private var externalAudio = false
    private var hardRetryCount = 0
    private var softRetryCount = 0
    private var lastHardRetryAt = Date.distantPast
    private var lastHardReason = ""
    private var allowServerFallback = false
    private var lastResult = Date()
    private var locale = "ko-KR"
    private var committed = ""
    private var partial = ""
    private var lastPublishedPartial = ""
    private var lastPartialCommitAt = Date.distantPast
    private var lastTurnsRenderAt = Date.distantPast
    private var speakerAnalyzer: SpeakerAnalyzer?
    private var segmentOrder: [String] = []
    private var segmentTokens: [String: [(text: String, time: Double)]] = [:]
    private var intervals: [String: [SpeakerInterval]] = [:]
    private var onTurns: (([SpeakerTurn]) -> Void)?
    private var onStatus: ((String) -> Void)?
    private var onText: ((String) -> Void)?
    private var onInterimText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(locale: String, externalAudio: Bool = false, inputDeviceUID: String, onTurns: @escaping ([SpeakerTurn]) -> Void, onSTTStatus: @escaping (String) -> Void, onSpeakerStatus: @escaping (String) -> Void, onText: @escaping (String) -> Void, onInterim: ((String) -> Void)? = nil, onError: @escaping (String) -> Void, onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        try await AudioPermissions.speech()
        self.externalAudio = externalAudio
        self.inputDeviceUID = inputDeviceUID; self.locale = locale
        self.onText = onText; self.onInterimText = onInterim; self.onError = onError; self.onTurns = onTurns; self.onStatus = onSTTStatus; self.onAudioBuffer = onAudioBuffer
        committed = ""; partial = ""; lastPublishedPartial = ""; lastPartialCommitAt = .distantPast; lastTurnsRenderAt = .distantPast
        segmentOrder = []; segmentTokens = [:]; intervals = [:]
        hardRetryCount = 0; softRetryCount = 0; lastHardRetryAt = .distantPast; lastHardReason = ""; allowServerFallback = false; usingModernAnalyzer = false
        active = true
        sink.setAccepting(true)
        let analyzer = SpeakerAnalyzer()
        analyzer.onInterval = { [weak self] interval in
            Task { @MainActor in
                guard let self, self.active, self.segmentOrder.contains(interval.segment) else { return }
                self.intervals[interval.segment, default: []].append(interval)
                self.renderTurns()
            }
        }
        analyzer.onStatus = { status in Task { @MainActor in onSpeakerStatus(status) } }
        if !externalAudio {
            do { try analyzer.start(); speakerAnalyzer = analyzer } catch { onSpeakerStatus(error.localizedDescription) }
        }
        do {
            let startedModern = await tryBeginModernAnalyzer()
            if !startedModern {
                try beginRecognition()
            }
            try startAudio()
        } catch { stop(); throw error }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.active else { return }
                let health = self.sink.health()
                let now = Date()
                if self.recovery == nil && self.hardRetryCount > 0 && now.timeIntervalSince(self.lastHardRetryAt) > 20 {
                    self.hardRetryCount = 0
                }
                if !self.externalAudio && !self.sink.isMuted && now.timeIntervalSince(health.buffer) > 4 {
                    self.recoverHard(reason: "마이크 입력이 중단되어 재연결 중", rebuildAudio: true)
                } else if self.recovery == nil && now.timeIntervalSince(self.lastResult) > 15 && health.voice > self.lastResult {
                    // Music, ambient sound, or a stalled on-device task: softly cycle recognition without ever killing listening.
                    self.recoverSoft(reason: "음성 인식 세션 재동기화 중", delay: nil)
                } else if self.recovery == nil && now.timeIntervalSince(health.voice) > 6 {
                    self.onStatus?(self.externalAudio ? "Mac 재생음 대기 중 (음성 감지 시 자동 인식)" : "마이크 입력 중 · 음성 대기 (입력 장치를 확인하세요)")
                }
            }
        }
    }

    func setMuted(_ value: Bool) {
        sink.setMuted(value)
    }

    nonisolated func appendExternalAudio(_ buffer: AVAudioPCMBuffer) {
        sink.append(buffer)
    }

    private func startAudio() throws {
        if externalAudio { sink.resetHealth(); return }
        let configured: (engine: AVAudioEngine, format: AVAudioFormat)
        do {
            configured = try AudioInputDevices.configuredEngine(uid: inputDeviceUID)
        } catch {
            guard !inputDeviceUID.isEmpty else { throw error }
            configured = try AudioInputDevices.configuredEngine(uid: "")
            inputDeviceUID = ""
            onStatus?("선택한 마이크 연결 실패 · 기본 마이크로 자동 전환됨")
        }
        engine = configured.engine
        let input = engine.inputNode
        let format = configured.format
        let sink = sink, analyzer = speakerAnalyzer, recorder = onAudioBuffer
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            sink.append(buffer)
            if !sink.isMuted {
                analyzer?.append(buffer)
                recorder?(buffer)
            }
        }
        tapped = true
        sink.resetHealth()
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
        engine.prepare()
        try engine.start()
        let startedEngine = engine
        audioStartedAt = Date()
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: startedEngine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.engine === startedEngine else { return }
                // USB microphones (e.g. Logitech C930c) and Bluetooth devices commonly emit an initial
                // IOUnit configuration-change notification ~50-200ms after start while running normally.
                try? await Task.sleep(for: .milliseconds(250))
                guard self.active, self.engine === startedEngine else { return }
                if Date().timeIntervalSince(self.audioStartedAt) < 1.5 && startedEngine.isRunning {
                    return
                }
                if startedEngine.isRunning && Date().timeIntervalSince(self.sink.health().buffer) < 1.0 {
                    return
                }
                self.recoverHard(reason: "오디오 입력 경로가 변경되어 재연결 중", rebuildAudio: true)
            }
        }
    }

    private func ensureRecognizer() throws -> SFSpeechRecognizer {
        if let existing = recognizer, existing.locale.identifier == locale, existing.isAvailable {
            return existing
        }
        guard let created = SFSpeechRecognizer(locale: Locale(identifier: locale)), created.isAvailable else {
            throw CaptureError.message("선택한 언어의 음성 인식을 사용할 수 없습니다.")
        }
        recognizer = created
        return created
    }

    /// Attempts to start macOS 26 continuous streaming SpeechAnalyzer + SpeechTranscriber when assets are installed.
    /// If assets are supported but not yet downloaded, triggers silent background installation and falls back immediately to SFSpeechRecognizer.
    private func tryBeginModernAnalyzer() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let targetLocale = Locale(identifier: locale)
        guard let matchedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: targetLocale) else { return false }
        let transcriber = SpeechTranscriber(
            locale: matchedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus == .supported {
            Task.detached(priority: .utility) {
                _ = try? await AssetInventory.reserve(locale: matchedLocale)
                if let installer = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try? await installer.downloadAndInstall()
                }
            }
            return false
        }
        guard assetStatus == .installed else { return false }

        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let token = UUID()
        generation = token
        let segmentID = token.uuidString
        segmentOrder.append(segmentID)
        speakerAnalyzer?.reset(segment: segmentID)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            return false
        }
        guard active, generation == token else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return false
        }

        speechAnalyzer = analyzer
        usingModernAnalyzer = true
        lastResult = Date()
        sink.replaceAnalyzer(continuation: continuation, targetFormat: targetFormat)
        onStatus?(externalAudio ? "Mac 재생음 스트리밍 STT 준비 완료" : "실시간 스트리밍 STT 준비 완료")

        analyzerResultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let raw = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let isFinal = result.isFinal
                    let midpoint = CMTimeGetSeconds(result.range.start) + CMTimeGetSeconds(result.range.duration) / 2
                    let safeTime = midpoint.isFinite ? midpoint : 0
                    await MainActor.run {
                        guard self.active, self.generation == token else { return }
                        guard !raw.isEmpty else { return }
                        self.lastResult = Date()
                        self.hardRetryCount = 0
                        self.softRetryCount = 0
                        if isFinal {
                            self.committed = [self.committed, raw].filter { !$0.isEmpty }.joined(separator: "\n")
                            self.partial = ""
                            self.lastPublishedPartial = ""
                            self.onInterimText?("")
                            self.onText?(self.committed)
                            var tokens = self.segmentTokens[segmentID] ?? []
                            tokens.append((text: raw, time: safeTime))
                            self.segmentTokens[segmentID] = tokens
                            self.renderTurns()
                        } else {
                            self.partial = raw
                            if let onInterim = self.onInterimText {
                                onInterim(raw)
                            } else {
                                self.onText?([self.committed, raw].filter { !$0.isEmpty }.joined(separator: "\n"))
                            }
                        }
                        self.onStatus?(self.externalAudio ? "Mac 재생음 스트리밍 STT 수신 중" : "실시간 스트리밍 STT 수신 중")
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.active, self.generation == token else { return }
                    // Seamlessly fall back to SFSpeechRecognizer if SpeechAnalyzer encounters a runtime interruption.
                    self.usingModernAnalyzer = false
                    self.recoverSoft(reason: "스트리밍 STT 재연결 중", delay: 0.3)
                }
            }
        }
        return true
    }

    private func beginRecognition() throws {
        let recognizer = try ensureRecognizer()
        let token = UUID(); generation = token
        let segmentID = token.uuidString
        segmentOrder.append(segmentID)
        speakerAnalyzer?.reset(segment: segmentID)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition && !allowServerFallback { request.requiresOnDeviceRecognition = true }
        self.request = request
        lastResult = Date()
        sink.replace(request)
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let words = result?.bestTranscription.segments.map { (text: $0.substring, time: $0.timestamp + $0.duration / 2) }
            let final = result?.isFinal == true
            Task { @MainActor in
                guard let self, self.active, self.generation == token else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let now = Date()
                    self.lastResult = now
                    self.hardRetryCount = 0
                    self.softRetryCount = 0
                    if SpeechRecognitionPolicy.shouldCommitBeforeReplacing(previous: self.partial, incoming: text) {
                        self.commitPartial(emit: true)
                    }
                    self.partial = text
                    if let onInterim = self.onInterimText {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let endsSentence = trimmed.unicodeScalars.last.map { CharacterSet(charactersIn: ".!?。！？").contains($0) } ?? false
                        let timeToFlush = now.timeIntervalSince(self.lastPartialCommitAt) >= 1.6 && trimmed.count >= max(10, self.lastPublishedPartial.count + 8)
                        let revisedEarlier = !self.lastPublishedPartial.isEmpty && !text.hasPrefix(self.lastPublishedPartial)
                        if final || endsSentence || timeToFlush || revisedEarlier {
                            self.lastPublishedPartial = text
                            self.lastPartialCommitAt = now
                            onInterim("")
                            self.onText?([self.committed, text].filter { !$0.isEmpty }.joined(separator: "\n"))
                        } else {
                            let tail = self.lastPublishedPartial.isEmpty
                                ? text
                                : String(text.dropFirst(self.lastPublishedPartial.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            onInterim(tail.isEmpty ? text : tail)
                        }
                    } else {
                        // Publish raw STT before optional token alignment or speaker analysis.
                        self.onText?([self.committed, text].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                    self.onStatus?(self.externalAudio ? "Mac 재생음 STT 수신 중" : "STT 수신 중")
                    if let words, !words.isEmpty {
                        self.segmentTokens[segmentID] = words
                        if final || now.timeIntervalSince(self.lastTurnsRenderAt) >= 1.5 {
                            self.lastTurnsRenderAt = now
                            self.renderTurns()
                        }
                    }
                }
                if final {
                    self.rotate(delay: 0.15)
                } else if let error {
                    if SpeechRecognitionPolicy.isTransientError(error) {
                        self.recoverSoft(reason: self.externalAudio ? "Mac 재생음 대기 중 · 인식 세션 갱신" : "음성 대기 중 · 인식 세션 갱신", delay: nil)
                    } else {
                        self.recoverHard(reason: "음성 인식 재연결: \(error.localizedDescription)", rebuildAudio: false)
                    }
                }
            }
        }
        rotation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.rotate(delay: 0.15)
        }
    }

    private func rotate(delay: Double) {
        guard active, recovery == nil else { return }
        commitPartial()
        stopRecognition()
        // Wait briefly so macOS localspeechrecognition finishes tearing down the previous task;
        // SpeechAudioSink buffers incoming audio during this short window.
        recovery = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled, let self, self.active else { return }
            self.recovery = nil
            do { try self.beginRecognition() }
            catch { self.recoverHard(reason: error.localizedDescription, rebuildAudio: false) }
        }
    }

    /// Continuous non-fatal recovery for silence / no-speech / music / XPC timeout.
    /// Never terminates the listening session on its own.
    private func recoverSoft(reason: String, delay: Double?) {
        guard active, recovery == nil else { return }
        softRetryCount += 1
        let wait = delay ?? SpeechRecognitionPolicy.softBackoffSeconds(attempt: softRetryCount)
        onStatus?(reason)
        commitPartial()
        stopRecognition()
        if softRetryCount >= 3 { recognizer = nil }
        recovery = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled, let self, self.active else { return }
            self.recovery = nil
            if self.usingModernAnalyzer, await self.tryBeginModernAnalyzer() { return }
            do { try self.beginRecognition() }
            catch { self.recoverHard(reason: error.localizedDescription, rebuildAudio: false) }
        }
    }

    private func recoverHard(reason: String, rebuildAudio: Bool) {
        guard active, recovery == nil else { return }
        let now = Date()
        if now.timeIntervalSince(lastHardRetryAt) > 25 {
            hardRetryCount = 0
        }
        lastHardRetryAt = now
        lastHardReason = reason
        hardRetryCount += 1
        guard hardRetryCount <= 5 else {
            let serverOnlyLocale = !usingModernAnalyzer && (recognizer?.supportsOnDeviceRecognition == false)
            stop()
            let detail = lastHardReason.isEmpty ? "" : " (\(lastHardReason))"
            let hint = serverOnlyLocale
                ? " 현재 언어(\(locale))는 Apple 서버 음성 인식을 사용하므로 로컬 Whisper STT로 전환하면 안정적으로 계속 인식할 수 있습니다."
                : " 입력 장치와 권한·네트워크를 확인한 뒤 듣기를 다시 시작해주세요."
            onError?("음성 인식이 복구되지 않았습니다\(detail).\(hint)")
            return
        }
        if !rebuildAudio && hardRetryCount >= 2 {
            allowServerFallback = true
        }
        onStatus?(reason)
        commitPartial()
        stopRecognition()
        recognizer = nil
        if rebuildAudio { stopAudio() }
        let wait = min(3.0, Double(hardRetryCount) * 0.6)
        recovery = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled, let self, self.active else { return }
            self.recovery = nil
            do {
                try self.beginRecognition()
                if rebuildAudio { try self.startAudio() }
            } catch {
                // Retry on transient audio/recognition setup error instead of failing immediately.
                self.recoverHard(reason: "재연결 재시도 중: \(error.localizedDescription)", rebuildAudio: rebuildAudio)
            }
        }
    }

    private func commitPartial(emit: Bool = false) {
        let hadUnpublished = !partial.isEmpty && partial != lastPublishedPartial
        committed = [committed, partial].filter { !$0.isEmpty }.joined(separator: "\n")
        partial = ""
        lastPublishedPartial = ""
        onInterimText?("")
        if (emit || hadUnpublished), !committed.isEmpty {
            onText?(committed)
        }
    }

    private func renderTurns() {
        var turns: [SpeakerTurn] = []
        for segment in segmentOrder {
            for (index, word) in (segmentTokens[segment] ?? []).enumerated() {
                let speaker = intervals[segment]?.first(where: { word.time >= $0.start && word.time < $0.end })?.speaker
                if let last = turns.last, last.speaker == speaker, last.id.hasPrefix(segment) { turns[turns.count - 1].text += " " + word.text }
                else { turns.append(SpeakerTurn(id: "\(segment)-\(index)", speaker: speaker, start: word.time, text: word.text)) }
            }
        }
        onTurns?(turns)
    }

    func flushPartial() {
        guard active else { return }
        commitPartial(emit: true)
    }

    func stop() {
        active = false
        partial = ""
        lastPublishedPartial = ""
        onInterimText?("")
        sink.setAccepting(false)
        watchdog?.cancel(); watchdog = nil
        recovery?.cancel(); recovery = nil
        stopRecognition(); stopAudio()
        recognizer = nil
        speakerAnalyzer?.stop(); speakerAnalyzer = nil
    }

    private func stopRecognition() {
        generation = UUID()
        rotation?.cancel(); rotation = nil
        analyzerResultsTask?.cancel(); analyzerResultsTask = nil
        let analyzer = speechAnalyzer
        speechAnalyzer = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        sink.replace(nil)
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }

    private func stopAudio() {
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
