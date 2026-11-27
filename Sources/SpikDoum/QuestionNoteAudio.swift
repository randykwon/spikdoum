import Foundation
import AVFoundation
import Speech

/// Maintains a lightweight 45-second rolling PCM ring buffer (24kHz mono Float32) of live mic/system audio
/// AND supports dedicated active question recording (even when main STT listening is paused).
/// Each captured question is encoded to its own standalone playable `.m4a` file inside `Recordings/<conversationID>/`.
final class QuestionAudioClipRecorder: @unchecked Sendable {
    enum Source { case mic, system }

    private static let sampleRate: Double = 24000
    private static let maxRingSeconds: Double = 45.0
    private static let maxRingSamples: Int = Int(sampleRate * maxRingSeconds)
    private static let maxManualSeconds: Double = 300.0
    private static let maxManualSamples: Int = Int(sampleRate * maxManualSeconds)
    private static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private struct Chunk {
        var startedAt: Date
        var endedAt: Date
        var samples: [Float]
    }

    private let queue = DispatchQueue(label: "SpikDoum.QuestionClipRecorder", qos: .utility)
    private var converters: [Source: (format: AVAudioFormat, converter: AVAudioConverter)] = [:]
    private var ringChunks: [Chunk] = []
    private var ringSampleCount: Int = 0

    // Active manual question recording state
    private var manualActive = false
    private var manualStartedAt = Date()
    private var manualSamples: [Float] = []
    private var standaloneEngine: AVAudioEngine?

    func append(_ buffer: AVAudioPCMBuffer, source: Source) {
        guard buffer.frameLength > 0, let copy = Self.copyBuffer(buffer) else { return }
        let now = Date()
        queue.async { [weak self] in
            self?.consume(copy, source: source, arrivedAt: now)
        }
    }

    /// Direct PCM append helper (useful for unit tests and synthetic audio).
    func appendMonoSamples(_ samples: [Float], at endedAt: Date = Date()) {
        guard !samples.isEmpty else { return }
        queue.sync {
            let duration = Double(samples.count) / Self.sampleRate
            let chunk = Chunk(startedAt: endedAt.addingTimeInterval(-duration), endedAt: endedAt, samples: samples)
            self.pushChunk(chunk)
        }
    }

    func clearBuffer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ringChunks.removeAll()
            self.ringSampleCount = 0
            self.converters.removeAll()
        }
    }

    /// Starts dedicated recording for an ongoing audience question, automatically prepending `preRollSeconds`
    /// from the rolling ring buffer so the first words are never cut off.
    /// If main STT capture is not running (`useStandaloneMic == true`), attaches a lightweight mic tap.
    func startManualRecording(preRollSeconds: Double = 2.0, useStandaloneMic: Bool = false) throws {
        var engineError: Error?
        queue.sync {
            let now = Date()
            let preRollStart = now.addingTimeInterval(-max(0, preRollSeconds))
            let preRoll = self.sliceRingSamples(from: preRollStart, to: now)
            self.manualSamples = preRoll
            self.manualStartedAt = preRoll.isEmpty ? now : now.addingTimeInterval(-Double(preRoll.count) / Self.sampleRate)
            self.manualActive = true
        }
        if useStandaloneMic {
            do {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else {
                    throw NSError(domain: "SpikDoum.QuestionRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용 가능한 마이크 입력을 찾지 못했습니다."])
                }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    self?.append(buffer, source: .mic)
                }
                engine.prepare()
                try engine.start()
                queue.sync { self.standaloneEngine = engine }
            } catch {
                engineError = error
            }
        }
        if let engineError { throw engineError }
    }

    func cancelManualRecording() {
        queue.sync {
            self.stopStandaloneEngineLocked()
            self.manualActive = false
            self.manualSamples.removeAll()
        }
    }

    func stopManualRecordingAndExport(
        conversationID: UUID,
        recordingsRoot: URL,
        sourceSummary: String
    ) -> AudioClipRecord? {
        queue.sync {
            self.stopStandaloneEngineLocked()
            guard self.manualActive else { return nil }
            self.manualActive = false
            let samples = self.manualSamples
            let started = self.manualStartedAt
            self.manualSamples.removeAll()
            return self.writeAACClip(
                samples: samples,
                startedAt: started,
                conversationID: conversationID,
                recordingsRoot: recordingsRoot,
                sourceSummary: sourceSummary
            )
        }
    }

    /// Retroactively exports a standalone `.m4a` clip from the rolling ring buffer for a question that was just asked.
    func exportRecentClip(
        conversationID: UUID,
        recordingsRoot: URL,
        from startDate: Date?,
        to endDate: Date?,
        fallbackSeconds: Double = 14.0,
        sourceSummary: String
    ) -> AudioClipRecord? {
        queue.sync {
            let now = Date()
            let sliceStart: Date
            let sliceEnd: Date
            if let startDate {
                sliceStart = startDate.addingTimeInterval(-1.2)
                sliceEnd = (endDate ?? now).addingTimeInterval(0.8)
            } else {
                sliceStart = now.addingTimeInterval(-max(2.0, fallbackSeconds))
                sliceEnd = now
            }
            var samples = self.sliceRingSamples(from: sliceStart, to: sliceEnd)
            var actualStart = sliceStart
            if samples.count < Int(Self.sampleRate * 0.35) {
                // Fallback to the tail of the rolling buffer if timestamp window was slightly off
                let tailStart = now.addingTimeInterval(-max(4.0, fallbackSeconds))
                samples = self.sliceRingSamples(from: tailStart, to: now)
                actualStart = now.addingTimeInterval(-Double(samples.count) / Self.sampleRate)
            } else {
                actualStart = min(now, sliceEnd).addingTimeInterval(-Double(samples.count) / Self.sampleRate)
            }
            return self.writeAACClip(
                samples: samples,
                startedAt: actualStart,
                conversationID: conversationID,
                recordingsRoot: recordingsRoot,
                sourceSummary: sourceSummary
            )
        }
    }

    // MARK: - Question Detection Heuristic (Unit-Testable)

    /// Detects whether a newly spoken utterance during a presentation is likely an audience question.
    static func isLikelyQuestion(_ rawText: String, sourceTag: String?, inQAMode: Bool) -> Bool {
        let text = TranslationPolicy.displayText(strippingSourceTag: rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return false }

        // In Google Meet / Zoom / Teams presentations, remote audience speech comes over [Mac 재생음].
        // Any substantive audience utterance (>10 chars) during a presentation is worth capturing as a question/comment!
        if sourceTag == "Mac 재생음" && text.count >= 10 {
            return true
        }

        let lower = text.lowercased()
        if text.contains("?") || text.contains("？") {
            return true
        }

        // Only auto-capture microphone utterances without '?' when in Q&A mode or clearly interrogative.
        let koreanMarkers = ["질문", "궁금", "여쭤", "어떻게", "무엇", "왜 ", "인가요", "할까요", "있나요", "되나요", "인지요", "알 수 있을까요", "설명해"]
        let englishStarts = ["how ", "what ", "why ", "when ", "where ", "who ", "which ", "can you ", "could you ", "would you ", "do you ", "does ", "did ", "is there ", "are there ", "have you ", "my question"]

        if inQAMode {
            if koreanMarkers.contains(where: { lower.contains($0) }) { return true }
            if englishStarts.contains(where: { lower.hasPrefix($0) || lower.contains(" " + $0) }) { return true }
        }
        return false
    }

    // MARK: - Internal Audio Processing

    private func consume(_ buffer: AVAudioPCMBuffer, source: Source, arrivedAt: Date) {
        guard let samples = convertToMono(buffer, source: source), !samples.isEmpty else { return }
        let duration = Double(samples.count) / Self.sampleRate
        let chunk = Chunk(startedAt: arrivedAt.addingTimeInterval(-duration), endedAt: arrivedAt, samples: samples)
        pushChunk(chunk)
    }

    private func pushChunk(_ chunk: Chunk) {
        // Merge/append cleanly into ring buffer.
        // If two sources arrive simultaneously within 150ms, mix overlapping tail to avoid doubling duration.
        if let last = ringChunks.last,
           abs(last.endedAt.timeIntervalSince(chunk.endedAt)) < 0.15,
           last.samples.count == chunk.samples.count {
            var mixed = last.samples
            for i in 0..<mixed.count {
                mixed[i] = max(-1.0, min(1.0, (mixed[i] + chunk.samples[i]) * 0.85))
            }
            ringChunks[ringChunks.count - 1].samples = mixed
            if manualActive && manualSamples.count >= mixed.count {
                let offset = manualSamples.count - mixed.count
                for i in 0..<mixed.count {
                    manualSamples[offset + i] = mixed[i]
                }
            }
            return
        }

        ringChunks.append(chunk)
        ringSampleCount += chunk.samples.count
        while ringSampleCount > Self.maxRingSamples, !ringChunks.isEmpty {
            let removed = ringChunks.removeFirst()
            ringSampleCount -= removed.samples.count
        }

        if manualActive && manualSamples.count < Self.maxManualSamples {
            let room = Self.maxManualSamples - manualSamples.count
            if chunk.samples.count <= room {
                manualSamples.append(contentsOf: chunk.samples)
            } else {
                manualSamples.append(contentsOf: chunk.samples.prefix(room))
            }
        }
    }

    private func sliceRingSamples(from startDate: Date, to endDate: Date) -> [Float] {
        var collected: [Float] = []
        for chunk in ringChunks {
            if chunk.endedAt >= startDate && chunk.startedAt <= endDate {
                collected.append(contentsOf: chunk.samples)
            }
        }
        return collected
    }

    private func stopStandaloneEngineLocked() {
        if let engine = standaloneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            standaloneEngine = nil
        }
    }

    private func writeAACClip(
        samples: [Float],
        startedAt: Date,
        conversationID: UUID,
        recordingsRoot: URL,
        sourceSummary: String
    ) -> AudioClipRecord? {
        let duration = Double(samples.count) / Self.sampleRate
        guard duration >= 0.30 else { return nil }

        let folder = RecordingStorage.conversationFolder(for: conversationID, root: recordingsRoot)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID()
            let filename = "question-\(id.uuidString).m4a"
            let url = folder.appendingPathComponent(filename)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            do {
                let audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let chunkSize = 8192
                var cursor = 0
                while cursor < samples.count {
                    let count = min(chunkSize, samples.count - cursor)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: AVAudioFrameCount(count)),
                          let dst = buffer.floatChannelData?[0] else { break }
                    buffer.frameLength = AVAudioFrameCount(count)
                    samples.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            memcpy(dst, base.advanced(by: cursor), count * MemoryLayout<Float>.size)
                        }
                    }
                    try audioFile.write(from: buffer)
                    cursor += count
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AudioClipRecord(
                id: id,
                filename: filename,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(duration),
                duration: duration,
                sourceSummary: sourceSummary
            )
        } catch {
            return nil
        }
    }

    private func convertToMono(_ buffer: AVAudioPCMBuffer, source: Source) -> [Float]? {
        let converter: AVAudioConverter
        if let existing = converters[source], existing.format == buffer.format {
            converter = existing.converter
        } else {
            guard let created = AVAudioConverter(from: buffer.format, to: Self.canonicalFormat) else { return nil }
            converters[source] = (buffer.format, created)
            converter = created
        }
        let ratio = Self.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return nil }
        var result = [Float]()
        result.reserveCapacity(Int(output.frameLength))
        for i in 0..<Int(output.frameLength) {
            let s = channel[i]
            result.append(s.isFinite ? max(-1.0, min(1.0, s)) : 0)
        }
        return result
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(src, dst) {
            if let from = input.mData, let to = output.mData {
                memcpy(to, from, Int(min(input.mDataByteSize, output.mDataByteSize)))
            }
        }
        return copy
    }
}

/// Lightweight inline `.m4a` player for individual Question Post-it cards.
@MainActor
final class QuestionAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var activeNoteID: UUID? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playbackError: String? = nil

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func togglePlay(noteID: UUID, url: URL) {
        if activeNoteID == noteID, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                progressTask?.cancel()
            } else {
                player.play()
                isPlaying = true
                startProgressLoop()
            }
            return
        }

        stop()
        playbackError = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            playbackError = "저장된 질문 음성 파일을 찾지 못했습니다."
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            activeNoteID = noteID
            duration = p.duration
            currentTime = 0
            isPlaying = true
            startProgressLoop()
        } catch {
            playbackError = "음성 재생 실패: \(error.localizedDescription)"
        }
    }

    func seek(noteID: UUID, to time: TimeInterval) {
        guard activeNoteID == noteID, let player else { return }
        player.currentTime = max(0, min(player.duration, time))
        currentTime = player.currentTime
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        activeNoteID = nil
        currentTime = 0
        duration = 0
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, let player = self.player, player.isPlaying else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}

/// Transcribes a recorded standalone question `.m4a` clip into text.
/// Decodes `.m4a` cleanly to 16kHz mono PCM16, supporting Managed Whisper (multilingual auto-detect),
/// Parakeet ANE, and macOS Speech (`SFSpeechURLRecognitionRequest`) with multi-locale fallback & timeout.
enum QuestionAudioTranscriber {
    /// Decodes an `.m4a` / audio file to 16kHz mono Int16 PCM data across full EOF (never truncating).
    static func decodeTo16kMonoPCM16(url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CloudFailure(message: "질문 음성 포맷 변환에 실패했습니다.")
        }

        let readChunkSize: AVAudioFrameCount = 8192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readChunkSize) else {
            return Data()
        }

        var pcmData = Data()
        let ratio = 16000.0 / max(1.0, inputFormat.sampleRate)
        let outChunkFrames = AVAudioFrameCount(Double(readChunkSize) * ratio + 256)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outChunkFrames) else {
            return Data()
        }

        let maxInputFrames = Int64(inputFormat.sampleRate * 300) // cap at 5 minutes
        var totalReadFrames: Int64 = 0

        while file.framePosition < file.length && totalReadFrames < maxInputFrames {
            let remaining = Int64(file.length - file.framePosition)
            let toRead = AVAudioFrameCount(min(Int64(readChunkSize), remaining))
            guard toRead > 0 else { break }
            readBuffer.frameLength = 0
            do {
                try file.read(into: readBuffer, frameCount: toRead)
            } catch {
                break
            }
            guard readBuffer.frameLength > 0 else { break }
            totalReadFrames += Int64(readBuffer.frameLength)

            var supplied = false
            var convError: NSError?
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return readBuffer
            }
            if convError != nil || status == .error { break }
            if outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData?[0] {
                pcmData.append(Data(bytes: channel, count: Int(outBuffer.frameLength) * MemoryLayout<Int16>.size))
            }
        }
        return pcmData
    }

    static func transcribeWithManagedWhisper(pcm16: Data, key: String, languageHint: String) async throws -> String {
        guard !pcm16.isEmpty, !key.isEmpty else { return "" }
        let wav = ManagedSTTClient.wave(pcm: pcm16)
        let client = ManagedSTTClient(key: key)
        let raw = try await client.transcribe(wave: wav, language: languageHint)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcribeWithAppleSpeech(url: URL, localeIdentifiers: [String]) async throws -> String {
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw CloudFailure(message: "macOS 음성 인식 권한이 필요합니다. (또는 모델 관리에서 Whisper/Parakeet 모델을 사용하세요)")
        }

        var uniqueLocales: [String] = []
        for id in localeIdentifiers {
            let cleaned = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned != LanguageCatalog.autoCode && !uniqueLocales.contains(cleaned) {
                uniqueLocales.append(cleaned)
            }
        }
        if uniqueLocales.isEmpty {
            uniqueLocales.append(Locale.current.identifier)
        }

        var lastError: Error?
        for localeID in uniqueLocales {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
                  recognizer.isAvailable else { continue }
            do {
                let text = try await runSingleAppleRecognition(recognizer: recognizer, url: url)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return ""
    }

    private static func runSingleAppleRecognition(recognizer: SFSpeechRecognizer, url: URL) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var task: SFSpeechRecognitionTask?

            let finish: (Result<String, Error>) -> Void = { outcome in
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let activeTask = task
                task = nil
                lock.unlock()
                activeTask?.cancel()
                switch outcome {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                if let result, result.isFinal {
                    finish(.success(result.bestTranscription.formattedString))
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 18.0) {
                finish(.failure(CloudFailure(message: "Apple 음성 인식 시간이 초과되었습니다.")))
            }
        }
    }
}

/// Resolves the automatic translation target language for a Question Record:
/// - If the question language differs from the user's target language (e.g., English question for Korean user) -> translates into target language (Korean).
/// - If the question is already in the user's target language (e.g., Korean question during English presentation) -> translates into the presentation/STT language (English).
enum QuestionTranslationLanguageResolver {
    static func targetLanguage(
        for text: String,
        userTarget: SupportedLanguage,
        presentationLanguage: SupportedLanguage?
    ) -> SupportedLanguage? {
        let detected = LanguageCatalog.detectLanguage(for: text)
        if let detected {
            if detected.translationCode != userTarget.translationCode {
                return userTarget
            }
            if let pres = presentationLanguage, pres.translationCode != userTarget.translationCode {
                return pres
            }
            return nil
        }
        return userTarget
    }
}

/// Parses structured bilingual or single-language recommended answer output from LLM.
enum QuestionAnswerParser {
    static func parse(_ raw: String) -> (speak: String, local: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        if let speakRange = trimmed.range(of: "[ANSWER_SPEAK]") {
            let afterSpeak = String(trimmed[speakRange.upperBound...])
            if let localRange = afterSpeak.range(of: "[ANSWER_LOCAL]") {
                let speakPart = String(afterSpeak[..<localRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let localPart = String(afterSpeak[localRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    speakPart.isEmpty ? trimmed : speakPart,
                    localPart.isEmpty ? nil : localPart
                )
            }
            let speakOnly = afterSpeak.trimmingCharacters(in: .whitespacesAndNewlines)
            return (speakOnly.isEmpty ? trimmed : speakOnly, nil)
        }
        return (trimmed, nil)
    }
}
