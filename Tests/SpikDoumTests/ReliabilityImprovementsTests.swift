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

@Test func managedAudioTrimsExcessLeadingSilenceBeforeSpeech() async throws {
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

    // 2.0s silence followed by 1.0s speech + 0.3s trailing silence should trim leading silence to pre-roll (~0.16s).
    try feed(samples: 16000 * 2, amplitude: 0)
    try feed(samples: 16000, amplitude: 0.25)
    try feed(samples: 16000 * 3 / 10, amplitude: 0)
    _ = await bufferer.finish()

    let chunks = collector.snapshot()
    #expect(chunks.count == 1)
    // Total emitted bytes should be ~1.36s (< 2.0s), proving the 2.0s leading silence was trimmed.
    #expect(chunks[0].count < 16000 * 2 * 2)
    #expect(chunks[0].count >= 16000 * 2 * 9 / 10)
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

@Test func panelLayoutReordersPersistsNormalizesAndResetsCleanly() throws {
    let suiteName = "SpikDoum.PanelLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var layout = PanelLayout(splitOrder: [.translation, .translation, .stt])
    #expect(layout.splitOrder == [.translation, .stt, .coach, .summaryScript])

    // Drag-and-drop reorder: move summaryScript to the leftmost slot.
    layout.move(.summaryScript, to: .translation)
    #expect(layout.splitOrder == [.summaryScript, .translation, .stt, .coach])

    // Arrow move skips hidden summaryScript when includeSummaryScript is false.
    layout.move(.translation, by: 1, includeSummaryScript: false)
    #expect(layout.splitOrder == [.summaryScript, .stt, .translation, .coach])

    layout.swapLinkedSide()
    layout.toggleSummaryScriptOrder()
    layout.save(defaults: defaults)

    let reloaded = PanelLayout.load(defaults: defaults)
    #expect(reloaded == layout)
    #expect(reloaded.linkedSummaryOnLeft)
    #expect(reloaded.summaryScriptReversed)

    layout.reset()
    #expect(layout.splitOrder == PanelLayout.defaultOrder)
    #expect(!layout.linkedSummaryOnLeft)
    #expect(!layout.summaryScriptReversed)
}

@Test func targetLanguageSwitchInvalidatesOldTranslationsAndWhisperNoiseIsCleaned() {
    let source = "おはようございます。今日はいい天気ですね。"
    let koreanEntry = TranslationEntry(source: source, translated: "좋은 아침입니다. 오늘 날씨가 좋네요.", targetLanguage: "ko-KR", sourceStart: 0, sourceEnd: source.count)
    let legacyEntry = TranslationEntry(source: source, translated: "좋은 아침입니다.", targetLanguage: nil, sourceStart: 0, sourceEnd: source.count)

    // Keeping same target language retains existing entries.
    #expect(TranslationPolicy.retained(transcript: source, entries: [koreanEntry], targetLanguage: "ko-KR").entries.count == 1)
    #expect(TranslationPolicy.retained(transcript: source, entries: [legacyEntry], targetLanguage: "ko-KR").entries.count == 1)

    // Switching to English translation invalidates Korean entries so they re-translate into English.
    let switched = TranslationPolicy.plan(transcript: source, entries: [koreanEntry], flush: true, targetLanguage: "en-US")
    #expect(switched.retained.isEmpty)
    #expect(switched.source == source)

    // Whisper non-speech noise and fragmented lines are cleaned before Apple Translation.
    let noisy = "[Mac 재생음] [BLANK_AUDIO]\n(snoring)\n[Bell]\n(音楽)\n[Mac 재생음] おはようございます。\n今日はいい天気ですね。\n(笑)"
    #expect(TranslationPolicy.preparedForTranslation(noisy) == "おはようございます。 今日はいい天気ですね。")
    #expect(TranslationPolicy.preparedForTranslation("[BLANK_AUDIO]\n(音楽)\n(拍手)").isEmpty)
}

@Test func bilingualCoachParsesBothLanguagesAndPreservesCombinedFallback() {
    let raw = """
    [STT_LANG]
    Reply: Could we confirm the launch date by Friday?
    Advice: Ask for the exact owner of the QA checklist.
    [TARGET_LANG]
    Reply: 금요일까지 출시 일정을 확정할 수 있을까요?
    Advice: QA 체크리스트 담당자를 정확히 확인해 보세요.
    """
    let advice = AdvicePolicy.makeAdvice(
        raw: raw,
        sourceLanguageName: "영어",
        targetLanguageName: "한국어",
        sourceSnapshot: nil,
        sourceStart: 0,
        sourceEnd: 20,
        sourceExcerpt: "Let's finalize launch."
    )
    #expect(advice.sourceLanguageName == "영어")
    #expect(advice.targetLanguageName == "한국어")
    #expect(advice.sourceLanguageText?.contains("launch date by Friday") == true)
    #expect(advice.targetLanguageText?.contains("금요일까지 출시 일정") == true)
    #expect(advice.text.contains("[영어]") && advice.text.contains("[한국어]"))

    // Non-bilingual plain output gracefully falls back to single text.
    let plain = AdvicePolicy.makeAdvice(
        raw: "Reply: 네, 확인하겠습니다.",
        sourceLanguageName: "한국어",
        targetLanguageName: "한국어",
        sourceSnapshot: nil,
        sourceStart: nil,
        sourceEnd: nil,
        sourceExcerpt: nil
    )
    #expect(plain.sourceLanguageText == nil)
    #expect(plain.targetLanguageText == nil)
    #expect(plain.text == "Reply: 네, 확인하겠습니다.")
}

@Test func appleContextTokenBudgetTightlyBoundsCJKAndPreservesNewestSpeech() {
    let longJapanese = String(repeating: "明日の会議のスケジュールを確認しましょう。", count: 200) // ~4,000 CJK chars
    let bounded = AdvicePolicy.boundedTail(longJapanese, maxTokens: 1100)
    #expect(bounded.count < 600)
    #expect(AdvicePolicy.estimatedTokens(bounded) <= 1100)
    #expect(longJapanese.hasSuffix(bounded))

    let longEnglish = String(repeating: "Let us review the project schedule tomorrow. ", count: 120) // ~5,400 ASCII chars
    let boundedEn = AdvicePolicy.boundedTail(longEnglish, maxTokens: 1100)
    #expect(boundedEn.count > 2000)
    #expect(AdvicePolicy.estimatedTokens(boundedEn) <= 1100)
    #expect(longEnglish.hasSuffix(boundedEn))

    let head = AdvicePolicy.boundedHead(longJapanese, maxTokens: 200)
    #expect(AdvicePolicy.estimatedTokens(head) <= 200)
    #expect(longJapanese.hasPrefix(head))
}

@Test func summaryLanguagePreferencesSupportSTTTranslationAndMultipleExtraLanguages() throws {
    let suite = "SpikDoum.SummaryLangTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let en = try #require(LanguageCatalog.language(for: "en-US"))
    let ko = try #require(LanguageCatalog.language(for: "ko-KR"))
    let ja = try #require(LanguageCatalog.language(for: "ja-JP"))

    // Default includes both translation (target) and STT languages without duplicates.
    var prefs = SummaryLanguagePreferences()
    #expect(prefs.resolvedLanguages(sttSpec: en, targetSpec: ko).map(\.code) == ["ko-KR", "en-US"])
    #expect(prefs.resolvedLanguages(sttSpec: ko, targetSpec: ko).map(\.code) == ["ko-KR"])

    // Adding extra languages produces multi-language list in order, deduplicated.
    prefs.toggleExtra(ja.code)
    prefs.toggleExtra("zh-CN")
    prefs.toggleExtra(en.code) // already included via STT
    #expect(prefs.resolvedLanguages(sttSpec: en, targetSpec: ko).map(\.code) == ["ko-KR", "en-US", "ja-JP", "zh-CN"])

    // Persistence round-trip.
    prefs.save(defaults: defaults)
    #expect(SummaryLanguagePreferences.load(defaults: defaults) == prefs)

    // Fallback to target language if all toggles/extras are off.
    prefs.includeSTTLanguage = false
    prefs.includeTranslationLanguage = false
    prefs.extraLanguageCodes = []
    #expect(prefs.resolvedLanguages(sttSpec: en, targetSpec: ko).map(\.code) == ["ko-KR"])

    // Language-match verifier catches English drift when Korean or Japanese was requested.
    #expect(!LanguageCatalog.matchesExpectedLanguage("Improving Mac playback and career advice for women.", expected: ko))
    #expect(LanguageCatalog.matchesExpectedLanguage("여성을 위한 커리어 조언과 발표 전략에 대한 핵심 요약입니다.", expected: ko))
    #expect(!LanguageCatalog.matchesExpectedLanguage("Improving Mac playback and career advice.", expected: ja))
    #expect(LanguageCatalog.matchesExpectedLanguage("キャリアアドバイスと重要なポイントの要約です。", expected: ja))
    #expect(LanguageCatalog.matchesExpectedLanguage("Summary of career advice and key action items.", expected: en))
}

@Test func panelVisibilityHidesPersistsAndKeepsAtLeastOneMainPanel() throws {
    let suite = "SpikDoum.PanelVisibilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var layout = PanelLayout()
    layout.setVisible(.coach, false)
    layout.setVisible(.summary, false)
    #expect(!layout.isVisible(.coach))
    #expect(!layout.isVisible(.summary))
    #expect(layout.hasAnySummaryScriptVisible)

    layout.setVisible(.script, false)
    #expect(!layout.hasAnySummaryScriptVisible)
    #expect(layout.visibleSplitPanels(includeSummaryScript: true) == [.stt, .translation])

    layout.setVisible(.stt, false)
    #expect(!layout.isVisible(.stt))
    #expect(!layout.canHide(.translation))
    layout.setVisible(.translation, false)
    #expect(layout.isVisible(.translation))

    layout.save(defaults: defaults)
    let reloaded = PanelLayout.load(defaults: defaults)
    #expect(reloaded.hiddenPanels == layout.hiddenPanels)

    layout.showAllPanels()
    #expect(!layout.hasHiddenPanels)
    #expect(layout.visibleSplitPanels(includeSummaryScript: true) == PanelLayout.defaultOrder)
}

@Test func managedAudioBuffererDropsSamplesWhileMutedAndResumesImmediately() async throws {
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

    // While muted, 2.0s of loud speech should emit zero chunks.
    bufferer.setMuted(true)
    try feed(samples: 16000 * 2, amplitude: 0.25)
    try feed(samples: 16000 * 3 / 10, amplitude: 0)
    try await Task.sleep(for: .milliseconds(80))
    #expect(collector.snapshot().isEmpty)

    // After unmuting, speech emits chunks normally again.
    bufferer.setMuted(false)
    try feed(samples: 16000 * 12 / 10, amplitude: 0.25)
    try feed(samples: 16000 * 3 / 10, amplitude: 0)
    _ = await bufferer.finish()
    #expect(collector.snapshot().count == 1)
}

@Test func speechRecognitionTransientErrorsIncludeXPCAndServerBusy() {
    let xpcInterrupted = NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: nil)
    let xpcInvalidated = NSError(domain: NSCocoaErrorDomain, code: 4099, userInfo: nil)
    let serverBusy = NSError(domain: "kAFAssistantErrorDomain", code: 201, userInfo: nil)
    let lsrTransient = NSError(domain: "kLSRErrorDomain", code: 300, userInfo: nil)
    let siriDisabled = NSError(domain: "kAFAssistantErrorDomain", code: 1700, userInfo: nil)
    let denied = NSError(domain: "kAFAssistantErrorDomain", code: 201, userInfo: [NSLocalizedDescriptionKey: "Speech recognition denied by user"])

    #expect(SpeechRecognitionPolicy.isTransientError(xpcInterrupted))
    #expect(SpeechRecognitionPolicy.isTransientError(xpcInvalidated))
    #expect(SpeechRecognitionPolicy.isTransientError(serverBusy))
    #expect(SpeechRecognitionPolicy.isTransientError(lsrTransient))
    #expect(!SpeechRecognitionPolicy.isTransientError(siriDisabled))
    #expect(!SpeechRecognitionPolicy.isTransientError(denied))
}

@Test func recentSummaryWindowSlicesLiveAndFinishedConversationsAndExportsMarkdown() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var conversation = Conversation(
        date: now.addingTimeInterval(-40 * 60),
        title: "주간 싱크",
        transcript: "35분전발언\n12분전발언\n4분전발언\n90초전발언\n30초전발언"
    )
    conversation.transcriptSpans = [
        TranscriptSpan(date: now.addingTimeInterval(-35 * 60), start: 0, text: "35분전발언\n"),
        TranscriptSpan(date: now.addingTimeInterval(-12 * 60), start: 7, text: "12분전발언\n"),
        TranscriptSpan(date: now.addingTimeInterval(-4 * 60), start: 14, text: "4분전발언\n"),
        TranscriptSpan(date: now.addingTimeInterval(-90), start: 20, text: "90초전발언\n"),
        TranscriptSpan(date: now.addingTimeInterval(-30), start: 27, text: "30초전발언")
    ]

    #expect(RecentSummaryWindow.allCases.map(\.minutes) == [1, 2, 3, 5, 10, 30])

    let live1 = SummaryPolicy.recentTranscript(for: conversation, window: .min1, referenceDate: now, isListening: true)
    #expect(live1.text == "30초전발언")
    #expect(live1.spanCount == 1)
    #expect(!live1.anchoredToLastActivity)

    let live2 = SummaryPolicy.recentTranscript(for: conversation, window: .min2, referenceDate: now, isListening: true)
    #expect(live2.text.contains("90초전발언"))
    #expect(live2.text.contains("30초전발언"))
    #expect(!live2.text.contains("4분전발언"))

    let live5 = SummaryPolicy.recentTranscript(for: conversation, window: .min5, referenceDate: now, isListening: true)
    #expect(live5.text.contains("4분전발언"))
    #expect(!live5.text.contains("12분전발언"))

    let live30 = SummaryPolicy.recentTranscript(for: conversation, window: .min30, referenceDate: now, isListening: true)
    #expect(live30.text.contains("12분전발언"))
    #expect(!live30.text.contains("35분전발언"))

    // Reviewing a finished conversation 2 hours later anchors to its last recorded span.
    let later = now.addingTimeInterval(2 * 3600)
    let finished5 = SummaryPolicy.recentTranscript(for: conversation, window: .min5, referenceDate: later, isListening: false)
    #expect(finished5.anchoredToLastActivity)
    #expect(finished5.text.contains("4분전발언"))
    #expect(!finished5.text.contains("12분전발언"))

    // Saved recent-window summaries are exported cleanly to Markdown.
    conversation.summaries = [
        RecentSummaryWindow.min5.summaryKey: SummaryState(text: "• 최근 5분 핵심 정리", coveredSource: live5.text, updatedAt: now)
    ]
    let md = ConversationExport.markdown(for: conversation)
    #expect(md.contains("## 구간별 요약"))
    #expect(md.contains("### 최근 5분"))
    #expect(md.contains("• 최근 5분 핵심 정리"))
}

@Test func presentationNotesParserSplitsHeadingsDurationsAndNativeNotes() {
    let md = """
    # 오프닝 [2분]
    - Welcome everyone to today's talk.
    - Let's review Q3 goals.
    > 미소 유지, 천천히 시작

    ## 라이브 데모 (4.5m)
    - Switching to live screen now.
    > 화면 공유 상태 확인

    # 마무리 [90s]
    - Thank you! Any questions?
    """

    let cards = PresentationNotesParser.parse(md)
    #expect(cards.count == 3)
    #expect(cards[0].title == "오프닝")
    #expect(cards[0].plannedMinutes == 2.0)
    #expect(cards[0].bodyLines.count == 2)
    #expect(cards[0].subNotes == ["미소 유지, 천천히 시작"])

    #expect(cards[1].title == "라이브 데모")
    #expect(cards[1].plannedMinutes == 4.5)
    #expect(cards[1].subNotes == ["화면 공유 상태 확인"])

    #expect(cards[2].title == "마무리")
    #expect(cards[2].plannedMinutes == 1.5)
}

@Test func presentationChecklistMatcherHandlesAliasesAndRespectsManualOverride() {
    var items = [
        PresentationChecklistItem(title: "35% 비용 절감 / 35% / thirty-five percent"),
        PresentationChecklistItem(title: "보안 인증, SOC2"),
        PresentationChecklistItem(title: "Q4 로드맵", isChecked: false, autoMatched: false, manuallyOverridden: true)
    ]

    let result = PresentationChecklistMatcher.apply(
        transcript: "We achieved thirty five percent reduction and completed SOC 2 and Q4 로드맵.",
        to: items
    )
    #expect(result.changed)
    items = result.items
    #expect(items[0].isChecked && items[0].autoMatched)
    #expect(items[1].isChecked && items[1].autoMatched)
    // Manually overridden item must not be auto-checked back.
    #expect(!items[2].isChecked)

    // Cloning a presentation resets elapsed time and checklist completion while preserving content.
    var session = PresentationSession(
        targetMinutes: 20,
        notesMarkdown: "# Intro [2분]\n- Hello",
        activeCardIndex: 2,
        checklist: items,
        elapsedSeconds: 420,
        inQAMode: true
    )
    let cloned = session.clonedForNewRun()
    #expect(cloned.targetMinutes == 20)
    #expect(cloned.notesMarkdown == session.notesMarkdown)
    #expect(cloned.activeCardIndex == 0)
    #expect(cloned.elapsedSeconds == 0)
    #expect(!cloned.inQAMode)
    #expect(cloned.checklist.count == 3)
    #expect(cloned.checklist.allSatisfy { !$0.isChecked && !$0.manuallyOverridden })
    session.checklist = items
    var convo = Conversation(title: "발표", transcript: "test")
    convo.presentation = session
    let md = ConversationExport.markdown(for: convo)
    #expect(md.contains("## 프레젠테이션 요약"))
    #expect(md.contains("필수 언급 체크리스트: 2/3 완료"))
}

@Test func speakingPaceCalculatorMeasuresEnglishWPMAndKoreanCPM() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let enSpans = [
        TranscriptSpan(date: now.addingTimeInterval(-17), start: 0, text: "[마이크] Today I want to share three important milestones from our engineering team this quarter."),
        TranscriptSpan(date: now.addingTimeInterval(-5), start: 95, text: "[마이크] First we reduced end to end latency dramatically across all regions."),
        TranscriptSpan(date: now.addingTimeInterval(-3), start: 170, text: "[Mac 재생음] This audience speech should be ignored for presenter pace.")
    ]
    let enPace = SpeakingPaceCalculator.calculate(spans: enSpans, referenceDate: now)
    #expect(enPace.unitLabel == "WPM")
    #expect(enPace.rate > 40 && enPace.rate < 220)
    #expect(enPace.zone != .idle)

    let koSpans = [
        TranscriptSpan(date: now.addingTimeInterval(-15), start: 0, text: "안녕하세요 오늘 발표에서는 지난 분기 핵심 성과와 다음 분기 계획을 공유드리겠습니다. 특히 실시간 지연 시간을 크게 단축했습니다.")
    ]
    let koPace = SpeakingPaceCalculator.calculate(spans: koSpans, referenceDate: now)
    #expect(koPace.unitLabel == "자/분")
    #expect(koPace.rate > 100)
}

@Test func speedQualityTierResolvesFiveStagesForSTTAndTranslation() {
    let installedAll: Set<String> = [
        "whisper-tiny", "whisper-base", "whisper-small",
        "whisper-large-v3-turbo-q5", "whisper-large-v3-q5",
        "qwen25-05b-q4", "qwen25-15b-q4", "qwen3-4b-q4"
    ]

    // Tier 1 (Ultra Fast): English + Parakeet ready picks Parakeet ANE; Japanese picks Apple modern streaming; Translation picks Apple.
    let enTier1 = SpeedQualityTier.ultraFast.resolveSTTPlan(languageCode: "en-US", installedWhisperIDs: installedAll, parakeetReady: true, appleModernReady: true)
    #expect(enTier1.engine == .parakeet)
    let jaTier1 = SpeedQualityTier.ultraFast.resolveSTTPlan(languageCode: "ja-JP", installedWhisperIDs: installedAll, parakeetReady: true, appleModernReady: true)
    #expect(jaTier1.engine == .apple)
    #expect(SpeedQualityTier.ultraFast.resolveTranslationPlan(installedTranslationIDs: installedAll).engine == .apple)

    // Tiers 2..5 progress from fast streaming to max accuracy batch with tighter/wider audio context.
    let koTier2 = SpeedQualityTier.fast.resolveSTTPlan(languageCode: "ko-KR", installedWhisperIDs: installedAll, parakeetReady: true, appleModernReady: false)
    #expect(koTier2.engine == .managed && koTier2.managedModelID == "whisper-base")
    #expect(koTier2.streamingInterval == 0.35 && koTier2.audioContext == 384)
    #expect(SpeedQualityTier.fast.resolveTranslationPlan(installedTranslationIDs: installedAll).managedModelID == "qwen25-05b-q4")

    let tier3 = SpeedQualityTier.balanced.resolveSTTPlan(languageCode: "ko-KR", installedWhisperIDs: installedAll, parakeetReady: false, appleModernReady: false)
    #expect(tier3.managedModelID == "whisper-small" && tier3.streamingInterval == 0.45)
    #expect(SpeedQualityTier.balanced.resolveTranslationPlan(installedTranslationIDs: installedAll).managedModelID == "qwen25-15b-q4")

    let tier4 = SpeedQualityTier.accurate.resolveSTTPlan(languageCode: "ko-KR", installedWhisperIDs: installedAll, parakeetReady: false, appleModernReady: false)
    #expect(tier4.managedModelID == "whisper-large-v3-turbo-q5" && tier4.streamingInterval == 0.55 && tier4.audioContext == 512)
    #expect(SpeedQualityTier.accurate.resolveTranslationPlan(installedTranslationIDs: installedAll).managedModelID == "qwen3-4b-q4")

    let tier5 = SpeedQualityTier.maxAccuracy.resolveSTTPlan(languageCode: "ja-JP", installedWhisperIDs: installedAll, parakeetReady: false, appleModernReady: false)
    #expect(tier5.managedModelID == "whisper-large-v3-q5" && tier5.streamingInterval == nil && tier5.audioContext == 768 && tier5.bestOf == 2)

    let whisperArgs = ManagedModelManager.arguments(role: .stt, model: URL(fileURLWithPath: "/tmp/m.bin"), audioContext: 384, bestOf: 1)
    #expect(whisperArgs.contains("-ac") && whisperArgs.contains("384"))
}

@Test func localAgreementStabilizesStreamingInterimAndPCM16ConvertsCleanly() {
    var tracker = LocalAgreementTracker()
    let h1 = tracker.update(hypothesis: "Hello everyone today we")
    #expect(h1 == "Hello everyone today we")
    let h2 = tracker.update(hypothesis: "Hello everyone today we will discuss latency")
    #expect(tracker.confirmedPrefix == "Hello everyone today we")
    #expect(h2 == "Hello everyone today we will discuss latency")
    // Transient truncation shorter than agreed prefix keeps the confirmed prefix steady.
    let h3 = tracker.update(hypothesis: "Hello")
    #expect(h3 == "Hello everyone today we")
    tracker.reset()
    #expect(tracker.confirmedPrefix.isEmpty)

    // PCM16 little-endian to Float32 conversion for Parakeet ANE.
    var samples: [Int16] = ([0, 16384, -16384] as [Int16]).map { $0.littleEndian }
    let data = Data(bytes: &samples, count: samples.count * 2)
    let floats = ParakeetModelManager.pcm16ToFloats(data)
    #expect(floats.count == 3)
    #expect(abs(floats[0]) < 0.0001)
    #expect(abs(floats[1] - 0.5) < 0.001)
    #expect(abs(floats[2] + 0.5) < 0.001)
}

@Test func presentationAdvisorRecommendsByDurationContentAndLiveContext() {
    #expect(SignpostCategory.allCases.count == 8)
    #expect(PresentationDurationProfile.profile(for: 5).tier == .lightning)
    #expect(PresentationDurationProfile.profile(for: 15).tier == .standard)
    #expect(PresentationDurationProfile.profile(for: 30).tier == .deepDive)

    var session = PresentationSession(
        targetMinutes: 15,
        notesMarkdown: """
        # 오프닝 훅 [2분]
        - Did you know latency costs 35% of user drop-off?

        # 라이브 데모 [6분]
        - Let me switch to a live demo of Q3 rollout.

        # 성과 데이터 [5분]
        - Look at the chart showing 3x speed improvement.
        """
    )

    let instant = PresentationAdvisor.instantRecommend(session: session, languageCode: "en-US")
    #expect(instant.checklist.contains { $0.title.contains("35%") })
    #expect(instant.checklist.contains { $0.title.contains("Q3") })
    #expect(instant.phrases.contains { $0.category == .demo || $0.category == .visuals })

    let cards = PresentationNotesParser.parse(session.notesMarkdown)
    // Active card = Demo → surfaces Demo & Glitch Recovery phrases.
    let demoCtx = PresentationAdvisor.contextualLiveRecommendation(session: session, cards: cards, activeCardIndex: 1, languageCode: "en-US")
    #expect(demoCtx.category == .demo)
    #expect(!demoCtx.phrases.isEmpty)

    // Active card = Data/Chart → surfaces Visuals & Data phrases.
    let chartCtx = PresentationAdvisor.contextualLiveRecommendation(session: session, cards: cards, activeCardIndex: 2, languageCode: "en-US")
    #expect(chartCtx.category == .visuals)

    // Approaching end of talk (85% elapsed) → overrides with Time Control / Closing phrases.
    session.elapsedSeconds = 13 * 60
    let closingCtx = PresentationAdvisor.contextualLiveRecommendation(session: session, cards: cards, activeCardIndex: 1, languageCode: "en-US")
    #expect(closingCtx.category == .timeControl)

    // AI JSON recommendation parsing (including fenced JSON).
    let aiJSON = """
    ```json
    {
      "rationale": "15분 발표에 맞춰 수치·데모·마무리 3축으로 구성했습니다.",
      "checklist": [
        {"title": "35% 지연 단축 / 35% / thirty-five", "stage": "핵심 수치", "minute": 4}
      ],
      "phrases": [
        {"category": "visuals", "phrase": "Look at the sharp 35% drop on the right.", "meaning": "35% 감소 차트 시선 유도"}
      ]
    }
    ```
    """
    let parsed = PresentationAdvisor.parseAIRecommendationJSON(aiJSON, languageCode: "en-US", rationaleFallback: "")
    #expect(parsed != nil)
    #expect(parsed?.isAIGenerated == true)
    #expect(parsed?.checklist.first?.stageTag == "핵심 수치")
    #expect(parsed?.checklist.first?.targetMinute == 4)
    #expect(parsed?.phrases.first?.category == .visuals)
}

@Test func enhancedMultilingualAutoDetectionHandlesShortCJKCodeSwitchingCandidatesAndWhisperNames() {
    // 1. Short non-Latin utterances & code-switched phrases are detected reliably via script-first heuristics.
    #expect(LanguageCatalog.detectLanguage(for: "감사")?.code == "ko-KR")
    #expect(LanguageCatalog.detectLanguage(for: "はい")?.code == "ja-JP")
    #expect(LanguageCatalog.detectLanguage(for: "API 에러 확인해 주세요")?.code == "ko-KR")
    #expect(LanguageCatalog.detectLanguage(for: "Q3 レビュー 시작")?.code == "ja-JP")
    #expect(LanguageCatalog.detectLanguage(for: "สวัสดีครับ")?.code == "th-TH")
    #expect(LanguageCatalog.detectLanguage(for: "مرحبا بكم")?.code == "ar-SA")
    #expect(LanguageCatalog.detectLanguage(for: "नमस्ते")?.code == "hi-IN")

    // 2. Pure Kanji disambiguates to Japanese when preferred candidates include Japanese without Chinese.
    let kanjiForJA = LanguageCatalog.detectLanguageDetailed(for: "会議資料", preferredCodes: ["ko-KR", "ja-JP"])
    #expect(kanjiForJA?.language.code == "ja-JP")

    // 3. Whisper acoustic verbose_json language names map cleanly to SupportedLanguage.
    #expect(LanguageCatalog.language(forWhisperName: "japanese")?.code == "ja-JP")
    #expect(LanguageCatalog.language(forWhisperName: "korean")?.code == "ko-KR")
    #expect(LanguageCatalog.language(forWhisperName: "chinese")?.code == "zh-CN")
    #expect(LanguageCatalog.language(forWhisperName: "thai")?.code == "th-TH")

    // 4. Parakeet ANE auto mode is enabled only when candidate languages are all European.
    #expect(SpeedQualityTier.supportsParakeet(languageCode: "auto", preferredAutoCodes: ["en-US", "de-DE", "fr-FR"]))
    #expect(!SpeedQualityTier.supportsParakeet(languageCode: "auto", preferredAutoCodes: ["en-US", "ko-KR"]))
    #expect(!SpeedQualityTier.supportsParakeet(languageCode: "auto", preferredAutoCodes: []))
}

@Test func pptxImporterParsesDrawingMLSlidesNotesRelsAndFormatsCueCards() {
    let slideXML = Data("""
    <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <p:cSld><p:spTree>
        <p:sp><p:txBody>
          <a:p><a:r><a:t>Q3 Performance Review</a:t></a:r></a:p>
          <a:p><a:r><a:t>Latency reduced by 35%</a:t></a:r></a:p>
          <a:p><a:r><a:t>1</a:t></a:r></a:p>
        </p:txBody></p:sp>
      </p:spTree></p:cSld>
    </p:sld>
    """.utf8)
    let paragraphs = PPTXSlideImporter.parseDrawingMLParagraphs(slideXML)
    #expect(paragraphs == ["Q3 Performance Review", "Latency reduced by 35%", "1"])

    let relsXML = Data("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide4.xml"/>
    </Relationships>
    """.utf8)
    #expect(PPTXSlideImporter.parseNotesTarget(fromRels: relsXML) == "ppt/notesSlides/notesSlide4.xml")

    let slides = [
        ImportedPPTSlide(
            number: 1,
            title: "Q3 Performance Review",
            bullets: ["Latency reduced by 35%", "Zero downtime"],
            speakerNotes: ["Start with the latency hook and pause 2 seconds."]
        ),
        ImportedPPTSlide(
            number: 2,
            title: "Live Demo",
            bullets: ["Walk through real-time translation"],
            speakerNotes: []
        )
    ]
    let markdown = PPTXSlideImporter.formatAsCueCardMarkdown(slides: slides, totalMinutes: 10)
    #expect(markdown.contains("# 1. Q3 Performance Review [5분]"))
    #expect(markdown.contains("- Start with the latency hook and pause 2 seconds."))
    #expect(markdown.contains("> 슬라이드 화면: Latency reduced by 35% · Zero downtime"))
    let cards = PresentationNotesParser.parse(markdown)
    #expect(cards.count == 2)
    #expect(cards[0].plannedMinutes == 5.0)
    #expect(cards[1].title == "2. Live Demo")
}

@MainActor @Test func sttLowLatencyOptimizationsProtectTurboContextUseFastJSONAndIsolateLiveCaption() {
    // 1. Default ManagedSTTClient request uses compact "json" (skips slow token timestamp alignment).
    let wave = ManagedSTTClient.wave(pcm: Data([1, 0, 2, 0]))
    let fastReq = ManagedSTTClient(key: "k").request(wave: wave, language: "auto")
    let fastBody = String(decoding: fastReq.httpBody!, as: UTF8.self)
    #expect(fastBody.contains("name=\"response_format\"\r\n\r\njson"))
    #expect(!fastBody.contains("verbose_json"))

    // 2. Large-v3 / turbo models clamp -ac >= 512 so positional embeddings cannot corrupt; smaller models keep 384.
    let turboArgs = ManagedModelManager.arguments(
        role: .stt,
        model: URL(fileURLWithPath: "/tmp/ggml-large-v3-turbo-q5_0.bin"),
        audioContext: 384,
        bestOf: 1
    )
    if let acIdx = turboArgs.firstIndex(of: "-ac"), acIdx + 1 < turboArgs.count {
        #expect(turboArgs[acIdx + 1] == "512")
    } else {
        Issue.record("Missing -ac flag for turbo model")
    }
    let smallArgs = ManagedModelManager.arguments(
        role: .stt,
        model: URL(fileURLWithPath: "/tmp/ggml-small.bin"),
        audioContext: 384,
        bestOf: 1
    )
    if let acIdx = smallArgs.firstIndex(of: "-ac"), acIdx + 1 < smallArgs.count {
        #expect(smallArgs[acIdx + 1] == "384")
    } else {
        Issue.record("Missing -ac flag for small model")
    }

    // 3. Tier 1 (Ultra Fast) in multilingual "auto" mode picks ultra-fast Whisper instead of fixed-locale Apple STT.
    let autoTier1 = SpeedQualityTier.ultraFast.resolveSTTPlan(
        languageCode: "auto",
        installedWhisperIDs: ["whisper-tiny", "whisper-base"],
        parakeetReady: true,
        appleModernReady: true
    )
    #expect(autoTier1.engine == .managed && autoTier1.managedModelID == "whisper-tiny")

    // 4. LiveSTTDisplayStore isolates partial updates per source and clears cleanly.
    let live = LiveSTTDisplayStore()
    live.update(text: "Hello world", sourceTag: "Mac 재생음")
    #expect(live.text == "Hello world" && live.sourceTag == "Mac 재생음")
    live.update(text: "네 알겠습니다", sourceTag: "마이크")
    #expect(live.text == "네 알겠습니다" && live.sourceTag == "마이크")
    live.clear(sourceTag: "마이크")
    #expect(live.text == "Hello world" && live.sourceTag == "Mac 재생음")
    live.clear()
    #expect(live.text.isEmpty && live.sourceTag == nil)

    // 5. RecentActivity append fast-path matches incremental span growth.
    let t0 = Date()
    let s1 = RecentActivity.update(old: "", new: "First sentence.", spans: [], at: t0)
    let s2 = RecentActivity.update(old: "First sentence.", new: "First sentence. Second sentence.", spans: s1, at: t0.addingTimeInterval(2))
    #expect(s2.count == 1 && s2[0].text == "First sentence. Second sentence.")
    let s3 = RecentActivity.update(old: s2[0].text, new: s2[0].text + " Later.", spans: s2, at: t0.addingTimeInterval(15))
    #expect(s3.count == 2 && s3[1].start == s2[0].end && s3[1].text == " Later.")
}

@MainActor @Test func managedLocalLLMAndTaskRoutingConfigureDedicatedServerAndOverrides() throws {
    // 1. Dedicated managed LLM server uses port 18884, 8K context, 2 parallel slots, reasoning off, and loopback binding.
    #expect(ManagedRole.llm.port == 18884)
    #expect(ManagedRole.llm.executable == "llama-server")
    let llmArgs = ManagedModelManager.arguments(role: .llm, model: URL(fileURLWithPath: "/tmp/Qwen3-4B-Q4_K_M.gguf"))
    #expect(llmArgs.contains("127.0.0.1"))
    #expect(llmArgs.contains("18884"))
    #expect(llmArgs.contains("8192"))
    #expect(llmArgs.contains("--parallel"))
    if let pIdx = llmArgs.firstIndex(of: "--parallel"), pIdx + 1 < llmArgs.count {
        #expect(llmArgs[pIdx + 1] == "2")
    } else {
        Issue.record("Missing --parallel flag for managed LLM")
    }
    #expect(llmArgs.contains("--reasoning") && llmArgs.contains("off"))

    // 2. Per-task LLM routing defaults to main LLM and supports independent keyword/summary overrides.
    var settings = EngineSettings()
    settings.llm = .managed
    #expect(settings.effectiveLLM(for: .coach) == .managed)
    #expect(settings.effectiveLLM(for: .summary) == .managed)
    #expect(settings.effectiveLLM(for: .keywords) == .managed)
    #expect(!settings.usesAppleLLMForAnyTask)

    settings.keywordLLM = .apple
    settings.summaryLLM = .openAI
    #expect(settings.effectiveLLM(for: .coach) == .managed)
    #expect(settings.effectiveLLM(for: .keywords) == .apple)
    #expect(settings.effectiveLLM(for: .summary) == .openAI)
    #expect(settings.usesAppleLLMForAnyTask)

    // 3. Legacy EngineSettings JSON without keywordLLM/summaryLLM decodes cleanly to .followMain.
    let legacyJSON = Data("{\"stt\":\"apple\",\"translation\":\"apple\",\"llm\":\"managed\"}".utf8)
    let decoded = try JSONDecoder().decode(EngineSettings.self, from: legacyJSON)
    #expect(decoded.llm == .managed)
    #expect(decoded.keywordLLM == .followMain)
    #expect(decoded.summaryLLM == .followMain)

    // 4. LLMClient respects engineOverride when a task uses a different provider than settings.llm.
    settings.cloudModel = "gpt-4.1-mini"
    let openAIReq = try LLMClient(settings: settings, key: "sk-test", engineOverride: .openAI)
        .request(instructions: "Summarize", input: "Hello")
    #expect(openAIReq.url?.host == "api.openai.com")
    let localReq = try LLMClient(settings: settings, key: "", engineOverride: .compatible)
        .request(instructions: "Summarize", input: "Hello")
    #expect(localReq.url?.host == "localhost")
}

@Test func powerPointRemoteParsesSlideSnapshotsAndBuildsValidControlScripts() {
    // 1. Parse full PowerPoint slide show snapshot with deck name and blackout state.
    let running = PPTSlideSyncMonitor.parseSnapshot("PowerPoint|4|15|1|black|Q3_Roadmap.pptx")
    #expect(running == PPTSlideSnapshot(
        appName: "PowerPoint",
        presentationName: "Q3_Roadmap.pptx",
        currentSlide: 4,
        totalSlides: 15,
        isSlideShowRunning: true,
        screenMode: .black
    ))

    // 2. Parse edit-mode PowerPoint snapshot and Keynote snapshot.
    let editMode = PPTSlideSyncMonitor.parseSnapshot("PowerPoint|2|10|0|normal|Demo | Deck.pptx")
    #expect(editMode?.currentSlide == 2 && editMode?.totalSlides == 10 && editMode?.isSlideShowRunning == false && editMode?.presentationName == "Demo | Deck.pptx")
    let keynote = PPTSlideSyncMonitor.parseSnapshot("Keynote|7|20|1|normal|Launch.key")
    #expect(keynote?.appName == "Keynote" && keynote?.currentSlide == 7 && keynote?.isSlideShowRunning == true)

    // 3. Reject empty or malformed snapshots safely.
    #expect(PPTSlideSyncMonitor.parseSnapshot("") == nil)
    #expect(PPTSlideSyncMonitor.parseSnapshot("PowerPoint|0|10|0|normal|bad") == nil)
    #expect(PPTSlideSyncMonitor.parseSnapshot("invalid") == nil)

    // 4. Verify path parsing, live notes extraction, merging, and explicit timing preservation.
    let withPath = PPTSlideSyncMonitor.parseSnapshot("PowerPoint|3|22|1|normal|Demo | Deck.pptx\t/Users/me/Demo | Deck.pptx")
    #expect(withPath?.presentationName == "Demo | Deck.pptx")
    #expect(withPath?.presentationPath == "/Users/me/Demo | Deck.pptx")
    #expect(withPath?.currentSlide == 3 && withPath?.totalSlides == 22 && withPath?.isSlideShowRunning == true)

    let notesScriptPPT = PPTSlideSyncMonitor.buildNotesExportScript(for: .powerPoint)
    #expect(notesScriptPPT.contains("notes page of sl"))
    #expect(notesScriptPPT.contains("<<<SPIK_SLIDE>>>"))
    let notesScriptKeynote = PPTSlideSyncMonitor.buildNotesExportScript(for: .keynote)
    #expect(notesScriptKeynote.contains("presenter notes of sl"))

    // 5. Parse live PowerPoint CR-delimited notes, merge onto disk PPTX titles/bullets, and keep >6 lines + explicit timing.
    let liveRaw = "<<<SPIK_SLIDE>>>1<<<SPIK_FIELD>>><<<SPIK_FIELD>>>예상 배분 시간: 0:45 (누적 0:45)\r라인1\r라인2\r라인3\r라인4\r라인5\r라인6\r라인7\r1<<<SPIK_SLIDE>>>2<<<SPIK_FIELD>>>Custom Live Title<<<SPIK_FIELD>>>Live edited note"
    let parsedLive = PPTSlideSyncMonitor.parseLiveSlides(liveRaw)
    #expect(parsedLive.count == 2)
    #expect(parsedLive[0].title == "슬라이드 1")
    #expect(parsedLive[0].speakerNotes.count == 8) // standalone "1" filtered out, all 8 lines preserved
    #expect(parsedLive[1].title == "Custom Live Title")

    let diskBase = [
        ImportedPPTSlide(number: 1, title: "온톨로지 재무 AI", bullets: ["핵심 아키텍처", "성과 요약"], speakerNotes: ["Old saved note"])
    ]
    let merged = PPTSlideSyncMonitor.mergeLiveNotes(baseSlides: diskBase, liveSlides: parsedLive)
    #expect(merged.count == 2)
    #expect(merged[0].title == "온톨로지 재무 AI")
    #expect(merged[0].bullets == ["핵심 아키텍처", "성과 요약"])
    #expect(merged[0].speakerNotes.contains("라인7"))
    let mergedMD = PPTXSlideImporter.formatAsCueCardMarkdown(slides: merged, totalMinutes: 20)
    #expect(mergedMD.contains("# 1. 온톨로지 재무 AI [0:45]"))
    #expect(mergedMD.contains("- 라인7")) // no longer truncated at 6 lines!
    let mergedCards = PresentationNotesParser.parse(mergedMD)
    #expect(mergedCards.count == 2)
    #expect(mergedCards[0].plannedSeconds == 45)

    // 6. Verify generated AppleScript commands cover all presentation remote actions.
    let startWindowed = PPTSlideSyncMonitor.buildControlScript(for: .startShowFromBeginning(.windowed))
    #expect(startWindowed.contains("run slide show"))
    #expect(startWindowed.contains("slide show type window"))
    #expect(startWindowed.contains("set ending slide of sss to totalCnt"))
    #expect(startWindowed.contains("slide show range show all"))

    let startFullFromCurrent = PPTSlideSyncMonitor.buildControlScript(for: .startShowFromCurrent(.fullScreen))
    #expect(startFullFromCurrent.contains("slide show type speaker"))
    #expect(startFullFromCurrent.contains("set ending slide of sss to totalCnt"))
    #expect(startFullFromCurrent.contains("go to next slide ssv"))

    let nextScript = PPTSlideSyncMonitor.buildControlScript(for: .nextSlide)
    #expect(nextScript.contains("go to next slide"))
    #expect(nextScript.contains("go to slide (view of active window)"))

    let prevScript = PPTSlideSyncMonitor.buildControlScript(for: .previousSlide)
    #expect(prevScript.contains("go to previous slide"))

    let jumpScript = PPTSlideSyncMonitor.buildControlScript(for: .goToSlide(5))
    #expect(jumpScript.contains("set targetIdx to 5"))

    let blackScript = PPTSlideSyncMonitor.buildControlScript(for: .toggleBlackScreen)
    #expect(blackScript.contains("slide show state black screen"))

    let whiteScript = PPTSlideSyncMonitor.buildControlScript(for: .toggleWhiteScreen)
    #expect(whiteScript.contains("slide show state white screen"))

    let endScript = PPTSlideSyncMonitor.buildControlScript(for: .endShow)
    #expect(endScript.contains("exit slide show"))
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SPIKDOUM_PPT_E2E"] == "1"))
func powerPointLiveEndToEndSlideShowControl() async throws {
    let monitor = PPTSlideSyncMonitor()
    func runAction(_ action: PPTControlAction) async throws {
        monitor.perform(action)
        for _ in 0..<120 {
            if !monitor.isSendingCommand { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(monitor.lastControlError == nil, "Action \(action) failed: \(monitor.lastControlError ?? "")")
    }

    // 1. Fetch live presenter notes from the currently open PowerPoint deck
    let notesOutcome = await PPTSlideSyncMonitor.fetchActivePresentationSlides()
    switch notesOutcome {
    case .success(let fetched):
        #expect(!fetched.slides.isEmpty)
        #expect(fetched.slides.contains { !$0.speakerNotes.isEmpty })
    case .failure(let error):
        Issue.record("Live PowerPoint notes fetch failed: \(error.localizedDescription)")
    }

    // 2. Start windowed slide show from beginning
    try await runAction(.startShowFromBeginning(.windowed))
    #expect(monitor.connectedApp == "PowerPoint")
    #expect(monitor.isSlideShowRunning == true)
    #expect(monitor.currentSlideNumber == 1)

    // 2. Next slide, jump to slide 5, previous slide
    try await runAction(.nextSlide)
    #expect(monitor.currentSlideNumber == 2)
    try await runAction(.goToSlide(5))
    #expect(monitor.currentSlideNumber == 5)
    try await runAction(.previousSlide)
    #expect(monitor.currentSlideNumber == 4)

    // 3. Black screen & white screen toggles
    try await runAction(.toggleBlackScreen)
    #expect(monitor.screenMode == .black)
    try await runAction(.toggleWhiteScreen)
    #expect(monitor.screenMode == .white)
    try await runAction(.toggleWhiteScreen)
    #expect(monitor.screenMode == .normal)

    // 4. End show, move to slide 3 in edit mode, then start from current slide (#3)
    try await runAction(.endShow)
    #expect(monitor.isSlideShowRunning == false)
    try await runAction(.goToSlide(3))
    #expect(monitor.currentSlideNumber == 3)
    try await runAction(.startShowFromCurrent(.windowed))
    #expect(monitor.isSlideShowRunning == true)
    #expect(monitor.currentSlideNumber == 3)

    // 5. Step back to slide 2 (proving full range is preserved!), end show, restore slide 1
    try await runAction(.previousSlide)
    #expect(monitor.currentSlideNumber == 2)
    try await runAction(.endShow)
    #expect(monitor.isSlideShowRunning == false)
    try await runAction(.firstSlide)
    #expect(monitor.currentSlideNumber == 1)
}

@Test func presentationQuestionPostItCapturesAudioClipsDetectsQuestionsAndPersists() throws {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SpikDoum-QNoteTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let convoID = UUID()

    // 1. Feed 2 seconds of 440Hz sine wave at 24kHz into QuestionAudioClipRecorder rolling ring buffer.
    let recorder = QuestionAudioClipRecorder()
    let sampleRate = 24000
    let twoSeconds = (0..<(sampleRate * 2)).map { idx in
        Float(sin(2.0 * Double.pi * 440.0 * Double(idx) / Double(sampleRate)) * 0.25)
    }
    let now = Date()
    recorder.appendMonoSamples(Array(twoSeconds.prefix(sampleRate)), at: now.addingTimeInterval(-1.0))
    recorder.appendMonoSamples(Array(twoSeconds.suffix(sampleRate)), at: now)

    // 2. Retroactively export standalone `.m4a` clip from the rolling ring buffer and verify AVAudioFile readability.
    let retroClip = recorder.exportRecentClip(
        conversationID: convoID,
        recordingsRoot: tempRoot,
        from: now.addingTimeInterval(-2.0),
        to: now,
        fallbackSeconds: 5.0,
        sourceSummary: "Meet 청중"
    )
    #expect(retroClip != nil)
    if let retroClip {
        #expect(retroClip.filename.hasPrefix("question-"))
        #expect(retroClip.filename.hasSuffix(".m4a"))
        #expect(retroClip.duration >= 1.5)
        let url = RecordingStorage.clipURL(conversationID: convoID, filename: retroClip.filename, root: tempRoot)
        let readable = try AVAudioFile(forReading: url)
        #expect(readable.length > 0)
        // Verify full-EOF `.m4a` -> 16kHz mono PCM16 decode for automatic question STT (Whisper / Parakeet).
        let decodedPCM = try QuestionAudioTranscriber.decodeTo16kMonoPCM16(url: url)
        #expect(decodedPCM.count >= 16000 * 2) // at least 1s of 16kHz Int16 PCM
    }

    // Verify two-way automatic question translation target selection (EN -> KO, KO -> EN).
    let koLang = LanguageCatalog.language(for: "ko-KR")!
    let enLang = LanguageCatalog.language(for: "en-US")!
    #expect(QuestionTranslationLanguageResolver.targetLanguage(for: "How do you validate SQL outputs?", userTarget: koLang, presentationLanguage: enLang)?.code == "ko-KR")
    #expect(QuestionTranslationLanguageResolver.targetLanguage(for: "지연 시간은 얼마나 줄었나요?", userTarget: koLang, presentationLanguage: enLang)?.code == "en-US")

    // 3. Dedicated manual recording with pre-roll exports a separate standalone `.m4a` clip.
    try recorder.startManualRecording(preRollSeconds: 1.0, useStandaloneMic: false)
    recorder.appendMonoSamples(Array(twoSeconds.prefix(sampleRate)), at: now.addingTimeInterval(1.0))
    let manualClip = recorder.stopManualRecordingAndExport(
        conversationID: convoID,
        recordingsRoot: tempRoot,
        sourceSummary: "마이크"
    )
    #expect(manualClip != nil)
    #expect(manualClip?.id != retroClip?.id)
    #expect((manualClip?.duration ?? 0) >= 1.5)

    // 4. Question detection heuristic handles Google Meet remote audio, `?`, and Q&A interrogatives accurately.
    #expect(QuestionAudioClipRecorder.isLikelyQuestion("[Mac 재생음] How do you handle ontology hallucinations in production?", sourceTag: "Mac 재생음", inQAMode: false) == true)
    #expect(QuestionAudioClipRecorder.isLikelyQuestion("Could you share the latency numbers?", sourceTag: "마이크", inQAMode: false) == true)
    #expect(QuestionAudioClipRecorder.isLikelyQuestion("보안 감사는 어떻게 대응하셨나요", sourceTag: "마이크", inQAMode: true) == true)
    #expect(QuestionAudioClipRecorder.isLikelyQuestion("Thank you all for joining today.", sourceTag: "마이크", inQAMode: false) == false)

    // 5. PresentationQuestionNote Codable round-trip (including AI recommended answer) & answer parser.
    let parsedBilingual = QuestionAnswerParser.parse("""
    [ANSWER_SPEAK]
    We enforce strict schema guardrails before executing any generated query.
    [ANSWER_LOCAL]
    생성된 쿼리를 실행하기 전에 엄격한 스키마 가드레일을 적용합니다.
    - 핵심 포인트: 정확도 검증 수치를 함께 언급하세요.
    """)
    #expect(parsedBilingual.speak == "We enforce strict schema guardrails before executing any generated query.")
    #expect(parsedBilingual.local?.contains("스키마 가드레일") == true)
    let parsedPlain = QuestionAnswerParser.parse("간결하게 핵심 구조부터 설명하면 좋습니다.")
    #expect(parsedPlain.speak == "간결하게 핵심 구조부터 설명하면 좋습니다.")
    #expect(parsedPlain.local == nil)

    var session = PresentationSession()
    session.questionNotes = [
        PresentationQuestionNote(
            slideNumber: 4,
            slideTitle: "Ontology Architecture",
            sourceLabel: "Meet 청중",
            questionText: "How do you validate SQL outputs?",
            translatedText: "SQL 출력은 어떻게 검증하시나요?",
            recommendedAnswer: parsedBilingual.speak,
            recommendedAnswerLocal: parsedBilingual.local,
            recommendedAnswerAt: Date(),
            answerMemo: "Schema guardrails + deterministic test suite",
            color: .sky,
            isResolved: false,
            isPinned: true,
            autoCaptured: true,
            audioClip: retroClip
        )
    ]
    let encoded = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(PresentationSession.self, from: encoded)
    #expect(decoded.resolvedQuestionNotes.count == 1)
    #expect(decoded.resolvedQuestionNotes[0].slideNumber == 4)
    #expect(decoded.resolvedQuestionNotes[0].recommendedAnswer == parsedBilingual.speak)
    #expect(decoded.resolvedQuestionNotes[0].recommendedAnswerLocal == parsedBilingual.local)
    #expect(decoded.resolvedQuestionNotes[0].audioClip?.filename == retroClip?.filename)
    #expect(decoded.clonedForNewRun().resolvedQuestionNotes.isEmpty)
}

@Test func sidebarAutoHidePolicyRevealsOnLeftEdgeAndProtectsBusyState() {
    let size = CGSize(width: 1200, height: 800)

    // 1. Hovering near left edge reveals hidden sidebar; center workspace does not.
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 6, y: 300), viewSize: size, isRevealed: false, isPinned: false, isBusy: false) == .reveal)
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 18, y: 300), viewSize: size, isRevealed: false, isPinned: false, isBusy: false) == .reveal)
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 200, y: 300), viewSize: size, isRevealed: false, isPinned: false, isBusy: false) == .ignore)

    // 2. While revealed, staying inside sidebar + hysteresis margin keeps it open; moving away schedules hide.
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 245, y: 300), viewSize: size, isRevealed: true, isPinned: false, isBusy: false) == .keepOpen)
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 262, y: 300), viewSize: size, isRevealed: true, isPinned: false, isBusy: false) == .keepOpen)
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 320, y: 300), viewSize: size, isRevealed: true, isPinned: false, isBusy: false) == .scheduleHide)

    // 3. Busy state (typing search / multi-select) keeps sidebar open even when pointer moves out.
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 500, y: 300), viewSize: size, isRevealed: true, isPinned: false, isBusy: true) == .keepOpen)

    // 4. Exiting window bounds schedules hide when revealed and idle; pinned mode always ignores auto-hide.
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: -10, y: 300), viewSize: size, isRevealed: true, isPinned: false, isBusy: false) == .scheduleHide)
    #expect(SidebarAutoHidePolicy.evaluate(pointInView: CGPoint(x: 500, y: 300), viewSize: size, isRevealed: true, isPinned: true, isBusy: false) == .ignore)
}

@Test func learningScreenDiffDetectsSlideChangesAndPersistsCaptureRecords() throws {
    func makeSolidImage(gray: UInt8) -> CGImage {
        let side = 32
        var bytes = [UInt8](repeating: gray, count: side * side)
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    let slideA = makeSolidImage(gray: 30)
    let slideAAlmostSame = makeSolidImage(gray: 34)
    let slideB = makeSolidImage(gray: 210)

    let fpA = LearningScreenDiff.luminanceFingerprint(of: slideA)
    let fpASame = LearningScreenDiff.luminanceFingerprint(of: slideAAlmostSame)
    let fpB = LearningScreenDiff.luminanceFingerprint(of: slideB)

    // Identical or near-identical slide is skipped; genuinely changed slide triggers silent auto-capture.
    #expect(LearningScreenDiff.shouldSaveAutoCapture(previousFingerprint: nil, currentFingerprint: fpA) == true)
    #expect(LearningScreenDiff.normalizedDifference(fpA, fpASame) < LearningScreenDiff.defaultThreshold)
    #expect(LearningScreenDiff.shouldSaveAutoCapture(previousFingerprint: fpA, currentFingerprint: fpASame) == false)
    #expect(LearningScreenDiff.normalizedDifference(fpA, fpB) > 0.5)
    #expect(LearningScreenDiff.shouldSaveAutoCapture(previousFingerprint: fpA, currentFingerprint: fpB) == true)

    // Codable round-trip inside Conversation + Markdown export coverage.
    var convo = Conversation(title: "Transformer Architecture")
    convo.screenCaptures = [
        LearningScreenCapture(
            filename: "screen-test.jpg",
            windowTitle: "Lecture 04 — Attention Mechanism",
            appName: "Google Chrome",
            transcriptExcerpt: "Self-attention computes pairwise relevance scores across all tokens.",
            translationExcerpt: "셀프 어텐션은 모든 토큰 간의 상호 관련성 점수를 계산합니다.",
            userNote: "Scaled dot-product 공식 복습",
            autoCaptured: true,
            pixelWidth: 1600,
            pixelHeight: 900
        )
    ]
    let encoded = try JSONEncoder().encode(convo)
    let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)
    #expect(decoded.screenCaptures?.count == 1)
    #expect(decoded.screenCaptures?[0].windowTitle == "Lecture 04 — Attention Mechanism")
    let md = ConversationExport.markdown(for: decoded)
    #expect(md.contains("## 강의 화면 기록 (1장)"))
    #expect(md.contains("screen-test.jpg"))
    #expect(md.contains("셀프 어텐션은 모든 토큰 간의 상호 관련성 점수를 계산합니다."))
}

@MainActor
@Test func liveSTTDisplayStoreRetainsCommittedSentenceWithoutBlankFlicker() {
    let store = LiveSTTDisplayStore()

    // 1. Interim words arrive
    store.update(text: "Now, notice the phrase", sourceTag: "Mac 재생음")
    #expect(store.displayText == "Now, notice the phrase")
    #expect(store.displaySourceTag == "Mac 재생음")
    #expect(store.hasDisplayText == true)

    // 2. Chunk commits — displayText stays non-empty (no blank placeholder strobe!)
    store.commit(text: "Now, notice the phrase", sourceTag: "Mac 재생음")
    #expect(store.text.isEmpty)
    #expect(store.displayText == "Now, notice the phrase")
    #expect(store.displaySourceTag == "Mac 재생음")
    #expect(store.hasDisplayText == true)

    // 3. Continuing clause from same source merges smoothly into a full sentence
    store.update(text: "especially those in different time zones.", sourceTag: "Mac 재생음")
    #expect(store.displayText == "Now, notice the phrase especially those in different time zones.")

    store.commit(text: "especially those in different time zones.", sourceTag: "Mac 재생음")
    #expect(store.displayText == "Now, notice the phrase especially those in different time zones.")

    // 4. After sentence-ending punctuation, the next utterance replaces cleanly
    store.commit(text: "Let's begin with slide two.", sourceTag: "Mac 재생음")
    #expect(store.displayText == "Let's begin with slide two.")

    // 5. latestUtterance strips source tags and extracts the newest line
    let multi = "[Mac 재생음] First line.\n[Mac 재생음] Second line here."
    #expect(LiveSTTDisplayStore.latestUtterance(from: multi) == "Second line here.")

    // 6. Full clear wipes both live and committed text
    store.clear()
    #expect(store.hasDisplayText == false)
    #expect(store.displayText.isEmpty)
    #expect(store.displaySourceTag == nil)
}

@Test func linkedPanelLayoutSupportsIndependentRightCoachAndLegacyMigration() throws {
    // 1. Default linked layout places independent Coach panel to the right of Linked main view
    var layout = PanelLayout()
    #expect(layout.visibleLinkedPanels(includeCoach: true, includeSummary: true) == [.main, .coach, .summary])
    #expect(layout.visibleLinkedPanels(includeCoach: true, includeSummary: false) == [.main, .coach])

    // 2. Hiding Coach removes it from Linked View panels while keeping main + summary
    layout.setVisible(.coach, false, includeCoach: true)
    #expect(layout.visibleLinkedPanels(includeCoach: true, includeSummary: true) == [.main, .summary])
    layout.setVisible(.coach, true, includeCoach: true)
    #expect(layout.visibleLinkedPanels(includeCoach: true, includeSummary: true) == [.main, .coach, .summary])

    // 3. Reordering Coach right of Summary works and persists cleanly
    layout.moveLinked(.coach, by: 1, includeCoach: true, includeSummary: true)
    #expect(layout.visibleLinkedPanels(includeCoach: true, includeSummary: true) == [.main, .summary, .coach])
    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(PanelLayout.self, from: data)
    #expect(decoded.linkedOrder == [.main, .summary, .coach])

    // 4. Legacy JSON without linkedOrder respects linkedSummaryOnLeft
    let legacyJSON = #"{"splitOrder":["stt","translation","coach","summaryScript"],"linkedSummaryOnLeft":true,"summaryScriptReversed":false,"hiddenPanels":[]}"#.data(using: .utf8)!
    let migrated = try JSONDecoder().decode(PanelLayout.self, from: legacyJSON)
    #expect(migrated.linkedOrder == [.summary, .main, .coach])
    #expect(migrated.linkedSummaryOnLeft == true)
}

@Test func coachStrategiesCoverAllGroupsBuildDirectedPromptsAndPersistStrategyID() throws {
    // 1. Every strategy belongs to a group and all 4 groups are populated
    let groupedCount = CoachStrategyGroup.allCases.reduce(0) { $0 + $1.strategies.count }
    #expect(groupedCount == CoachStrategy.allCases.count)
    #expect(CoachStrategy.allCases.count >= 12)
    for group in CoachStrategyGroup.allCases {
        #expect(!group.strategies.isEmpty)
    }

    // 2. Prompt instructions embed the selected strategy directive for both bilingual and single-language modes
    let bilingualPrompt = CoachStrategy.negotiation.buildInstructions(partnerLang: "English", userLang: "한국어", bilingual: true)
    #expect(bilingualPrompt.contains("[STT_LANG]"))
    #expect(bilingualPrompt.contains("[TARGET_LANG]"))
    #expect(bilingualPrompt.contains(CoachStrategy.negotiation.title))
    #expect(bilingualPrompt.contains("Win-Win"))

    let singlePrompt = CoachStrategy.criticalQuestion.buildInstructions(partnerLang: "English", userLang: "한국어", bilingual: false)
    #expect(singlePrompt.contains(CoachStrategy.criticalQuestion.title))
    #expect(!singlePrompt.contains("[STT_LANG]"))

    // 3. effectiveGoal combines strategy goal with custom goal without duplicating default balanced goal
    #expect(CoachStrategy.negotiation.effectiveGoal(customGoal: CoachStrategy.balanced.defaultGoal) == CoachStrategy.negotiation.defaultGoal)
    #expect(CoachStrategy.negotiation.effectiveGoal(customGoal: "가격 10% 방어").contains("가격 10% 방어"))

    // 4. Advice persists strategyID cleanly via Codable
    let advice = AdvicePolicy.makeAdvice(
        raw: "[STT_LANG]\nReply: Could we revisit the timeline?\nAdvice: Confirm scope before agreeing.\n[TARGET_LANG]\nReply: 일정을 다시 조율해 볼 수 있을까요?\nAdvice: 합의 전에 범위를 먼저 확정하세요.",
        sourceLanguageName: "영어",
        targetLanguageName: "한국어",
        sourceSnapshot: "Can you ship Friday?",
        sourceStart: 0,
        sourceEnd: 20,
        sourceExcerpt: "Can you ship Friday?",
        strategyID: CoachStrategy.diplomaticPushback.rawValue
    )
    #expect(advice.strategyID == CoachStrategy.diplomaticPushback.rawValue)
    let encoded = try JSONEncoder().encode(advice)
    let decoded = try JSONDecoder().decode(Advice.self, from: encoded)
    #expect(decoded.strategyID == CoachStrategy.diplomaticPushback.rawValue)
}
