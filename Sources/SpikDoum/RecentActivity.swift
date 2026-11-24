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
