import Foundation

struct Advice: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var sourceLanguageText: String? = nil
    var targetLanguageText: String? = nil
    var sourceLanguageName: String? = nil
    var targetLanguageName: String? = nil
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
    var targetLanguage: String? = nil
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
    var allRelatedKeywords: [String: [String]] {
        KeywordPolicy.mergedRelated(current: keywords, history: keywordHistory ?? [])
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
    static func parseBilingual(_ raw: String) -> (sourceText: String, targetText: String)? {
        let pattern = #"(?is)(?:^|\n)\s*(?:#+\s*)?\[STT_LANG\]:?\s*(.*?)\s*(?:^|\n)\s*(?:#+\s*)?\[TARGET_LANG\]:?\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r1 = Range(match.range(at: 1), in: raw),
              let r2 = Range(match.range(at: 2), in: raw) else { return nil }
        let sourceText = raw[r1].trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = raw[r2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, !targetText.isEmpty else { return nil }
        return (sourceText, targetText)
    }

    static func makeAdvice(
        raw: String,
        sourceLanguageName: String?,
        targetLanguageName: String?,
        sourceSnapshot: String?,
        sourceStart: Int?,
        sourceEnd: Int?,
        sourceExcerpt: String?
    ) -> Advice {
        if let pair = parseBilingual(raw) {
            let srcLabel = sourceLanguageName ?? "STT"
            let dstLabel = targetLanguageName ?? "번역"
            let combined = "[\(srcLabel)]\n\(pair.sourceText)\n\n[\(dstLabel)]\n\(pair.targetText)"
            return Advice(
                text: combined,
                sourceLanguageText: pair.sourceText,
                targetLanguageText: pair.targetText,
                sourceLanguageName: srcLabel,
                targetLanguageName: dstLabel,
                sourceSnapshot: sourceSnapshot,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                sourceExcerpt: sourceExcerpt
            )
        }
        return Advice(
            text: raw,
            sourceSnapshot: sourceSnapshot,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            sourceExcerpt: sourceExcerpt
        )
    }
    static func context(_ text: String) -> String { String(text.suffix(3000)) }

    /// Conservative token estimate tailored for Apple FoundationModels (4,096-token window):
    /// CJK / non-ASCII characters frequently tokenize to ~2.0–3.0 tokens each (byte-fallback), whereas ASCII averages ~0.35 tokens.
    static func estimatedTokens(_ text: String) -> Int {
        var units = 0 // 1 token == 10 units
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                units += 4
            } else {
                units += 26
            }
        }
        return (units + 9) / 10
    }

    static func boundedTail(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        let maxUnits = maxTokens * 10
        var units = 0
        var start = text.endIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            var charUnits = 0
            for scalar in text[prev].unicodeScalars {
                charUnits += scalar.isASCII ? 4 : 26
            }
            if units + charUnits > maxUnits { break }
            units += charUnits
            start = prev
        }
        return String(text[start...])
    }

    static func boundedHead(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        let maxUnits = maxTokens * 10
        var units = 0
        var end = text.startIndex
        while end < text.endIndex {
            var charUnits = 0
            for scalar in text[end].unicodeScalars {
                charUnits += scalar.isASCII ? 4 : 26
            }
            if units + charUnits > maxUnits { break }
            units += charUnits
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
