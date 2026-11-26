import Foundation

struct TranscriptSpan: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var start: Int
    var text: String
    var end: Int { start + text.count }
}
enum RecentActivity {
    static func update(old: String, new: String, spans: [TranscriptSpan], at date: Date) -> [TranscriptSpan] {
        guard old != new else { return spans }
        // O(1) append fast-path (95%+ of live STT updates): avoids O(N) character zip & rebuilding all spans.
        if !old.isEmpty && new.hasPrefix(old) {
            let oldCount = old.count
            let appended = String(new.dropFirst(oldCount))
            guard !appended.isEmpty else { return spans }
            var kept = spans
            if let last = kept.last, last.end == oldCount, date.timeIntervalSince(last.date) <= 8, last.text.count + appended.count <= 220 {
                kept[kept.count - 1].text += appended
                kept[kept.count - 1].date = date
            } else {
                kept.append(TranscriptSpan(date: date, start: oldCount, text: appended))
            }
            return kept
        }
        let common = zip(old, new).prefix { $0 == $1 }.count
        var kept = spans.compactMap { span -> TranscriptSpan? in
            guard span.start < common else { return nil }
            var copy = span
            copy.text = String(span.text.prefix(common - span.start))
            return copy.text.isEmpty ? nil : copy
        }
        let appended = String(new.dropFirst(common))
        if !appended.isEmpty {
            if let last = kept.last, last.end == common, date.timeIntervalSince(last.date) <= 8, last.text.count + appended.count <= 220 {
                kept[kept.count - 1].text += appended
                kept[kept.count - 1].date = date
            } else { kept.append(TranscriptSpan(date: date, start: common, text: appended)) }
        }
        return kept
    }
    static func sourceDate(for entry: TranslationEntry, spans: [TranscriptSpan]) -> Date? {
        guard let start = entry.sourceStart, let end = entry.sourceEnd else { return entry.date }
        return spans.last { $0.start < end && $0.end > start }?.date ?? entry.date
    }
}
