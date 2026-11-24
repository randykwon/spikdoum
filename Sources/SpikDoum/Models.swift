import Foundation

struct Advice: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var sourceSnapshot: String? = nil
    var sourceStart: Int? = nil
    var sourceEnd: Int? = nil
    var sourceExcerpt: String? = nil
}
struct TranslationEntry: Codable, Identifiable {
    var id = UUID()
    var source: String
    var date: Date? = Date()
    var translated: String
    var engine: String? = "apple-translation-v1"
    var sourceStart: Int? = nil
    var sourceEnd: Int? = nil
}
struct SpeakerTurn: Codable, Identifiable {
    var id: String
    var speaker: Int?
    var start: Double
    var text: String
    var label: String { speaker.map { "화자 \($0) · 추정" } ?? "화자 확인 중"
    }
}
struct SummarySnapshot: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var preview: String?
    var text: String
}
struct OrganizedScript: Codable, Equatable {
    var text: String
    var coveredSource: String
    var updatedAt: Date
}
struct Conversation: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title = "새 대화"
    var archivedAt: Date? = nil
    var transcript = ""
    var advice: [Advice] = []
    var translations: [TranslationEntry]? = nil
    var turns: [SpeakerTurn]? = nil
    var preview: String? = nil
    var summaries: [String: SummaryState]? = nil
    var transcriptSpans: [TranscriptSpan]? = nil
    var keywords: ConversationKeywords? = nil
    var keywordHistory: [ConversationKeywords]? = nil
    var summaryHistory: [SummarySnapshot]? = nil
    var audioClips: [AudioClipRecord]? = nil
    var organizedScript: OrganizedScript? = nil
    var allKeywords: [String] {
        KeywordPolicy.merged(current: keywords, history: keywordHistory ?? [])
    }
}

enum AdvicePolicy {
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    static func shouldGenerate(text: String, previous: String) -> Bool {
        let current = normalized(text), old = normalized(previous)
        guard current.count >= 8, current != old else { return false }
        if old.isEmpty { return true }
        let common = zip(current, old).prefix { $0 == $1 }.count
        // Correcting an earlier word does not make the entire transcript new.
        let growth = current.count - old.count
        return growth >= 16 || (common < old.count && growth >= 8 && common < current.count - 24)
    }
    static func isNoChange(_ text: String) -> Bool {
        let candidate = normalized(text)
        return candidate.isEmpty || ["변경없음", "nochange", "変更なし", "无变化"].contains(candidate)
    }
    static func isDuplicate(_ text: String, recent: [String]) -> Bool {
        let candidate = normalized(text)
        guard !isNoChange(text) else { return true }
        func grams(_ value: String) -> Set<String> {
            let chars = Array(value)
            guard chars.count >= 3 else { return [value] }
            return Set((0...(chars.count - 3)).map { String(chars[$0...($0 + 2)]) })
        }
        let left = grams(candidate)
        return recent.contains { previous in
            let old = normalized(previous)
            if old == candidate { return true }
            let right = grams(old)
            let overlap = Double(left.intersection(right).count) / Double(max(1, min(left.count, right.count)))
            return overlap >= 0.80 && min(old.count, candidate.count) >= 15
        }
    }
    static func context(_ text: String) -> String { String(text.suffix(3000)) }
}
