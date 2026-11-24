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
