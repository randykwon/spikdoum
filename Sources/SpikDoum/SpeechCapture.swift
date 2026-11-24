import AVFoundation
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
        let transientDomains: Set<String> = [
            "kAFAssistantErrorDomain",
            "kLSRErrorDomain",
            "com.apple.speech.localspeechrecognition",
            "SFSpeechErrorDomain"
        ]
        // 1110 = No speech detected, 203 = Retry/empty, 209 = Interrupted, 216/301 = Canceled, 1101/1107 = Local service transient
        let transientCodes: Set<Int> = [203, 209, 216, 301, 1101, 1107, 1110]
        if transientDomains.contains(nsError.domain) && transientCodes.contains(nsError.code) { return true }
        if nsError.domain == NSURLErrorDomain { return true }
        let desc = nsError.localizedDescription.lowercased()
        return desc.contains("no speech detected") || desc.contains("retry") || desc.contains("음성이 감지되지")
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

/// Protects the recognition request while audio callbacks and MainActor swap sessions.
/// Buffers a brief window (~0.5s) of audio during session rotation so words at boundaries are not dropped.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var accepting = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var lastBuffer = Date()
    private var lastVoice = Date.distantPast

    func setAccepting(_ value: Bool) {
        lock.lock()
        accepting = value
        if !value { pendingBuffers.removeAll(); request = nil }
        lock.unlock()
    }

    func replace(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        let toDrain: [AVAudioPCMBuffer]
        if request != nil && !pendingBuffers.isEmpty {
            toDrain = pendingBuffers
            pendingBuffers.removeAll()
        } else {
            toDrain = []
        }
        lock.unlock()
        if let request {
            for buffer in toDrain { request.append(buffer) }
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
        if peak > 0.015 { lastVoice = lastBuffer }
        let request = self.request
        if request == nil {
            if let copy = Self.copy(buffer) {
                pendingBuffers.append(copy)
                if pendingBuffers.count > 25 { pendingBuffers.removeFirst() }
            }
        }
        lock.unlock()
        request?.append(buffer)
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
    private var rotation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var generation = UUID()
    private var tapped = false
    private var active = false
    private var externalAudio = false
    private var hardRetryCount = 0
    private var softRetryCount = 0
    private var lastResult = Date()
    private var locale = "ko-KR"
    private var committed = ""
    private var partial = ""
    private var speakerAnalyzer: SpeakerAnalyzer?
    private var segmentOrder: [String] = []
    private var segmentTokens: [String: [(text: String, time: Double)]] = [:]
    private var intervals: [String: [SpeakerInterval]] = [:]
    private var onTurns: (([SpeakerTurn]) -> Void)?
    private var onStatus: ((String) -> Void)?
    private var onText: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(locale: String, externalAudio: Bool = false, inputDeviceUID: String, onTurns: @escaping ([SpeakerTurn]) -> Void, onSTTStatus: @escaping (String) -> Void, onSpeakerStatus: @escaping (String) -> Void, onText: @escaping (String) -> Void, onError: @escaping (String) -> Void, onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) async throws {
        stop()
        if !externalAudio { try await AudioPermissions.microphone() }
        try await AudioPermissions.speech()
        self.externalAudio = externalAudio
        self.inputDeviceUID = inputDeviceUID; self.locale = locale
        self.onText = onText; self.onError = onError; self.onTurns = onTurns; self.onStatus = onSTTStatus; self.onAudioBuffer = onAudioBuffer
        committed = ""; partial = ""; segmentOrder = []; segmentTokens = [:]; intervals = [:]
        hardRetryCount = 0; softRetryCount = 0
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
        do { try beginRecognition(); try startAudio() } catch { stop(); throw error }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.active else { return }
                let health = self.sink.health()
                let now = Date()
                if !self.externalAudio && now.timeIntervalSince(health.buffer) > 4 {
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

    nonisolated func appendExternalAudio(_ buffer: AVAudioPCMBuffer) {
        sink.append(buffer)
    }

    private func startAudio() throws {
        if externalAudio { sink.resetHealth(); return }
        let configured = try AudioInputDevices.configuredEngine(uid: inputDeviceUID)
        engine = configured.engine
        let input = engine.inputNode
        let format = configured.format
        let sink = sink, analyzer = speakerAnalyzer, recorder = onAudioBuffer
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
            analyzer?.append(buffer)
            recorder?(buffer)
        }
        tapped = true
        sink.resetHealth()
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.recoverHard(reason: "오디오 입력 경로가 변경되어 재연결 중", rebuildAudio: true)
            }
        }
        engine.prepare()
        try engine.start()
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

    private func beginRecognition() throws {
        let recognizer = try ensureRecognizer()
        let token = UUID(); generation = token
        let segmentID = token.uuidString
        segmentOrder.append(segmentID)
        speakerAnalyzer?.reset(segment: segmentID)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
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
                    self.lastResult = Date()
                    self.hardRetryCount = 0
                    self.softRetryCount = 0
                    if SpeechRecognitionPolicy.shouldCommitBeforeReplacing(previous: self.partial, incoming: text) {
                        self.commitPartial()
                    }
                    self.partial = text
                    // Publish raw STT before optional token alignment or speaker analysis.
                    self.onText?([self.committed, text].filter { !$0.isEmpty }.joined(separator: "\n"))
                    self.onStatus?(self.externalAudio ? "Mac 재생음 STT 수신 중" : "STT 수신 중")
                    if let words, !words.isEmpty { self.segmentTokens[segmentID] = words; self.renderTurns() }
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
            do { try self.beginRecognition() }
            catch { self.recoverHard(reason: error.localizedDescription, rebuildAudio: false) }
        }
    }

    private func recoverHard(reason: String, rebuildAudio: Bool) {
        guard active, recovery == nil else { return }
        hardRetryCount += 1
        guard hardRetryCount <= 5 else {
            stop()
            onError?("음성 인식이 복구되지 않았습니다. 입력 장치와 권한·네트워크를 확인한 뒤 듣기를 다시 시작해주세요.")
            return
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

    private func commitPartial() { committed = [committed, partial].filter { !$0.isEmpty }.joined(separator: "\n"); partial = "" }

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

    func stop() {
        active = false
        sink.setAccepting(false)
        watchdog?.cancel(); watchdog = nil
        recovery?.cancel(); recovery = nil
        stopRecognition(); stopAudio()
        recognizer = nil
        speakerAnalyzer?.stop(); speakerAnalyzer = nil
    }

    private func stopRecognition() {
        generation = UUID(); rotation?.cancel(); rotation = nil; sink.replace(nil)
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
