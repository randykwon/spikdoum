import Foundation
import AVFoundation
import Testing
@testable import SpikDoum

@Test func summaryDigestParsesPlainAndCodeFencedJSON() throws {
    let plain = #"{"title":"회의 정리","preview":"일정 합의","summary":"다음 주 화요일 배포"}"#
    let parsedPlain = try SummaryPolicy.parseDigest(plain)
    #expect(parsedPlain.title == "회의 정리")
    #expect(parsedPlain.preview == "일정 합의")
    #expect(parsedPlain.summary == "다음 주 화요일 배포")

    let fenced = "```json\n\(plain)\n```"
    let parsedFenced = try SummaryPolicy.parseDigest(fenced)
    #expect(parsedFenced == parsedPlain)

    #expect(throws: (any Error).self) {
        _ = try SummaryPolicy.parseDigest("not valid json")
    }
}

@Test func llmClientRejectsEmptyHostAndContentFilterFinishReason() throws {
    var settings = EngineSettings()
    settings.llm = .compatible
    settings.serverURL = "http:///v1"
    settings.serverModel = "qwen3:8b"
    #expect(throws: (any Error).self) {
        _ = try LLMClient(settings: settings, key: "").request(instructions: "sys", input: "hi")
    }

    let filtered = try SSEPayload.decode(#"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#)
    #expect(filtered.error != nil)
    #expect(!filtered.done)
}

@Test func translationRetainedHandlesUnicodeAndStopsAtRevision() {
    let first = "안녕 👋 반가워요. "
    let second = "오늘 일정 확인해요."
    let transcript = first + second
    let entries = [
        TranslationEntry(source: first, translated: "t1", sourceStart: 0, sourceEnd: first.count),
        TranslationEntry(source: "수정된 문장", translated: "t2", sourceStart: first.count, sourceEnd: first.count + 6)
    ]
    let kept = TranslationPolicy.retained(transcript: transcript, entries: entries)
    #expect(kept.entries.count == 1)
    #expect(kept.cursor == first.count)
    #expect(String(transcript[kept.index...]) == second)
}

@Test func nativeProcessMetricsReadsCurrentProcessWithoutSubprocess() throws {
    let metrics = try #require(ManagedModelManager.processMetrics(ProcessInfo.processInfo.processIdentifier))
    #expect(metrics.memoryMB > 0)
    #expect(metrics.cpuNS >= 0)
    #expect(ManagedModelManager.processMetrics(-1) == nil)
}

@Test func liveActivityScheduleOnlyTicksWhenActive() {
    let start = Date(timeIntervalSince1970: 1000)
    let idleEntries = Array(LiveActivitySchedule(active: false).entries(from: start, mode: .normal))
    #expect(idleEntries == [start])

    let activeEntries = Array(LiveActivitySchedule(active: true).entries(from: start, mode: .normal).prefix(3))
    #expect(activeEntries == [start, start.addingTimeInterval(1), start.addingTimeInterval(2)])
}

@Test func conversationStoreCoalescesAsyncSavesAndFlushesSync() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("conversations.json")
    let store = ConversationStore(file: file)

    var first = Conversation(title: "첫 대화", transcript: "Hello")
    let second = Conversation(title: "두 번째", transcript: "World")
    store.saveAsync([first]) { _ in }
    first.transcript = "Hello updated"
    store.saveAsync([first, second]) { _ in }
    store.cancelAndDrain()

    try store.saveSync([first, second])
    let loaded = try store.load()
    #expect(loaded.count == 2)
    #expect(loaded[0].transcript == "Hello updated")
    #expect(loaded[1].title == "두 번째")
}

@Test func managedAudioSplitsEarlyOnNaturalSilencePause() async throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var chunks: [Data] = []
        func append(_ data: Data) { lock.lock(); chunks.append(data); lock.unlock() }
        func snapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return chunks }
    }
    let collector = Collector()
    let bufferer = ManagedAudioBufferer()
    bufferer.start { collector.append($0) }

    func feed(samples: Int, amplitude: Float) throws {
        var sent = 0
        while sent < samples {
            let count = min(1600, samples - sent)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                buffer.floatChannelData![0][i] = amplitude * Float(sin(Double(sent + i) * 2 * .pi * 440 / 16000))
            }
            bufferer.append(buffer)
            sent += count
        }
    }

    // 1.7s voiced speech + 0.3s silence (~2.0s total) should split before the 3.0s hard cap.
    try feed(samples: 16000 * 17 / 10, amplitude: 0.25)
    try feed(samples: 16000 * 3 / 10, amplitude: 0)
    _ = await bufferer.finish()

    let chunks = collector.snapshot()
    #expect(chunks.count == 1)
    #expect(chunks[0].count >= 16000 * 2 * 16 / 10)
    #expect(chunks[0].count < 16000 * 2 * 3)
}

@Test func conversationSearchMatchesMetadataTranscriptTranslationAndSummary() {
    var active = Conversation(title: "Q3 로드맵", transcript: "Let us finalize the release schedule.")
    active.translations = [TranslationEntry(source: active.transcript, translated: "출시 일정을 확정합시다.", sourceStart: 0, sourceEnd: active.transcript.count)]
    active.summaries = ["all": SummaryState(text: "화요일 배포 합의", coveredSource: active.transcript, updatedAt: Date())]
    active.keywords = ConversationKeywords(terms: ["Roadmap", "Release"], date: Date(), source: active.transcript)

    var archived = Conversation(title: "지난 회의", transcript: "Old notes")
    archived.archivedAt = Date()

    let all = [active, archived]
    #expect(ConversationSearch.filter(all, query: "", archived: false).map(\.id) == [active.id])
    #expect(ConversationSearch.filter(all, query: "", archived: true).map(\.id) == [archived.id])
    #expect(ConversationSearch.filter(all, query: "출시 일정", archived: false).map(\.id) == [active.id])
    #expect(ConversationSearch.filter(all, query: "화요일 배포", archived: false).map(\.id) == [active.id])
    #expect(ConversationSearch.filter(all, query: "roadmap", archived: false).map(\.id) == [active.id])
    #expect(ConversationSearch.filter(all, query: "Old notes", archived: false).isEmpty)
    #expect(ConversationSearch.filter(all, query: "old notes", archived: true).map(\.id) == [archived.id])
}

@Test func conversationExportFormatsMarkdownAndSanitizesFilename() {
    var item = Conversation(title: "API/설계: 1차 회의", transcript: "Hello team. Ready to ship?")
    item.translations = [TranslationEntry(source: item.transcript, translated: "안녕하세요 팀. 배포 준비되셨나요?", sourceStart: 0, sourceEnd: item.transcript.count)]
    item.summaries = ["all": SummaryState(text: "배포 준비 확인", coveredSource: item.transcript, updatedAt: Date())]
    item.keywords = ConversationKeywords(terms: ["API", "ship"], date: Date(), source: item.transcript)
    item.advice = [Advice(text: "답변: Yes, we are ready. (네, 준비되었습니다.)")]

    let filename = ConversationExport.suggestedFilename(for: item)
    #expect(filename.hasSuffix(".md"))
    #expect(!filename.contains("/"))
    #expect(!filename.contains(":"))

    let md = ConversationExport.markdown(for: item)
    #expect(md.contains("# API/설계: 1차 회의"))
    #expect(md.contains("## 전체 요약"))
    #expect(md.contains("배포 준비 확인"))
    #expect(md.contains("`API` · `ship`"))
    #expect(md.contains("> **번역:** 안녕하세요 팀. 배포 준비되셨나요?"))
    #expect(md.contains("## 대화 코치 조언"))
}

@Test func speechPolicyCommitsOnDeviceUtteranceResetAndPreservesNormalRevisions() {
    #expect(SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "Right after lunch and I'm drinking literally my third drink",
        incoming: "OK guys that meeting went really well"
    ))
    // Same opening pronoun ("I") must still detect a new utterance reset.
    #expect(SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "I think we should ship the new feature on Tuesday and verify tests",
        incoming: "I will check the dashboard"
    ))
    // Large length shrink on a long utterance commits the prior sentence.
    #expect(SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "I have a one on one with my manager in a few minutes and we are discussing progress",
        incoming: "I have a question"
    ))
    // Space-less CJK utterance reset.
    #expect(SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "今日の会議では新しい機能について話します",
        incoming: "次のスケジュールを確認しましょう"
    ))
    // Normal in-place extensions and minor opening corrections must NOT split.
    #expect(!SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "I have a one on one with my",
        incoming: "I have a one-on-one with my manager"
    ))
    #expect(!SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "And so my fellow Americans",
        incoming: "Hand so my fellow Americans"
    ))
    #expect(!SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "今日の会議では",
        incoming: "今日の会議では新しい機能"
    ))
    #expect(!SpeechRecognitionPolicy.shouldCommitBeforeReplacing(
        previous: "We are",
        incoming: "Where are we going"
    ))
}

@Test func keywordHistoryPreservesEarlierTermsAcrossUpdatesAndExports() {
    let t1 = Date(timeIntervalSince1970: 100)
    let t2 = Date(timeIntervalSince1970: 200)
    var conversation = Conversation(title: "제품 회의", transcript: "Roadmap Budget Launch Metrics")
    let firstBatch = ConversationKeywords(terms: ["Roadmap", "Budget"], date: t1, source: "Roadmap Budget")
    let secondBatch = ConversationKeywords(terms: ["budget", "Launch", "Metrics"], date: t2, source: "Launch Metrics")
    conversation.keywordHistory = [firstBatch, secondBatch]
    conversation.keywords = secondBatch

    #expect(conversation.allKeywords == ["budget", "Launch", "Metrics", "Roadmap"])
    #expect(ConversationSearch.filter([conversation], query: "roadmap", archived: false).count == 1)
    let md = ConversationExport.markdown(for: conversation)
    #expect(md.contains("`budget` · `Launch` · `Metrics` · `Roadmap`"))
}

@Test func scriptFormatterOrganizesFullConversationWithLabelsAndModes() {
    let part1 = "[Mac 재생음] First sentence. Second sentence."
    let part2 = "\n[마이크] Third unfinished phrase"
    let full = part1 + part2
    let date = Date(timeIntervalSince1970: 1000)
    let conversation = Conversation(
        title: "스크립트 테스트",
        transcript: full,
        translations: [TranslationEntry(source: part1, translated: "첫 문장. 두 번째 문장.", sourceStart: 0, sourceEnd: part1.count)],
        transcriptSpans: [
            TranscriptSpan(date: date, start: 0, text: part1),
            TranscriptSpan(date: date.addingTimeInterval(10), start: part1.count, text: part2)
        ]
    )

    let items = ConversationScriptFormatter.items(for: conversation)
    #expect(items.count == 2)
    #expect(items[0].sourceLabel == "Mac 재생음")
    #expect(items[0].original == "First sentence. Second sentence.")
    #expect(items[0].translated == "첫 문장. 두 번째 문장.")
    #expect(items[1].sourceLabel == "마이크")
    #expect(items[1].original == "Third unfinished phrase")
    #expect(items[1].translated == nil)

    let bilingual = ConversationScriptFormatter.plainText(for: conversation, mode: .bilingual)
    #expect(bilingual.contains("First sentence. Second sentence."))
    #expect(bilingual.contains("→ 첫 문장. 두 번째 문장."))
    #expect(bilingual.contains("Third unfinished phrase"))

    let koreanOnly = ConversationScriptFormatter.plainText(for: conversation, mode: .koreanOnly)
    #expect(koreanOnly.contains("첫 문장. 두 번째 문장."))
    #expect(koreanOnly.contains("(번역 대기)"))

    let originalOnly = ConversationScriptFormatter.plainText(for: conversation, mode: .originalOnly)
    #expect(!originalOnly.contains("첫 문장"))
    #expect(originalOnly.contains("First sentence. Second sentence."))
}

@Test func conversationAudioRecorderWritesPlayableAACClipAndMixesDualSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let conversationID = UUID()
    let recorder = ConversationAudioRecorder()
    try recorder.start(conversationID: conversationID, recordingsRoot: root, dualSource: true, sourceSummary: "마이크 + Mac 재생음")

    let stereo48k = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
    let frameCount = 4800 // 0.1s per chunk
    for step in 0..<10 {
        let micBuf = try #require(AVAudioPCMBuffer(pcmFormat: stereo48k, frameCapacity: AVAudioFrameCount(frameCount)))
        micBuf.frameLength = AVAudioFrameCount(frameCount)
        let sysBuf = try #require(AVAudioPCMBuffer(pcmFormat: stereo48k, frameCapacity: AVAudioFrameCount(frameCount)))
        sysBuf.frameLength = AVAudioFrameCount(frameCount)
        for ch in 0..<2 {
            for i in 0..<frameCount {
                let sampleIndex = Double(step * frameCount + i)
                micBuf.floatChannelData![ch][i] = Float(sin(sampleIndex * 2 * .pi * 440 / 48000)) * 0.25
                sysBuf.floatChannelData![ch][i] = Float(sin(sampleIndex * 2 * .pi * 660 / 48000)) * 0.25
            }
        }
        recorder.append(micBuf, source: .mic)
        recorder.append(sysBuf, source: .system)
    }

    let clip = try #require(recorder.stopAndFinalize())
    #expect(clip.filename.hasSuffix(".m4a"))
    #expect(clip.duration >= 0.8 && clip.duration <= 1.2)
    let fileURL = RecordingStorage.clipURL(conversationID: conversationID, filename: clip.filename, root: root)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let player = try AVAudioPlayer(contentsOf: fileURL)
    #expect(player.duration >= 0.8)
}

@Test func replayTimelineReproducesSTTTranslationAdviceSummaryAndKeywordsByTimestamp() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let part1 = "First part of the meeting. "
    let part2 = "Second part with launch date."
    let full = part1 + part2
    let clip = AudioClipRecord(filename: "clip1.m4a", startedAt: t0, endedAt: t0.addingTimeInterval(20), duration: 20, sourceSummary: "Mac 재생음")

    var conversation = Conversation(title: "최종 제목", transcript: full)
    conversation.audioClips = [clip]
    conversation.transcriptSpans = [
        TranscriptSpan(date: t0.addingTimeInterval(2), start: 0, text: part1),
        TranscriptSpan(date: t0.addingTimeInterval(12), start: part1.count, text: part2)
    ]
    conversation.translations = [
        TranslationEntry(source: part1, date: t0.addingTimeInterval(4), translated: "회의 첫 부분.", sourceStart: 0, sourceEnd: part1.count),
        TranslationEntry(source: part2, date: t0.addingTimeInterval(15), translated: "출시일이 포함된 두 번째 부분.", sourceStart: part1.count, sourceEnd: full.count)
    ]
    conversation.keywordHistory = [
        ConversationKeywords(terms: ["meeting"], date: t0.addingTimeInterval(5), source: part1),
        ConversationKeywords(terms: ["launch date"], date: t0.addingTimeInterval(16), source: part2)
    ]
    conversation.keywords = conversation.keywordHistory?.last
    conversation.advice = [
        Advice(date: t0.addingTimeInterval(6), text: "첫 번째 조언"),
        Advice(date: t0.addingTimeInterval(17), text: "두 번째 조언")
    ]
    conversation.summaryHistory = [
        SummarySnapshot(date: t0.addingTimeInterval(8), title: "1차 제목", preview: "1차 미리보기", text: "1차 요약"),
        SummarySnapshot(date: t0.addingTimeInterval(18), title: "최종 제목", preview: "최종 미리보기", text: "최종 요약")
    ]
    conversation.summaries = ["all": SummaryState(text: "최종 요약", coveredSource: full, updatedAt: t0.addingTimeInterval(18))]

    let timeline = ReplayTimeline(conversation: conversation)
    #expect(timeline.duration == 20)
    #expect(timeline.activeClip(at: 7)?.clip.id == clip.id)
    #expect(timeline.activeClip(at: 7)?.clipOffset == 7)

    // At t = 7s: only part1, translation1, keyword1, advice1 are visible; summary hasn't arrived yet (t=8s).
    let snap7 = timeline.snapshot(at: 7)
    #expect(snap7.transcript == part1)
    #expect(snap7.translations?.count == 1)
    #expect(snap7.allKeywords == ["meeting"])
    #expect(snap7.advice.map(\.text) == ["첫 번째 조언"])
    #expect(snap7.summaries?["all"] == nil)

    // At t = 10s: summary #1 has appeared, part2 still hidden.
    let snap10 = timeline.snapshot(at: 10)
    #expect(snap10.summaries?["all"]?.text == "1차 요약")
    #expect(snap10.title == "1차 제목")
    #expect(snap10.transcript == part1)

    // At t = 20s (end): everything is visible.
    let snapEnd = timeline.snapshot(at: 20)
    #expect(snapEnd.transcript == full)
    #expect(snapEnd.translations?.count == 2)
    #expect(snapEnd.allKeywords == ["launch date", "meeting"])
    #expect(snapEnd.advice.count == 2)
    #expect(snapEnd.summaries?["all"]?.text == "최종 요약")
}

@Test func permanentRemovalDeletesRecordedAudioDirectory() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let file = folder.appendingPathComponent("conversations.json")
    let keep = Conversation(title: "보관 대화", transcript: "keep")
    let remove = Conversation(title: "삭제 대화", transcript: "remove")
    try JSONEncoder().encode([keep, remove]).write(to: file)

    let root = RecordingStorage.recordingsRoot(nextTo: file)
    let keepClip = RecordingStorage.clipURL(conversationID: keep.id, filename: "a.m4a", root: root)
    let removeClip = RecordingStorage.clipURL(conversationID: remove.id, filename: "b.m4a", root: root)
    try FileManager.default.createDirectory(at: keepClip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: removeClip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio1".utf8).write(to: keepClip)
    try Data("audio2".utf8).write(to: removeClip)

    try ConversationLifecycle.persistRemoval(id: remove.id, remaining: [keep], file: file)
    #expect(FileManager.default.fileExists(atPath: keepClip.path))
    #expect(!FileManager.default.fileExists(atPath: removeClip.deletingLastPathComponent().path))
}

@Test func scriptParagraphGroupingMergesRelatedSentencesAndSplitsOnPauseOrSourceChange() {
    let t0 = Date(timeIntervalSince1970: 2000)
    let b1 = "[Mac 재생음] First sentence here."
    let b2 = " Second sentence\ncontinued nicely."
    let b3 = "\n[Mac 재생음] After a long pause we moved to pricing."
    let b4 = "\n[마이크] That sounds reasonable to me."
    let full = b1 + b2 + b3 + b4
    let conversation = Conversation(
        title: "문단 테스트",
        transcript: full,
        translations: [
            TranslationEntry(source: b1, translated: "첫 문장입니다.", sourceStart: 0, sourceEnd: b1.count),
            TranslationEntry(source: b2, translated: "두 번째 문장입니다.", sourceStart: b1.count, sourceEnd: b1.count + b2.count),
            TranslationEntry(source: b3, translated: "긴 공백 후 가격 이야기로 넘어갔습니다.", sourceStart: b1.count + b2.count, sourceEnd: b1.count + b2.count + b3.count),
            TranslationEntry(source: b4, translated: "합리적으로 들리네요.", sourceStart: b1.count + b2.count + b3.count, sourceEnd: full.count)
        ],
        transcriptSpans: [
            TranscriptSpan(date: t0, start: 0, text: b1),
            TranscriptSpan(date: t0.addingTimeInterval(3), start: b1.count, text: b2),
            TranscriptSpan(date: t0.addingTimeInterval(25), start: b1.count + b2.count, text: b3),
            TranscriptSpan(date: t0.addingTimeInterval(28), start: b1.count + b2.count + b3.count, text: b4)
        ]
    )

    let paragraphs = ConversationScriptFormatter.paragraphs(for: conversation)
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0].sourceLabel == "Mac 재생음")
    #expect(paragraphs[0].originalText == "First sentence here. Second sentence continued nicely.")
    #expect(paragraphs[0].translatedText == "첫 문장입니다. 두 번째 문장입니다.")
    #expect(paragraphs[1].sourceLabel == "Mac 재생음")
    #expect(paragraphs[1].originalText == "After a long pause we moved to pricing.")
    #expect(paragraphs[2].sourceLabel == "마이크")
    #expect(paragraphs[2].translatedText == "합리적으로 들리네요.")

    let sections = ConversationScriptFormatter.parseOrganizedSections("""
    ### 프로젝트 일정
    첫 번째 문단입니다. 마침표와 문장이 정리되었습니다.

    두 번째 문단입니다.

    ### 가격 논의
    세 번째 문단입니다.
    """)
    #expect(sections.count == 2)
    #expect(sections[0].heading == "프로젝트 일정")
    #expect(sections[0].paragraphs.count == 2)
    #expect(sections[1].heading == "가격 논의")
    #expect(sections[1].paragraphs == ["세 번째 문단입니다."])
}

@Test func multilingualCatalogL10nAndAutoDetectParametersWorkAcrossAllEngines() throws {
    #expect(LanguageCatalog.all.count >= 12)
    #expect(LanguageCatalog.whisperLanguageParameter(for: "auto") == "auto")
    #expect(LanguageCatalog.whisperLanguageParameter(for: "ja-JP") == "ja")
    #expect(LanguageCatalog.language(for: "zh-TW")?.azureCode == "zh-Hant")

    // Managed Whisper STT sends "auto" cleanly when auto-detect is selected.
    let wave = ManagedSTTClient.wave(pcm: Data([1, 0, 2, 0]))
    let whisperAuto = ManagedSTTClient(key: "tok").request(wave: wave, language: "auto")
    #expect(String(decoding: whisperAuto.httpBody!, as: UTF8.self).contains("name=\"language\"\r\n\r\nauto"))

    // Deepgram omits invalid "au" hint when language is "auto".
    let dgAuto = CloudSpeechCapture.request(key: "k", sampleRate: 16000, language: "auto")
    let dgParams = Dictionary(uniqueKeysWithValues: (URLComponents(url: dgAuto.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(dgParams["language"] == "multi")
    #expect(dgParams["language_hint"] == nil)

    // UI Localization covers Korean, English, Japanese, and Simplified Chinese.
    #expect(L10n.t("action.startListening", lang: .ko) == "듣기 시작")
    #expect(L10n.t("action.startListening", lang: .en) == "Start Listening")
    #expect(L10n.t("action.startListening", lang: .ja) == "聞き取り開始")
    #expect(L10n.t("action.startListening", lang: .zhHans) == "开始监听")

    // Multilingual NO_CHANGE suppression across languages.
    #expect(AdvicePolicy.isNoChange("NO_CHANGE"))
    #expect(AdvicePolicy.isNoChange("변경 없음"))
    #expect(AdvicePolicy.isNoChange("変更なし"))
    #expect(AdvicePolicy.isNoChange("无变化"))
    #expect(!AdvicePolicy.isNoChange("Ask about the launch timeline."))
}

@Test func speechPolicyClassifiesTransientSilenceErrorsAndBoundsBackoff() {
    #expect(SpeechRecognitionPolicy.isTransientError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
    #expect(SpeechRecognitionPolicy.isTransientError(NSError(domain: "kAFAssistantErrorDomain", code: 203)))
    #expect(SpeechRecognitionPolicy.isTransientError(NSError(domain: "kAFAssistantErrorDomain", code: 301)))
    #expect(SpeechRecognitionPolicy.isTransientError(NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)))
    #expect(!SpeechRecognitionPolicy.isTransientError(NSError(domain: "kAFAssistantErrorDomain", code: 1700)))
    #expect(!SpeechRecognitionPolicy.isTransientError(CaptureError.message("권한 오류")))

    #expect(SpeechRecognitionPolicy.softBackoffSeconds(attempt: 1) == 0.5)
    #expect(SpeechRecognitionPolicy.softBackoffSeconds(attempt: 2) == 2.0)
    #expect(SpeechRecognitionPolicy.softBackoffSeconds(attempt: 10) == 4.0)
}

@Test func disconnectedSavedInputDeviceFallsBackToSystemDefaultWhenAvailable() {
    let builtIn = AudioInputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Air 마이크")
    let usb = AudioInputDevice(id: 2, uid: "USB-C930c", name: "Webcam Mic")

    let defaultChoice = AudioInputDevices.effectiveSelection(preferredUID: "", available: [builtIn])
    #expect(defaultChoice.uid == "")
    #expect(!defaultChoice.fellBackToDefault)

    let connectedChoice = AudioInputDevices.effectiveSelection(preferredUID: usb.uid, available: [builtIn, usb])
    #expect(connectedChoice.uid == usb.uid)
    #expect(!connectedChoice.fellBackToDefault)

    let disconnectedChoice = AudioInputDevices.effectiveSelection(preferredUID: "AC-07-75-E8-42-49:input", available: [builtIn, usb])
    #expect(disconnectedChoice.uid == "")
    #expect(disconnectedChoice.fellBackToDefault)

    let noDevicesChoice = AudioInputDevices.effectiveSelection(preferredUID: "AC-07-75-E8-42-49:input", available: [])
    #expect(noDevicesChoice.uid == "AC-07-75-E8-42-49:input")
    #expect(!noDevicesChoice.fellBackToDefault)
}

@Test func legacySpeakHelperSupportDirectoryMigratesOnceToSpikDoum() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let legacy = base.appendingPathComponent("SpeakHelper")
    let target = base.appendingPathComponent("SpikDoum")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    try Data("[]".utf8).write(to: legacy.appendingPathComponent("conversations.json"))
    AppStorageMigration.migrateSupportDirectoryIfNeeded(in: base)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("conversations.json").path))

    // Subsequent calls do not overwrite newer SpikDoum data.
    try Data("[{\"updated\":true}]".utf8).write(to: target.appendingPathComponent("conversations.json"))
    AppStorageMigration.migrateSupportDirectoryIfNeeded(in: base)
    let kept = try String(contentsOf: target.appendingPathComponent("conversations.json"), encoding: .utf8)
    #expect(kept.contains("updated"))
}

@Test func autoDetectLanguageRecognitionStripsSourcePrefixesAndHandlesMultipleLanguages() {
    #expect(LanguageCatalog.detectLanguage(for: "[마이크] Hello everyone, let's review the project schedule today.")?.code == "en-US")
    #expect(LanguageCatalog.detectLanguage(for: "[Mac 재생음] 明日の会議について話し合いましょう。")?.code == "ja-JP")
    #expect(LanguageCatalog.detectLanguage(for: "[마이크] 오늘 회의 일정을 먼저 확인해 주세요.")?.code == "ko-KR")
    #expect(LanguageCatalog.detectLanguage(for: "[Mac 재생음] Bonjour tout le monde, comment allez-vous aujourd'hui?")?.code == "fr-FR")
    #expect(LanguageCatalog.detectLanguage(for: "[마이크] ok") == nil)
}
