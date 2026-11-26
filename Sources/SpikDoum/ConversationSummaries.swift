import Foundation
import FoundationModels

struct SummaryState: Codable {
    var text: String
    var coveredSource: String
    var updatedAt: Date
    var primaryLanguageCode: String? = nil
    var localizedTexts: [String: String]? = nil
}

struct SummaryLanguagePreferences: Codable, Equatable, Sendable {
    static let storageKey = "summaryLanguagePreferencesV1"

    var includeTranslationLanguage: Bool = true
    var includeSTTLanguage: Bool = true
    var extraLanguageCodes: [String] = []

    func resolvedLanguages(sttSpec: SupportedLanguage?, targetSpec: SupportedLanguage) -> [SupportedLanguage] {
        var result: [SupportedLanguage] = []
        func appendUnique(_ lang: SupportedLanguage?) {
            guard let lang, !result.contains(where: { $0.code == lang.code }) else { return }
            result.append(lang)
        }
        if includeTranslationLanguage { appendUnique(targetSpec) }
        if includeSTTLanguage { appendUnique(sttSpec) }
        for code in extraLanguageCodes {
            appendUnique(LanguageCatalog.language(for: code))
        }
        if result.isEmpty {
            result.append(targetSpec)
        }
        return result
    }

    mutating func toggleExtra(_ code: String) {
        if let index = extraLanguageCodes.firstIndex(of: code) {
            extraLanguageCodes.remove(at: index)
        } else if LanguageCatalog.language(for: code) != nil {
            extraLanguageCodes.append(code)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
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

enum RecentSummaryWindow: Int, CaseIterable, Identifiable, Codable, Sendable {
    case min1 = 1
    case min2 = 2
    case min3 = 3
    case min5 = 5
    case min10 = 10
    case min30 = 30

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var summaryKey: String { "recent-\(rawValue)m" }
    var shortLabel: String { "\(rawValue)분" }
    var title: String { "최근 \(rawValue)분" }
}

struct RecentSummarySlice: Equatable, Sendable {
    var window: RecentSummaryWindow
    var text: String
    var cutoff: Date
    var reference: Date
    var spanCount: Int
    var anchoredToLastActivity: Bool
    var usedFallbackFullTranscript: Bool
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

    /// Extracts the conversation remarks spoken within the requested recent time window.
    /// - While listening, anchors to `referenceDate` (now) so "최근 N분" reflects live wall-clock time.
    /// - When stopped / reviewing an older conversation, anchors to the conversation's latest recorded timestamp
    ///   so "최근 N분" summarizes the final N minutes of that conversation.
    static func recentTranscript(
        for conversation: Conversation,
        window: RecentSummaryWindow,
        referenceDate: Date = Date(),
        isListening: Bool
    ) -> RecentSummarySlice {
        let spans = conversation.transcriptSpans ?? []
        let datedTranslations = (conversation.translations ?? []).compactMap { entry -> (date: Date, text: String)? in
            guard let date = entry.date else { return nil }
            let trimmed = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (date, trimmed)
        }
        let latestActivity = spans.map(\.date).max() ?? datedTranslations.map(\.date).max()
        let anchoredToLastActivity = !isListening && latestActivity != nil
        let reference = anchoredToLastActivity ? (latestActivity ?? referenceDate) : referenceDate
        let cutoff = reference.addingTimeInterval(-window.seconds)

        if !spans.isEmpty {
            let matching = spans.filter { $0.date >= cutoff && $0.date <= reference.addingTimeInterval(1) }
            let joined = matching.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return RecentSummarySlice(
                window: window,
                text: joined,
                cutoff: cutoff,
                reference: reference,
                spanCount: matching.count,
                anchoredToLastActivity: anchoredToLastActivity,
                usedFallbackFullTranscript: false
            )
        }

        if !datedTranslations.isEmpty {
            let matching = datedTranslations.filter { $0.date >= cutoff && $0.date <= reference.addingTimeInterval(1) }
            let joined = matching.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return RecentSummarySlice(
                window: window,
                text: joined,
                cutoff: cutoff,
                reference: reference,
                spanCount: matching.count,
                anchoredToLastActivity: anchoredToLastActivity,
                usedFallbackFullTranscript: false
            )
        }

        // Legacy conversations saved before per-span timestamps existed.
        let full = conversation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty && (!isListening || conversation.date >= cutoff) {
            return RecentSummarySlice(
                window: window,
                text: full,
                cutoff: cutoff,
                reference: reference,
                spanCount: 1,
                anchoredToLastActivity: !isListening,
                usedFallbackFullTranscript: true
            )
        }

        return RecentSummarySlice(
            window: window,
            text: "",
            cutoff: cutoff,
            reference: reference,
            spanCount: 0,
            anchoredToLastActivity: anchoredToLastActivity,
            usedFallbackFullTranscript: false
        )
    }
}
