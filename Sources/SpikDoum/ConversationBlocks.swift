import Foundation

struct ConversationBlock: Identifiable {
    var id: String
    var ordinal: Int
    var start: Int
    var end: Int
    var text: String
    var date: Date?
    var spans: [TranscriptSpan]
    var translation: TranslationEntry?
    var advice: [Advice] = []
}

enum ConversationBlocks {
    /// The displayed original uses exactly the same character range as its translation.
    static func make(_ conversation: Conversation) -> [ConversationBlock] {
        let transcript = conversation.transcript
        let kept = TranslationPolicy.retained(transcript: transcript, entries: conversation.translations ?? [])
        let translations = kept.entries
        let spans = conversation.transcriptSpans ?? []
        var blocks: [ConversationBlock] = []
        var cursor = 0
        for entry in translations {
            guard let end = entry.sourceEnd else { continue }
            let linked = spans.filter { $0.start < end && $0.end > cursor }
            blocks.append(ConversationBlock(id: "translation:\(entry.id)", ordinal: blocks.count + 1, start: cursor, end: end,
                                           text: entry.source, date: linked.last?.date,
                                           spans: linked, translation: entry))
            cursor = end
        }
        var stringIndex = kept.index
        var stringCursor = kept.cursor
        func slice(from start: Int, to end: Int) -> String {
            guard start >= stringCursor, end >= start,
                  let s = transcript.index(stringIndex, offsetBy: start - stringCursor, limitedBy: transcript.endIndex),
                  let e = transcript.index(s, offsetBy: end - start, limitedBy: transcript.endIndex) else {
                return String(transcript.dropFirst(start).prefix(max(0, end - start)))
            }
            stringIndex = e
            stringCursor = end
            return String(transcript[s..<e])
        }
        for span in spans where span.end > cursor {
            if span.start > cursor {
                blocks.append(ConversationBlock(id: "gap:\(cursor)", ordinal: blocks.count + 1, start: cursor, end: span.start,
                                               text: slice(from: cursor, to: span.start), date: nil, spans: []))
            }
            let start = max(cursor, span.start)
            let text = slice(from: start, to: span.end)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            blocks.append(ConversationBlock(id: "span:\(span.id)", ordinal: blocks.count + 1, start: start, end: span.end,
                                           text: text, date: span.date, spans: [span]))
            cursor = span.end
        }
        let totalCount = stringCursor + transcript[stringIndex...].count
        if cursor < totalCount {
            let text = slice(from: cursor, to: totalCount)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(ConversationBlock(id: "gap:\(cursor)", ordinal: blocks.count + 1, start: cursor, end: totalCount,
                                               text: text, date: nil, spans: []))
            }
        }
        for advice in conversation.advice {
            guard !ConversationLinks.spans(for: advice, in: conversation).isEmpty,
                  let end = advice.sourceEnd ?? advice.sourceSnapshot?.count,
                  let index = blocks.firstIndex(where: { $0.start < end && $0.end >= end }) else { continue }
            blocks[index].advice.append(advice)
        }
        return blocks
    }
}
