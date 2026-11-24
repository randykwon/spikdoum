import Foundation
import FoundationModels

struct ConversationKeywords: Codable {
    var terms: [String]
    var date: Date
    var source: String
}
@Generable
struct ExtractedKeywords {
    @Guide(description: "원문에 실제 등장하는 핵심 키워드 3~10개. 명사나 짧은 구절만. 설명·조언·문장 금지. 없으면 빈 배열.")
    var keywords: [String]
}
enum KeywordPolicy {
    static func clean(_ terms: [String], source: String) -> [String] {
        var seen: Set<String> = []
        return terms.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard !term.isEmpty, term.count <= 40, !term.contains("\n"),
                  source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }.prefix(10).map { $0 }
    }
    /// Returns accumulated deduplicated keywords ordered newest-first so the latest keywords appear at the top.
    static func merged(current: ConversationKeywords?, history: [ConversationKeywords]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let snapshots = (current.map { [$0] } ?? []) + history.reversed()
        for snapshot in snapshots {
            for term in snapshot.terms {
                let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
                result.append(cleaned)
            }
        }
        return result
    }
    static func parse(_ text: String) throws -> [String] {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            var lines = json.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            json = lines.joined(separator: "\n")
        }
        struct Output: Decodable { var keywords: [String] }
        return try JSONDecoder().decode(Output.self, from: Data(json.utf8)).keywords
    }
}
