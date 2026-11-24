import Foundation
import Testing
@testable import SpikDoum

private func linkedConversation() -> Conversation {
    Conversation(transcript: "Hello world. Next question?", transcriptSpans: [
        TranscriptSpan(date: Date(), start: 0, text: "Hello world."),
        TranscriptSpan(date: Date(), start: 12, text: " Next question?")
    ])
}
@Test func linksTranslationAcrossSpeechBlocksAndRejectsStaleText() {
    var conversation = linkedConversation()
    let translation = TranslationEntry(source: "world. Next", translated: "세상. 다음", sourceStart: 6, sourceEnd: 17)
    #expect(ConversationLinks.spans(for: translation, in: conversation).map(\.id) == conversation.transcriptSpans?.map(\.id))
    #expect(ConversationLinks.label(ConversationLinks.spans(for: translation, in: conversation), in: conversation) == "#1–#2")
    conversation.transcript = "Hello earth. Next question?"
    #expect(ConversationLinks.spans(for: translation, in: conversation).isEmpty)
}
@Test func adviceContextSurvivesSnapshotCleanupAndReload() throws {
    var conversation = linkedConversation()
    conversation.advice = [Advice(text: "Ask a follow-up", sourceSnapshot: nil, sourceStart: 0, sourceEnd: conversation.transcript.count, sourceExcerpt: conversation.transcript)]
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
    let linked = ConversationLinks.spans(for: restored.advice[0], in: restored)
    #expect(linked.count == 2)
    #expect(linked.last?.id == restored.transcriptSpans?.last?.id)
}
@Test func legacyRecordsRequireExactSnapshotAndNeverUseTimestampForLinks() {
    let conversation = linkedConversation()
    let oldAdvice = Advice(text: "Advice", sourceSnapshot: "Hello world.")
    #expect(ConversationLinks.spans(for: oldAdvice, in: conversation).count == 1)
    #expect(ConversationLinks.spans(for: Advice(text: "No source"), in: conversation).isEmpty)
    #expect(ConversationLinks.spans(for: TranslationEntry(source: "Hello", translated: "안녕"), in: conversation).isEmpty)
    #expect(ConversationLinks.spans(start: -1, end: 4, excerpt: "Hell", conversation: conversation).isEmpty)
}
