import Foundation
import Testing
@testable import SpikDoum

@Test func liveTranslationWaitsForTwoSentences() {
    let one = TranslationPolicy.plan(transcript: "Hello there. Still speaking", entries: [], flush: false)
    #expect(one.source.isEmpty)
    #expect(one.waitingForSentences)
    #expect(one.completedSentences == 1)
    let two = TranslationPolicy.plan(transcript: "Hello there. How are you? Still speaking", entries: [], flush: false)
    #expect(two.source.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello there. How are you?")
    #expect(!two.waitingForSentences)
}

@Test func translationLimitsBatchToThreeSentencesWithoutLosingRemainder() {
    let text = "First sentence. Second sentence? Third sentence! Fourth sentence."
    let work = TranslationPolicy.plan(transcript: text, entries: [], flush: false)
    #expect(work.source.trimmingCharacters(in: .whitespacesAndNewlines) == "First sentence. Second sentence? Third sentence!")
    let entry = TranslationEntry(source: work.source, translated: "test", sourceStart: 0, sourceEnd: work.end)
    let waiting = TranslationPolicy.plan(transcript: text, entries: [entry], flush: false)
    #expect(waiting.waitingForSentences)
    let flushed = TranslationPolicy.plan(transcript: text, entries: [entry], flush: true)
    #expect(flushed.source == "Fourth sentence.")
    #expect(work.source + flushed.source == text)
}

@Test func translationFlushesOnSilenceOrMaximumWait() {
    let start = Date(timeIntervalSince1970: 100)
    #expect(!TranslationPolicy.shouldFlush(now: start.addingTimeInterval(1), lastChange: start, batchStarted: start))
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(2), lastChange: start, batchStarted: start))
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(6), lastChange: start.addingTimeInterval(5.9), batchStarted: start))
    let unfinished = TranslationPolicy.plan(transcript: "\nOne unfinished thought", entries: [], flush: true)
    #expect(unfinished.source == "\nOne unfinished thought")
}

@Test func sourceLabelsNewlinesAndAbbreviationsDoNotTriggerEarlyBatch() {
    let text = "[Mac 재생음]\nDr. Smith paid 3.14 dollars.\nStill speaking"
    let work = TranslationPolicy.plan(transcript: text, entries: [], flush: false)
    #expect(work.waitingForSentences)
    #expect(work.completedSentences == 1)
    let ready = TranslationPolicy.plan(transcript: text + " about this. End", entries: [], flush: false)
    #expect(ready.source.contains("Still speaking about this."))
    #expect(!ready.source.hasSuffix("End"))
}

@Test func translationRowsMatchExactSourceAcrossSTTSpans() {
    let text = "First sentence. Second sentence. Last unfinished thought"
    let date = Date()
    let spans = [TranscriptSpan(date: date, start: 0, text: "First sentence. "),
                 TranscriptSpan(date: date, start: 16, text: "Second sentence. Last unfinished thought")]
    let work = TranslationPolicy.plan(transcript: text, entries: [], flush: false)
    let entry = TranslationEntry(source: work.source, translated: "첫 문장. 두 번째 문장.", sourceStart: 0, sourceEnd: work.end)
    let advice = Advice(text: "Follow up", sourceStart: 0, sourceEnd: work.end, sourceExcerpt: work.source)
    let conversation = Conversation(transcript: text, advice: [advice], translations: [entry], transcriptSpans: spans)
    let rows = ConversationBlocks.make(conversation)
    #expect(rows.count == 2)
    #expect(rows[0].text == entry.source)
    #expect(rows[0].spans.count == 2)
    #expect(rows[0].translation?.id == entry.id)
    #expect(rows[0].advice.map(\.id) == [advice.id])
    #expect(rows[1].translation == nil)
    #expect(rows.map(\.text).joined() == text)
    #expect(rows[0].end == rows[1].start)
}

@Test func alignedRowsPreserveLegacyPrefixWithoutTiming() {
    let text = "Older original text. Recent speech"
    let span = TranscriptSpan(date: Date(), start: 21, text: "Recent speech")
    let conversation = Conversation(transcript: text, transcriptSpans: [span])
    let rows = ConversationBlocks.make(conversation)
    #expect(rows.map(\.text).joined() == text)
    #expect(rows[0].spans.isEmpty)
}

@Test func realtimeTranslationSingleSentenceAndFastFlushTriggerImmediately() {
    let one = TranslationPolicy.plan(transcript: "Hello there. Still speaking", entries: [], flush: false, minSentences: 1)
    #expect(!one.waitingForSentences)
    #expect(one.source.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello there.")

    let unfinished = TranslationPolicy.plan(transcript: "Still speaking without punctuation", entries: [], flush: false, minSentences: 1)
    #expect(unfinished.waitingForSentences)
    #expect(unfinished.source.isEmpty)

    let start = Date(timeIntervalSince1970: 100)
    #expect(!TranslationPolicy.shouldFlush(now: start.addingTimeInterval(0.5), lastChange: start, batchStarted: start, silenceSeconds: 0.9, maxWaitSeconds: 2.5))
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(0.95), lastChange: start, batchStarted: start, silenceSeconds: 0.9, maxWaitSeconds: 2.5))
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(2.6), lastChange: start.addingTimeInterval(2.4), batchStarted: start, silenceSeconds: 0.9, maxWaitSeconds: 2.5))

    // Simple Fast Mode uses even tighter silence (0.55s) and max-wait (1.6s) flush thresholds.
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(0.6), lastChange: start, batchStarted: start, silenceSeconds: 0.55, maxWaitSeconds: 1.6))
    #expect(TranslationPolicy.shouldFlush(now: start.addingTimeInterval(1.65), lastChange: start.addingTimeInterval(1.5), batchStarted: start, silenceSeconds: 0.55, maxWaitSeconds: 1.6))
}

@Test func liveTranslationSplitsMicAndSystemAudioTurnsCleanly() {
    let duplex = "[Mac 재생음] 明日の会議を確認しましょう。\n[마이크] 네, 금요일 오후까지 확인하겠습니다."
    let first = TranslationPolicy.plan(transcript: duplex, entries: [], flush: false, minSentences: 1)
    #expect(!first.waitingForSentences)
    #expect(TranslationPolicy.sourceTag(of: first.source) == "Mac 재생음")
    #expect(TranslationPolicy.displayText(strippingSourceTag: first.source) == "明日の会議を確認しましょう。")

    let firstEntry = TranslationEntry(source: first.source, translated: "내일 회의를 확인합시다.", sourceStart: first.start, sourceEnd: first.end)
    let second = TranslationPolicy.plan(transcript: duplex, entries: [firstEntry], flush: false, minSentences: 1)
    #expect(!second.waitingForSentences)
    #expect(TranslationPolicy.sourceTag(of: second.source) == "마이크")
    #expect(TranslationPolicy.displayText(strippingSourceTag: second.source) == "네, 금요일 오후까지 확인하겠습니다.")
}

@Test func oneSentenceModeCollectsAndEmitsExactlyOneSentencePerCard() {
    let text = "First sentence. Second sentence? Third sentence! Unfinished fragment"
    var entries: [TranslationEntry] = []

    let s1 = TranslationPolicy.plan(transcript: text, entries: entries, flush: false, minSentences: 1, maxSentences: 1)
    #expect(!s1.waitingForSentences)
    #expect(s1.source.trimmingCharacters(in: .whitespacesAndNewlines) == "First sentence.")
    entries.append(TranslationEntry(source: s1.source, translated: "첫 번째 문장.", sourceStart: s1.start, sourceEnd: s1.end))

    let s2 = TranslationPolicy.plan(transcript: text, entries: entries, flush: false, minSentences: 1, maxSentences: 1)
    #expect(!s2.waitingForSentences)
    #expect(s2.source.trimmingCharacters(in: .whitespacesAndNewlines) == "Second sentence?")
    entries.append(TranslationEntry(source: s2.source, translated: "두 번째 문장?", sourceStart: s2.start, sourceEnd: s2.end))

    let s3 = TranslationPolicy.plan(transcript: text, entries: entries, flush: false, minSentences: 1, maxSentences: 1)
    #expect(!s3.waitingForSentences)
    #expect(s3.source.trimmingCharacters(in: .whitespacesAndNewlines) == "Third sentence!")
    entries.append(TranslationEntry(source: s3.source, translated: "세 번째 문장!", sourceStart: s3.start, sourceEnd: s3.end))

    // Unfinished trailing fragment waits until the sentence finishes (or silence flush).
    let waiting = TranslationPolicy.plan(transcript: text, entries: entries, flush: false, minSentences: 1, maxSentences: 1)
    #expect(waiting.waitingForSentences)
    #expect(waiting.source.isEmpty)

    let flushed = TranslationPolicy.plan(transcript: text, entries: entries, flush: true, minSentences: 1, maxSentences: 1)
    #expect(!flushed.waitingForSentences)
    #expect(flushed.source == "Unfinished fragment")
}
