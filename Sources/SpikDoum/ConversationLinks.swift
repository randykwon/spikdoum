import Foundation

enum ConversationLinks {
    static func spans(start: Int?, end: Int?, excerpt: String?, conversation: Conversation) -> [TranscriptSpan] {
        guard let start, let end, let excerpt, start >= 0, end > start else { return [] }
        let transcript = conversation.transcript
        guard let from = transcript.index(transcript.startIndex, offsetBy: start, limitedBy: transcript.endIndex),
              let to = transcript.index(from, offsetBy: end - start, limitedBy: transcript.endIndex),
              transcript[from..<to] == excerpt else { return [] }
        return (conversation.transcriptSpans ?? []).filter { $0.start < end && $0.end > start }
    }
    static func spans(for translation: TranslationEntry, in conversation: Conversation) -> [TranscriptSpan] {
        spans(start: translation.sourceStart, end: translation.sourceEnd, excerpt: translation.source, conversation: conversation)
    }
    static func spans(for advice: Advice, in conversation: Conversation) -> [TranscriptSpan] {
        if let start = advice.sourceStart, let end = advice.sourceEnd, let excerpt = advice.sourceExcerpt {
            return spans(start: start, end: end, excerpt: excerpt, conversation: conversation)
        }
        // Older records can be linked only when their saved snapshot still exactly matches.
        guard let snapshot = advice.sourceSnapshot, !snapshot.isEmpty, conversation.transcript.hasPrefix(snapshot) else { return [] }
        let excerpt = AdvicePolicy.context(snapshot)
        return spans(start: snapshot.count - excerpt.count, end: snapshot.count, excerpt: excerpt, conversation: conversation)
    }
    static func label(_ spans: [TranscriptSpan], in conversation: Conversation) -> String {
        let all = conversation.transcriptSpans ?? []
        let ids = Set(spans.map(\.id))
        let numbers = all.enumerated().filter { ids.contains($0.element.id) }.map { $0.offset + 1 }
        guard let first = numbers.first, let last = numbers.last else { return "연결 정보 없음" }
        return first == last ? "#\(first)" : "#\(first)–#\(last)"
    }
}
