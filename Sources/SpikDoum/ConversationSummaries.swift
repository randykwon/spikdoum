import Foundation
import FoundationModels

struct SummaryState: Codable {
    var text: String
    var coveredSource: String
    var updatedAt: Date
}

@Generable
struct ConversationDigest {
    @Guide(description: "대화 내용을 대표하는 자연스러운 한국어 제목. 20자 이내.")
    var title: String
    @Guide(description: "대화 목록에서 보여줄 한국어 미리보기 요약. 80자 이내, 한두 문장.")
    var preview: String
    @Guide(description: "이전 요약과 새 발언을 합친 누적 한국어 요약. 핵심 내용, 결정 사항, 할 일, 미해결 질문을 짧게 정리. 없는 정보는 만들지 않음.")
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
