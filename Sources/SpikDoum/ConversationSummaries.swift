import Foundation
import FoundationModels

struct SummaryState: Codable {
    var text: String
    var coveredSource: String
    var updatedAt: Date
}

@Generable
struct ConversationDigest {
    @Guide(description: "Natural title representing the conversation in the requested output language. Max 20 characters.")
    var title: String
    @Guide(description: "Brief preview summary for the conversation list in the requested output language. 1-2 sentences, max 80 characters.")
    var preview: String
    @Guide(description: "Cumulative summary combining previous summary and new speech in the requested output language. Concisely capture key points, decisions, action items, and open questions without inventing facts.")
    var summary: String
}

struct SummaryDigest: Decodable, Equatable {
    var title: String
    var preview: String
    var summary: String
}
struct SummaryWork {
    var source: String
    var covered: String
    var previous: String
}
enum SummaryPolicy {
    static func parseDigest(_ text: String) throws -> SummaryDigest {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            var lines = json.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            json = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try JSONDecoder().decode(SummaryDigest.self, from: Data(json.utf8))
    }
    static func work(source: String, state: SummaryState?) -> SummaryWork? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source != state?.coveredSource else { return nil }
        let prefix = state?.coveredSource ?? ""
        let incremental = source.hasPrefix(prefix)
        let pending = incremental ? String(source.dropFirst(prefix.count)) : source
        let chunk = String(pending.prefix(1800))
        return SummaryWork(source: chunk, covered: (incremental ? prefix : "") + chunk,
                           previous: incremental ? String((state?.text ?? "").suffix(2200)) : "")
    }
}
