import Foundation

struct DuplexTranscript {
    struct Part { var source: String; var start: Int; var text: String }
    private var snapshots: [String: String] = [:]
    private var parts: [Part] = []
    mutating func update(source: String, text: String) -> String {
        let old = snapshots[source] ?? ""
        guard old != text else { return rendered }
        let common = zip(old, text).prefix { $0 == $1 }.count
        parts = parts.compactMap { part in
            guard part.source == source else { return part }
            guard part.start < common else { return nil }
            var retained = part
            retained.text = String(part.text.prefix(common - part.start))
            return retained.text.isEmpty ? nil : retained
        }
        let added = String(text.dropFirst(common))
        if !added.isEmpty {
            if let last = parts.last, last.source == source, last.start + last.text.count == common {
                parts[parts.count - 1].text += added
            } else { parts.append(Part(source: source, start: common, text: added)) }
        }
        snapshots[source] = text
        return rendered
    }
    var rendered: String {
        parts.map { "[\($0.source)] \($0.text)" }.joined(separator: "\n")
    }
}
