import Foundation
import Testing
@testable import SpikDoum

@Test func readingSnapshotKeepsRowsAndTranslationsStillDuringSTTRevision() {
    let date = Date(timeIntervalSince1970: 100)
    let span = TranscriptSpan(date: date, start: 0, text: "First sentence. Second sentence.")
    var live = Conversation(transcript: span.text, transcriptSpans: [span])
    var reading = ReadingState()
    reading.pause(live, listening: true, now: date)
    let before = ConversationBlocks.make(reading.display(current: live)!)
    live.translations = [TranslationEntry(source: live.transcript, translated: "첫 문장. 두 번째 문장.", sourceStart: 0, sourceEnd: live.transcript.count)]
    live.transcript = "Corrected speech with newly arriving content."
    live.transcriptSpans = RecentActivity.update(old: span.text, new: live.transcript, spans: [span], at: date.addingTimeInterval(120))
    live.advice = [Advice(text: "New advice")]
    let frozen = reading.display(current: live)!
    #expect(frozen.transcript == span.text)
    #expect(frozen.translations == nil)
    #expect(frozen.advice.isEmpty)
    #expect(ConversationBlocks.make(frozen).map(\.id) == before.map(\.id))
    #expect(reading.referenceDate == date)
    reading.resume()
    #expect(reading.display(current: live)?.transcript == live.transcript)
    #expect(reading.display(current: live)?.advice.count == 1)
    #expect(reading.referenceDate == nil)
}

@Test func readingSnapshotNeverShowsAnotherConversationsContent() {
    let first = Conversation(transcript: "First private conversation")
    let second = Conversation(transcript: "Second conversation")
    var reading = ReadingState()
    reading.pause(first, listening: false)
    #expect(reading.display(current: second)?.id == second.id)
    #expect(reading.display(current: nil) == nil)
}

@Test func pausedHistoryUsesLastActivityInsteadOfWallClockAndFreezesKeywords() {
    let date = Date(timeIntervalSince1970: 100)
    let span = TranscriptSpan(date: date, start: 0, text: "Budget planning")
    var live = Conversation(transcript: span.text, transcriptSpans: [span])
    live.keywords = ConversationKeywords(terms: ["Budget"], date: date, source: span.text)
    var reading = ReadingState()
    reading.pause(live, listening: false, now: date.addingTimeInterval(3600))
    #expect(reading.referenceDate == date)
    live.translations = [TranslationEntry(source: span.text, translated: "예산 계획", sourceStart: 0, sourceEnd: span.text.count)]
    live.title = "New generated title"
    live.keywords = ConversationKeywords(terms: ["planning"], date: date.addingTimeInterval(10), source: span.text)
    #expect(reading.display(current: live)?.keywords?.terms == ["Budget"])
    #expect(reading.display(current: live)?.title == "새 대화")
    #expect(reading.display(current: live)?.translations == nil)
    reading.resume()
    #expect(reading.display(current: live)?.translations?.count == 1)
}
