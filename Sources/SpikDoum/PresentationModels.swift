import Foundation

enum SignpostCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case opening
    case transition
    case visuals
    case emphasis
    case demo
    case engagement
    case timeControl
    case qa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return "도입·훅"
        case .transition: return "전환"
        case .visuals: return "차트·데이터"
        case .emphasis: return "강조·스토리"
        case .demo: return "데모·돌발"
        case .engagement: return "청중 참여"
        case .timeControl: return "시간·마무리"
        case .qa: return "Q&A·대응"
        }
    }

    var icon: String {
        switch self {
        case .opening: return "hand.wave"
        case .transition: return "arrow.right.circle"
        case .visuals: return "chart.bar.xaxis"
        case .emphasis: return "star.fill"
        case .demo: return "play.laptopcomputer"
        case .engagement: return "person.3.fill"
        case .timeControl: return "clock.badge.checkmark"
        case .qa: return "questionmark.bubble"
        }
    }

    static func parseFlexible(_ raw: String) -> SignpostCategory {
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = SignpostCategory(rawValue: key) { return exact }
        if key.contains("open") || key.contains("hook") || key.contains("도입") { return .opening }
        if key.contains("visual") || key.contains("chart") || key.contains("data") || key.contains("차트") || key.contains("데이터") { return .visuals }
        if key.contains("demo") || key.contains("glitch") || key.contains("데모") { return .demo }
        if key.contains("engage") || key.contains("audience") || key.contains("청중") || key.contains("참여") { return .engagement }
        if key.contains("emph") || key.contains("story") || key.contains("강조") { return .emphasis }
        if key.contains("time") || key.contains("close") || key.contains("wrap") || key.contains("시간") || key.contains("마무리") { return .timeControl }
        if key.contains("qa") || key.contains("q&a") || key.contains("question") || key.contains("질문") { return .qa }
        return .transition
    }
}

struct PresentationChecklistItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var stageTag: String? = nil
    var targetMinute: Int? = nil
    var isChecked: Bool = false
    var autoMatched: Bool = false
    var manuallyOverridden: Bool = false
    var matchedAt: Date? = nil

    /// Splits `"35% 비용 절감 / 35% / thirty-five"` or comma-separated aliases into match candidates.
    var aliases: [String] {
        let separators = CharacterSet(charactersIn: "/,|")
        let parts = title
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [title.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }

    var displayLabel: String {
        aliases.first ?? title
    }

    var extraAliases: [String] {
        Array(aliases.dropFirst())
    }
}

typealias SignpostingCategory = SignpostCategory

struct PresentationPhrase: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var category: SignpostCategory
    var phrase: String
    var meaning: String
    var languageCode: String = "en"
    var isCustom: Bool = false

    var text: String { phrase }

    init(id: UUID = UUID(), category: SignpostCategory, phrase: String, meaning: String, languageCode: String = "en", isCustom: Bool = false) {
        self.id = id
        self.category = category
        self.phrase = phrase
        self.meaning = meaning
        self.languageCode = languageCode
        self.isCustom = isCustom
    }

    init(id: UUID = UUID(), category: SignpostCategory, text: String, meaning: String, languageCode: String = "en", isCustom: Bool = false) {
        self.init(id: id, category: category, phrase: text, meaning: meaning, languageCode: languageCode, isCustom: isCustom)
    }
}

struct PresentationCueCard: Identifiable, Equatable, Sendable {
    var id: String
    var index: Int
    var title: String
    var plannedMinutes: Double?
    var bodyLines: [String]
    var subNotes: [String]

    var targetMinutes: Double? { plannedMinutes }
    var targetSeconds: TimeInterval? { plannedSeconds }
    var lines: [String] { bodyLines }
    var nativeNotes: [String] { subNotes }

    var plannedSeconds: TimeInterval? {
        plannedMinutes.map { $0 * 60 }
    }
}

enum PostItColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case yellow
    case mint
    case pink
    case sky
    case lavender

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return "노랑 (기본)"
        case .mint: return "민트 (답변 완료)"
        case .pink: return "핑크 (핵심/중요)"
        case .sky: return "하늘 (후속 조치)"
        case .lavender: return "라벤더 (기술 질문)"
        }
    }
}

struct PresentationQuestionNote: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt: Date = Date()
    var slideNumber: Int? = nil
    var slideTitle: String? = nil
    var sourceLabel: String = "청중 질문"
    var questionText: String
    var translatedText: String? = nil
    var recommendedAnswer: String? = nil
    var recommendedAnswerLocal: String? = nil
    var recommendedAnswerAt: Date? = nil
    var answerMemo: String = ""
    var color: PostItColor = .yellow
    var isResolved: Bool = false
    var isPinned: Bool = false
    var autoCaptured: Bool = false
    var audioClip: AudioClipRecord? = nil
    var sourceSpanID: UUID? = nil
}

struct PresentationSession: Codable, Equatable, Sendable {
    static let starterTemplate = """
    # 오프닝 & 배경 [2분]
    - Thank you all for joining today.
    - Today I'll walk you through our key goals and progress.
    > 미소 유지, 첫 문장은 천천히 또박또박 시작하기

    # 핵심 성과 & 데이터 [5분]
    - We achieved a 35% reduction in latency across the pipeline.
    - Customer satisfaction improved significantly in Q3.
    > 수치(35%) 말할 때 잠시 멈추고 강조

    # 라이브 데모 [5분]
    - Let me switch over to a quick live demo to show how it works.
    - Notice how real-time updates appear immediately.
    > 화면 전환 전 청중 화면 확인

    # 요약 & Q&A [3분]
    - To wrap up, here are the three takeaways.
    - I'd be happy to take any questions now.
    > 질문 들어오면 상단 'Q&A 전환' 버튼 누르기
    """

    var targetMinutes: Int = 15
    var targetSeconds: TimeInterval { TimeInterval(max(1, targetMinutes) * 60) }
    var notesMarkdown: String = ""
    var activeCardIndex: Int = 0
    var checklist: [PresentationChecklistItem] = []
    var customPhrases: [PresentationPhrase] = []
    var elapsedSeconds: TimeInterval = 0
    var sectionElapsed: [String: TimeInterval] = [:]
    var inQAMode: Bool = false
    var cueCardFontSize: Double = 20
    var linkedDeckName: String? = nil
    var linkedDeckPath: String? = nil
    var linkedDeckNotesHash: String? = nil
    var linkedDeckSyncedAt: Date? = nil
    var questionNotes: [PresentationQuestionNote]? = nil

    var resolvedQuestionNotes: [PresentationQuestionNote] {
        questionNotes ?? []
    }

    static func notesFingerprint(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 14695981039346656037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    func clonedForNewRun() -> PresentationSession {
        var copy = self
        copy.activeCardIndex = 0
        copy.elapsedSeconds = 0
        copy.sectionElapsed = [:]
        copy.inQAMode = false
        copy.questionNotes = []
        copy.checklist = checklist.map { item in
            PresentationChecklistItem(
                id: UUID(),
                title: item.title,
                stageTag: item.stageTag,
                targetMinute: item.targetMinute,
                isChecked: false,
                autoMatched: false,
                manuallyOverridden: false,
                matchedAt: nil
            )
        }
        return copy
    }
}

enum PresentationNotesParser {
    /// Parses Markdown presentation notes into cue cards.
    /// - `# Section Title [2분]` or `## Section Title (2.5m)` / `[90s]` / `[1:30]` starts a new card.
    /// - Lines starting with `>` become `subNotes` (native intent / stage reminders).
    /// - Other non-empty lines become `bodyLines`.
    static func parse(_ markdown: String) -> [PresentationCueCard] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmedAll = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAll.isEmpty else { return [] }

        let rawLines = normalized.components(separatedBy: "\n")
        var cards: [PresentationCueCard] = []
        var currentTitle: String? = nil
        var currentMinutes: Double? = nil
        var currentBody: [String] = []
        var currentSubs: [String] = []

        func flush() {
            guard currentTitle != nil || !currentBody.isEmpty || !currentSubs.isEmpty else { return }
            let idx = cards.count
            let title = (currentTitle?.isEmpty == false ? currentTitle! : "섹션 \(idx + 1)")
            cards.append(PresentationCueCard(
                id: "card-\(idx)",
                index: idx,
                title: title,
                plannedMinutes: currentMinutes,
                bodyLines: currentBody,
                subNotes: currentSubs
            ))
            currentTitle = nil
            currentMinutes = nil
            currentBody = []
            currentSubs = []
        }

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "---" || trimmed == "***" {
                flush()
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                let headingBody = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                let parsed = parseHeading(headingBody)
                currentTitle = parsed.title
                currentMinutes = parsed.minutes
            } else if trimmed.hasPrefix(">") {
                let note = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !note.isEmpty { currentSubs.append(note) }
            } else {
                currentBody.append(trimmed)
            }
        }
        flush()
        return cards
    }

    static func parseHeading(_ raw: String) -> (title: String, minutes: Double?) {
        // Match trailing or inline [2분], (2.5분), [3m], [2 min], [90s], [1:30]
        let pattern = #"[\[\(]\s*(?:(\d+):(\d{1,2})|(\d+(?:\.\d+)?)\s*(분|m|min|mins|초|s|sec))\s*[\]\)]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let fullRange = Range(match.range, in: raw) else {
            return (raw.trimmingCharacters(in: .whitespaces), nil)
        }

        var minutes: Double?
        if let minRange = Range(match.range(at: 1), in: raw),
           let secRange = Range(match.range(at: 2), in: raw),
           let m = Double(raw[minRange]),
           let s = Double(raw[secRange]) {
            minutes = m + s / 60.0
        } else if let valRange = Range(match.range(at: 3), in: raw),
                  let unitRange = Range(match.range(at: 4), in: raw),
                  let value = Double(raw[valRange]) {
            let unit = raw[unitRange].lowercased()
            if unit == "초" || unit == "s" || unit == "sec" {
                minutes = value / 60.0
            } else {
                minutes = value
            }
        }

        var stripped = raw
        stripped.removeSubrange(fullRange)
        let title = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? raw : title, minutes)
    }
}

enum PresentationChecklistMatcher {
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "%"
        })
    }

    static func apply(
        transcript: String,
        to items: [PresentationChecklistItem],
        at date: Date = Date()
    ) -> (items: [PresentationChecklistItem], changed: Bool) {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return (items, false) }

        var updated = items
        var changed = false
        for idx in updated.indices {
            guard !updated[idx].manuallyOverridden, !updated[idx].isChecked else { continue }
            let matched = updated[idx].aliases.contains { alias in
                let needle = normalize(alias)
                return needle.count >= 2 && normalizedTranscript.contains(needle)
            }
            if matched {
                updated[idx].isChecked = true
                updated[idx].autoMatched = true
                updated[idx].matchedAt = date
                changed = true
            }
        }
        return (updated, changed)
    }
}

struct SpeakingPaceMetrics: Equatable, Sendable {
    enum Zone: String, Equatable, Sendable {
        case idle
        case slow
        case ideal
        case fast
    }

    var rate: Int
    var unitLabel: String
    var zone: Zone
    var guidance: String
}

enum SpeakingPaceCalculator {
    static func calculate(
        spans: [TranscriptSpan],
        referenceDate: Date = Date(),
        windowSeconds: TimeInterval = 30
    ) -> SpeakingPaceMetrics {
        let cutoff = referenceDate.addingTimeInterval(-windowSeconds)
        let presenterSpans = spans.filter { span in
            guard span.date >= cutoff && span.date <= referenceDate.addingTimeInterval(1) else { return false }
            let trimmed = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[Mac 재생음]") { return false }
            return !trimmed.isEmpty
        }

        guard !presenterSpans.isEmpty else {
            return SpeakingPaceMetrics(rate: 0, unitLabel: "WPM", zone: .idle, guidance: "발화 대기")
        }

        let cleaned = presenterSpans
            .map { $0.text.replacingOccurrences(of: "[마이크]", with: "").replacingOccurrences(of: "[Mac 재생음]", with: "") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return SpeakingPaceMetrics(rate: 0, unitLabel: "WPM", zone: .idle, guidance: "발화 대기")
        }

        let earliest = presenterSpans.map(\.date).min() ?? referenceDate
        let effectiveSeconds = max(10.0, min(windowSeconds, referenceDate.timeIntervalSince(earliest) + 3.0))

        var cjkCount = 0
        var totalLetters = 0
        for scalar in cleaned.unicodeScalars where CharacterSet.letters.contains(scalar) {
            totalLetters += 1
            if isCJK(scalar) { cjkCount += 1 }
        }

        let isMostlyCJK = totalLetters > 0 && Double(cjkCount) / Double(totalLetters) >= 0.4
        if isMostlyCJK {
            let charCount = cleaned.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            let cpm = Int((Double(charCount) / effectiveSeconds * 60.0).rounded())
            let zone: SpeakingPaceMetrics.Zone
            let guidance: String
            if cpm < 190 { zone = .slow; guidance = "차분함" }
            else if cpm <= 350 { zone = .ideal; guidance = "적정 속도" }
            else { zone = .fast; guidance = "약간 빠름 · 천천히" }
            return SpeakingPaceMetrics(rate: cpm, unitLabel: "자/분", zone: zone, guidance: guidance)
        } else {
            let words = cleaned
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .filter { $0.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) }
            let wpm = Int((Double(words.count) / effectiveSeconds * 60.0).rounded())
            let zone: SpeakingPaceMetrics.Zone
            let guidance: String
            if wpm < 95 { zone = .slow; guidance = "차분함" }
            else if wpm <= 155 { zone = .ideal; guidance = "적정 속도" }
            else { zone = .fast; guidance = "약간 빠름 · 천천히" }
            return SpeakingPaceMetrics(rate: wpm, unitLabel: "WPM", zone: zone, guidance: guidance)
        }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0xAC00...0xD7AF).contains(v)
            || (0x1100...0x11FF).contains(v)
            || (0x3040...0x30FF).contains(v)
            || (0x4E00...0x9FFF).contains(v)
    }
}

enum SignpostingCatalog {
    static func builtInPhrases(forLanguageCode code: String) -> [PresentationPhrase] {
        let short = LanguageCatalog.language(for: code)?.shortCode
            ?? code.split(separator: "-").first.map { String($0).lowercased() }
            ?? "en"
        return builtInPhrases(for: short)
    }

    static func builtInPhrases(for shortCode: String) -> [PresentationPhrase] {
        switch shortCode {
        case "ko":
            return [
                // 도입·훅
                PresentationPhrase(category: .opening, phrase: "혹시 지금 업무에서 가장 시간을 많이 빼앗는 병목이 무엇인지 생각해 보신 적 있으신가요?", meaning: "질문형 훅(Hook)으로 즉시 집중 유도", languageCode: "ko"),
                PresentationPhrase(category: .opening, phrase: "오늘 발표는 크게 세 가지 핵심 흐름으로 진행하겠습니다: 문제, 해결책, 그리고 실제 결과입니다.", meaning: "3단계 로드맵 예고 (What·So What·Now What)", languageCode: "ko"),
                PresentationPhrase(category: .opening, phrase: "질문은 발표 끝 Q&A 시간에 모아 받겠습니다.", meaning: "Q&A 진행 방식 안내", languageCode: "ko"),
                // 전환
                PresentationPhrase(category: .transition, phrase: "지금까지 배경을 살펴보았고, 이제 핵심 해결 전략으로 넘어가겠습니다.", meaning: "요약 후 다음 섹션 전환", languageCode: "ko"),
                PresentationPhrase(category: .transition, phrase: "이 흐름이 자연스럽게 다음 핵심 지표로 이어집니다.", meaning: "논리적 연결 전환", languageCode: "ko"),
                // 차트·데이터
                PresentationPhrase(category: .visuals, phrase: "화면 오른쪽 그래프의 상승 곡선에 주목해 주시기 바랍니다.", meaning: "시각 자료 시선 유도", languageCode: "ko"),
                PresentationPhrase(category: .visuals, phrase: "이 숫자를 체감하기 쉽게 말씀드리면, 전년 대비 40% 이상 단축된 수치입니다.", meaning: "수치의 맥락·의미 해석", languageCode: "ko"),
                // 강조·스토리
                PresentationPhrase(category: .emphasis, phrase: "오늘 발표에서 단 한 가지만 기억하셔야 한다면 바로 이 부분입니다.", meaning: "Rule of One 핵심 강조", languageCode: "ko"),
                PresentationPhrase(category: .emphasis, phrase: "실제 현장에서 겪은 짧은 사례를 하나 말씀드리겠습니다.", meaning: "스토리텔링으로 설득력 강화", languageCode: "ko"),
                // 데모·돌발
                PresentationPhrase(category: .demo, phrase: "이론 설명 대신 실제 동작 화면을 2분간 직접 보여드리겠습니다.", meaning: "라이브 데모 전환", languageCode: "ko"),
                PresentationPhrase(category: .demo, phrase: "Google Meet 화면에 제 슬라이드가 잘 보이시는지 잠깐 확인 부탁드립니다.", meaning: "Google Meet PPT 공유 확인", languageCode: "ko"),
                PresentationPhrase(category: .demo, phrase: "다음 슬라이드로 넘겼는데 화면 전환 지연이 있으면 채팅으로 알려주세요.", meaning: "원격 슬라이드 전환 딜레이 체크", languageCode: "ko"),
                PresentationPhrase(category: .demo, phrase: "잠시 로딩되는 동안 내부에서 어떤 처리가 일어나는지 먼저 설명드리겠습니다.", meaning: "데모 지연/돌발 상황 침착 대응", languageCode: "ko"),
                // 청중 참여
                PresentationPhrase(category: .engagement, phrase: "이 중에서 비슷한 문제를 직접 겪어보신 분은 잠깐 손을 들어주실 수 있을까요?", meaning: "중간 환기 · 거수 질문", languageCode: "ko"),
                PresentationPhrase(category: .engagement, phrase: "잠깐 멈춰서 여러분의 팀 상황이라면 어떨지 떠올려 보시겠습니까?", meaning: "청중 몰입 질문", languageCode: "ko"),
                // 시간·마무리
                PresentationPhrase(category: .timeControl, phrase: "시간 관계상 세부 수치는 생략하고 핵심 결론만 짚고 넘어가겠습니다.", meaning: "시간 부족 시 깔끔한 압축", languageCode: "ko"),
                PresentationPhrase(category: .timeControl, phrase: "처음에 드렸던 질문으로 돌아가 정리하자면, 오늘의 핵심은 세 가지입니다.", meaning: "오프닝과 연결하는 책갈피 마무리", languageCode: "ko"),
                // Q&A·대응
                PresentationPhrase(category: .qa, phrase: "핵심을 짚어주신 질문입니다. 제가 제대로 이해했는지 확인하면 ~에 대한 질문이 맞으실까요?", meaning: "질문 재확인 · 생각할 시간 확보", languageCode: "ko"),
                PresentationPhrase(category: .qa, phrase: "정확한 수치를 확인한 뒤 세션 직후에 바로 공유드리겠습니다.", meaning: "모르는 내용에 대한 신뢰감 있는 대응", languageCode: "ko"),
                PresentationPhrase(category: .qa, phrase: "매우 중요한 논점이라 시간 관계상 발표 직후 별도로 깊이 논의하면 좋겠습니다.", meaning: "긴/민감한 질문 오프라인 전환", languageCode: "ko")
            ]
        case "ja":
            return [
                // 도입·훅
                PresentationPhrase(category: .opening, phrase: "最初に一つ質問させてください。日々の業務で最も時間を奪っている課題は何でしょうか？", meaning: "질문형 오프닝 훅", languageCode: "ja"),
                PresentationPhrase(category: .opening, phrase: "本日は3つのパートに分けて、課題・解決策・成果の順でお話しします。", meaning: "3단계 로드맵 제시", languageCode: "ja"),
                // 전환
                PresentationPhrase(category: .transition, phrase: "ここまでの背景を踏まえて、次に具体的なアプローチへ移ります。", meaning: "배경 요약 후 자연스러운 전환", languageCode: "ja"),
                PresentationPhrase(category: .transition, phrase: "これがそのまま次の重要なポイントにつながります。", meaning: "다음 포인트 연결", languageCode: "ja"),
                // 차트·데이터
                PresentationPhrase(category: .visuals, phrase: "画面のグラフの右肩上がりのトレンドにご注目ください。", meaning: "차트 시선 유도", languageCode: "ja"),
                PresentationPhrase(category: .visuals, phrase: "分かりやすく言い換えると、前年比で大幅な改善を意味しています。", meaning: "데이터 의미 해석", languageCode: "ja"),
                // 강조·스토리
                PresentationPhrase(category: .emphasis, phrase: "本日たった一つだけ持ち帰っていただきたい点はこちらです。", meaning: "핵심 1가지 강조", languageCode: "ja"),
                PresentationPhrase(category: .emphasis, phrase: "ここで実際の現場で起きた短い事例をご紹介します。", meaning: "현장 스토리 전환", languageCode: "ja"),
                // 데모·돌발
                PresentationPhrase(category: .demo, phrase: "言葉で説明するより、実際の画面でデモをお見せします。", meaning: "라이브 데모 전환", languageCode: "ja"),
                PresentationPhrase(category: .demo, phrase: "読み込みを待つ間に、裏側で動いている仕組みをご説明します。", meaning: "로딩/돌발 시 시간 벌기", languageCode: "ja"),
                // 청중 참여
                PresentationPhrase(category: .engagement, phrase: "同じような課題を経験された方はいらっしゃいますか？", meaning: "중간 청중 참여 유도", languageCode: "ja"),
                // 시간·마무리
                PresentationPhrase(category: .timeControl, phrase: "時間の都合上、要点に絞って結論からお伝えします。", meaning: "시간 부족 시 핵심 압축", languageCode: "ja"),
                PresentationPhrase(category: .timeControl, phrase: "冒頭の問いに戻ってまとめますと、本日の要点は3つです。", meaning: "오프닝 회귀 마무리", languageCode: "ja"),
                // Q&A·대응
                PresentationPhrase(category: .qa, phrase: "鋭いご質問ありがとうございます。確認ですが、〜という観点でよろしいでしょうか？", meaning: "질문 재확인 · 여유 확보", languageCode: "ja"),
                PresentationPhrase(category: .qa, phrase: "正確な数値を確認のうえ、終了後すぐにご共有いたします。", meaning: "확인 후 회신", languageCode: "ja"),
                PresentationPhrase(category: .qa, phrase: "重要なテーマですので、終了後に個別で詳しくお話しさせてください。", meaning: "오프라인 논의로 정중히 유도", languageCode: "ja")
            ]
        case "zh":
            return [
                PresentationPhrase(category: .opening, phrase: "在开始之前，想先问大家一个问题：您每天花最多时间的瓶颈是什么？", meaning: "질문형 오프닝 훅", languageCode: "zh"),
                PresentationPhrase(category: .opening, phrase: "今天的分享分为三个部分：背景挑战、解决方案以及核心成果。", meaning: "3단계 로드맵 예고", languageCode: "zh"),
                PresentationPhrase(category: .transition, phrase: "了解了背景之后，接下来我们看看具体的解决方案。", meaning: "배경에서 해결책으로 전환", languageCode: "zh"),
                PresentationPhrase(category: .visuals, phrase: "请大家看屏幕上的图表，这条上升曲线非常值得关注。", meaning: "차트 시선 유도", languageCode: "zh"),
                PresentationPhrase(category: .emphasis, phrase: "如果今天只记住一个核心结论，那就是这一点。", meaning: "핵심 1가지 강조", languageCode: "zh"),
                PresentationPhrase(category: .demo, phrase: "与其只讲概念，不如直接通过实时演示带大家看实际效果。", meaning: "라이브 데모 전환", languageCode: "zh"),
                PresentationPhrase(category: .demo, phrase: "趁系统加载的几秒钟，我先介绍一下背后的处理流程。", meaning: "로딩 중 침착한 진행", languageCode: "zh"),
                PresentationPhrase(category: .engagement, phrase: "在座各位有多少人遇到过类似的情况？", meaning: "중간 청중 환기", languageCode: "zh"),
                PresentationPhrase(category: .timeControl, phrase: "由于时间关系，我直接总结最关键的三点收获。", meaning: "시간 단축 마무리", languageCode: "zh"),
                PresentationPhrase(category: .qa, phrase: "非常好的问题。为了确保准确理解，您是指……对吗？", meaning: "질문 재확인 · 시간 확보", languageCode: "zh"),
                PresentationPhrase(category: .qa, phrase: "这个问题很有深度，建议我们散会后单独详细探讨，以免耽误大家时间。", meaning: "오프라인 논의 전환", languageCode: "zh")
            ]
        default:
            return [
                // Opening & Hook (TED / Stanford GSB style)
                PresentationPhrase(category: .opening, phrase: "Imagine walking in on Monday morning and seeing your core metric drop overnight — that's where our story starts.", meaning: "스토리/시나리오 훅으로 즉시 몰입", languageCode: "en"),
                PresentationPhrase(category: .opening, phrase: "How many of you have ever lost hours to this exact bottleneck?", meaning: "질문형 오프닝 훅 (지루한 인사 대신)", languageCode: "en"),
                PresentationPhrase(category: .opening, phrase: "I've structured today's talk into three quick parts: the problem, our approach, and the measurable results.", meaning: "3단계 로드맵 예고 (What·So What·Now What)", languageCode: "en"),
                PresentationPhrase(category: .opening, phrase: "Feel free to jot down questions — we'll leave time for Q&A right at the end.", meaning: "Q&A 진행 규칙 안내", languageCode: "en"),
                // Smooth Transitions
                PresentationPhrase(category: .transition, phrase: "Now that we've seen the problem, let's turn our attention to the solution.", meaning: "앞 섹션 요약 후 자연스러운 전환", languageCode: "en"),
                PresentationPhrase(category: .transition, phrase: "This brings me nicely to my next point.", meaning: "매끄러운 다음 슬라이드 브리지", languageCode: "en"),
                PresentationPhrase(category: .transition, phrase: "Building on that insight, here is what we actually shipped.", meaning: "인사이트에서 실행 결과로 연결", languageCode: "en"),
                // Visuals & Data
                PresentationPhrase(category: .visuals, phrase: "If you look at the chart on the right, you'll notice a sharp inflection point here.", meaning: "차트 핵심 지점으로 시선 유도", languageCode: "en"),
                PresentationPhrase(category: .visuals, phrase: "To put these numbers into perspective, that's a 3x improvement year-over-year.", meaning: "수치의 체감 의미 해석", languageCode: "en"),
                PresentationPhrase(category: .visuals, phrase: "What this trend tells us is a clear correlation between speed and retention.", meaning: "그래프가 말하는 핵심 인사이트 정리", languageCode: "en"),
                // Emphasis & Story
                PresentationPhrase(category: .emphasis, phrase: "If there is just one takeaway you remember from today, let it be this.", meaning: "Rule of One 핵심 강조 (말한 뒤 2초 멈춤)", languageCode: "en"),
                PresentationPhrase(category: .emphasis, phrase: "Let me pause here for a second — this is the turning point.", meaning: "의도적 멈춤으로 집중도 끌어올리기", languageCode: "en"),
                PresentationPhrase(category: .emphasis, phrase: "Here's a quick real-world example that makes this concrete.", meaning: "추상 개념 → 구체 사례 전환", languageCode: "en"),
                // Live Demo & Glitch Recovery
                PresentationPhrase(category: .demo, phrase: "Rather than just talking about the theory, let me show you how it works live.", meaning: "이론 → 라이브 데모 전환", languageCode: "en"),
                PresentationPhrase(category: .demo, phrase: "Can everyone see my slides clearly on Meet before I jump in?", meaning: "Google Meet PPT 화면 공유 확인", languageCode: "en"),
                PresentationPhrase(category: .demo, phrase: "I just moved to the next slide — please let me know if there's any screen lag.", meaning: "원격 슬라이드 전환 지연 확인", languageCode: "en"),
                PresentationPhrase(category: .demo, phrase: "I see a question in the Meet chat — let me finish this slide and come right back to it.", meaning: "Meet 채팅/손들기 질문 매끄럽게 접수", languageCode: "en"),
                PresentationPhrase(category: .demo, phrase: "Bear with me for just a second while this loads — let me explain what's happening under the hood.", meaning: "데모 지연/로딩 시 침착하게 공백 메우기", languageCode: "en"),
                // Audience Engagement
                PresentationPhrase(category: .engagement, phrase: "Quick show of hands — who here has run into this in production?", meaning: "10~15분 지점 집중력 환기 질문", languageCode: "en"),
                PresentationPhrase(category: .engagement, phrase: "Take a second to think about how this would change your team's workflow.", meaning: "청중 자신에게 대입하도록 유도", languageCode: "en"),
                // Time Control & Closing
                PresentationPhrase(category: .timeControl, phrase: "In the interest of time, let me jump straight to the bottom line.", meaning: "시간 부족 시 핵심 결론으로 압축", languageCode: "en"),
                PresentationPhrase(category: .timeControl, phrase: "Coming back to the question I opened with, here are the three takeaways.", meaning: "오프닝과 수미상관(Bookending) 마무리", languageCode: "en"),
                PresentationPhrase(category: .timeControl, phrase: "Here is the one concrete next step I'd love for us to take this week.", meaning: "명확한 행동 촉구(CTA)로 마무리", languageCode: "en"),
                // Tough Q&A Handling
                PresentationPhrase(category: .qa, phrase: "That's a great question. If I understand correctly, you're asking about... — is that right?", meaning: "질문 재확인 + 답변 정리할 시간 벌기", languageCode: "en"),
                PresentationPhrase(category: .qa, phrase: "I see where you're coming from, though our data actually points to a slightly different dynamic.", meaning: "비판적 질문에 차분하고 전문적으로 응대", languageCode: "en"),
                PresentationPhrase(category: .qa, phrase: "I don't have that exact figure in front of me, but I'll verify and follow up right after.", meaning: "모르는 수치에 대한 솔직·신뢰 대응", languageCode: "en"),
                PresentationPhrase(category: .qa, phrase: "That's a nuanced topic — let's take it offline right after so we stay on schedule.", meaning: "긴 논쟁/범위 밖 질문 오프라인 전환", languageCode: "en"),
                PresentationPhrase(category: .qa, phrase: "We have time for one last question before we wrap up.", meaning: "Q&A 종료 주도권 유지", languageCode: "en")
            ]
        }
    }
}

// MARK: - Presentation Duration Profile & Smart Advisor (TED / Stanford GSB Frameworks)

struct PresentationDurationProfile: Equatable, Sendable {
    enum Tier: String, Equatable, Sendable {
        case lightning   // <= 5 min
        case standard    // 6...15 min (TED style)
        case deepDive    // 16+ min (Keynote / Workshop)
    }

    var tier: Tier
    var label: String
    var structureSummary: String
    var recommendedChecklistRange: ClosedRange<Int>
    var recommendedCategories: [SignpostCategory]
    var pacingTip: String

    static func profile(for targetMinutes: Int) -> PresentationDurationProfile {
        if targetMinutes <= 5 {
            return PresentationDurationProfile(
                tier: .lightning,
                label: "초단기 피치 (≤5분)",
                structureSummary: "훅 45초 → 핵심 근거 1개 2.5분 → 명확한 CTA 1분",
                recommendedChecklistRange: 3...4,
                recommendedCategories: [.opening, .emphasis, .timeControl],
                pacingTip: "긴 인사를 생략하고 핵심 메시지 1개(Rule of One) + 최강 근거 1개에 집중하세요."
            )
        } else if targetMinutes <= 15 {
            return PresentationDurationProfile(
                tier: .standard,
                label: "TED 스타일 표준 발표 (6~15분)",
                structureSummary: "도입 훅 2분 → 3대 핵심 포인트 9분 → 책갈피 마무리 2분 + Q&A",
                recommendedChecklistRange: 5...7,
                recommendedCategories: [.opening, .transition, .visuals, .emphasis, .timeControl, .qa],
                pacingTip: "데이터와 짧은 사례(스토리)를 번갈아 배치하고, 핵심 문장 뒤 2초 멈춤을 넣으세요."
            )
        } else {
            return PresentationDurationProfile(
                tier: .deepDive,
                label: "심층 키노트 · 워크숍 (16분+)",
                structureSummary: "1막 문제 제기 → 2막 프레임워크·데이터(중간 환기) → 3막 사례·데모·Q&A",
                recommendedChecklistRange: 7...9,
                recommendedCategories: [.opening, .transition, .visuals, .engagement, .demo, .emphasis, .timeControl, .qa],
                pacingTip: "12~15분마다 집중력이 떨어집니다. 중간에 청중 질문이나 데모로 리듬을 전환하세요."
            )
        }
    }
}

struct PresentationRecommendation: Equatable, Sendable {
    var checklist: [PresentationChecklistItem]
    var phrases: [PresentationPhrase]
    var rationale: String
    var isAIGenerated: Bool
}

struct ContextualSignpostSuggestion: Equatable, Sendable {
    var category: SignpostCategory
    var badge: String
    var reason: String
    var phrases: [PresentationPhrase]
}

enum PresentationAdvisor {
    /// Generates duration-appropriate practice starter checklist items grounded in TED / Stanford GSB structure.
    static func starterChecklist(for targetMinutes: Int) -> [PresentationChecklistItem] {
        let profile = PresentationDurationProfile.profile(for: targetMinutes)
        switch profile.tier {
        case .lightning:
            return [
                PresentationChecklistItem(title: "오프닝 훅 질문 / opening hook", stageTag: "도입·훅", targetMinute: 0),
                PresentationChecklistItem(title: "핵심 수치·근거 / key metric", stageTag: "핵심 근거", targetMinute: 2),
                PresentationChecklistItem(title: "명확한 다음 행동(CTA) / next step", stageTag: "마무리", targetMinute: max(3, targetMinutes - 1))
            ]
        case .standard:
            return [
                PresentationChecklistItem(title: "강력한 오프닝 훅 / hook / imagine", stageTag: "도입·훅", targetMinute: 1),
                PresentationChecklistItem(title: "3단계 로드맵 안내 / three parts / 세 가지", stageTag: "로드맵", targetMinute: 2),
                PresentationChecklistItem(title: "핵심 데이터·성과 수치 / percent / %", stageTag: "차트·데이터", targetMinute: max(4, targetMinutes / 3)),
                PresentationChecklistItem(title: "실제 사례 또는 데모 / example / demo / 사례", stageTag: "스토리·데모", targetMinute: max(6, targetMinutes * 2 / 3)),
                PresentationChecklistItem(title: "핵심 결론 1줄 요약 / takeaway / 핵심", stageTag: "강조", targetMinute: max(8, targetMinutes - 3)),
                PresentationChecklistItem(title: "오프닝 회귀 마무리 & Q&A / questions / 질문", stageTag: "마무리", targetMinute: max(9, targetMinutes - 1))
            ]
        case .deepDive:
            return [
                PresentationChecklistItem(title: "오프닝 훅 & 문제 제기 / hook / problem", stageTag: "1막·도입", targetMinute: 2),
                PresentationChecklistItem(title: "전체 로드맵 공유 / roadmap / agenda", stageTag: "로드맵", targetMinute: 4),
                PresentationChecklistItem(title: "핵심 프레임워크·데이터 / framework / data", stageTag: "2막·핵심", targetMinute: max(8, targetMinutes / 3)),
                PresentationChecklistItem(title: "중간 청중 참여 질문 / show of hands / 질문", stageTag: "중간 환기", targetMinute: max(12, targetMinutes / 2)),
                PresentationChecklistItem(title: "라이브 데모 또는 실제 적용 사례 / demo / case study", stageTag: "3막·적용", targetMinute: max(16, targetMinutes * 2 / 3)),
                PresentationChecklistItem(title: "예상 반론·한계 선제 대응 / trade-off / challenge", stageTag: "신뢰 확보", targetMinute: max(20, targetMinutes - 6)),
                PresentationChecklistItem(title: "3가지 핵심 요약 & CTA / takeaways / next step", stageTag: "마무리", targetMinute: max(24, targetMinutes - 3)),
                PresentationChecklistItem(title: "Q&A 전환 & 주도권 마무리 / questions / Q&A", stageTag: "Q&A", targetMinute: max(26, targetMinutes - 1))
            ]
        }
    }

    /// Zero-latency offline recommendation analyzing target duration + notes content (numbers, headings, demo/chart cues).
    static func instantRecommend(session: PresentationSession, languageCode: String) -> PresentationRecommendation {
        let profile = PresentationDurationProfile.profile(for: session.targetMinutes)
        let cards = PresentationNotesParser.parse(session.notesMarkdown)
        let notes = session.notesMarkdown
        let lowerNotes = notes.lowercased()

        var suggestedItems: [PresentationChecklistItem] = []
        var seenNorms = Set(session.checklist.map { PresentationChecklistMatcher.normalize($0.displayLabel) })

        func appendUnique(_ item: PresentationChecklistItem) {
            let key = PresentationChecklistMatcher.normalize(item.displayLabel)
            guard !key.isEmpty, !seenNorms.contains(key) else { return }
            seenNorms.insert(key)
            suggestedItems.append(item)
        }

        // 1. Extract concrete metrics / quarters / numbers from card body lines (ignoring heading duration tags like [2분]).
        let bodyTextForMetrics = cards.isEmpty ? notes : cards.flatMap(\.bodyLines).joined(separator: "\n")
        let metricPattern = #"(?:(?:\$|₩|€)\d+(?:[.,]\d+)?[KMBkmb]?|\d+(?:\.\d+)?\s*(?:%|percent|배|x|X|ms|초|분|명|건)|Q[1-4](?:\s*20\d{2})?)"#
        if let regex = try? NSRegularExpression(pattern: metricPattern) {
            let matches = regex.matches(in: bodyTextForMetrics, range: NSRange(bodyTextForMetrics.startIndex..., in: bodyTextForMetrics))
            for match in matches.prefix(3) {
                if let range = Range(match.range, in: bodyTextForMetrics) {
                    let token = String(bodyTextForMetrics[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard token.count >= 2 else { continue }
                    appendUnique(PresentationChecklistItem(
                        title: token,
                        stageTag: "핵심 수치"
                    ))
                }
            }
        }

        // 2. Add key section headings mapped to approximate minute marks.
        var cumulativeMinutes = 0.0
        let defaultSlice = cards.isEmpty ? Double(session.targetMinutes) : Double(session.targetMinutes) / Double(cards.count)
        for card in cards {
            let cleanTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanTitle.count >= 2 && suggestedItems.count < profile.recommendedChecklistRange.upperBound {
                let tag = card.index == 0 ? "도입" : (card.index == cards.count - 1 ? "마무리" : "섹션 \(card.index + 1)")
                appendUnique(PresentationChecklistItem(
                    title: cleanTitle,
                    stageTag: tag,
                    targetMinute: Int(cumulativeMinutes.rounded())
                ))
            }
            cumulativeMinutes += card.plannedMinutes ?? defaultSlice
        }

        // 3. Fill up to duration-appropriate count with TED / Stanford GSB practice items.
        if suggestedItems.count < profile.recommendedChecklistRange.lowerBound {
            for starter in starterChecklist(for: session.targetMinutes) {
                if suggestedItems.count >= profile.recommendedChecklistRange.lowerBound { break }
                appendUnique(starter)
            }
        }

        // 4. Select best-fit signposting phrases based on duration + detected content cues.
        var categories = profile.recommendedCategories
        if lowerNotes.contains("demo") || lowerNotes.contains("데모") || lowerNotes.contains("시연") || lowerNotes.contains("screen") {
            if !categories.contains(.demo) { categories.insert(.demo, at: min(2, categories.count)) }
        }
        if lowerNotes.contains("%") || lowerNotes.contains("chart") || lowerNotes.contains("graph") || lowerNotes.contains("그래프") || lowerNotes.contains("데이터") || lowerNotes.contains("지표") {
            if !categories.contains(.visuals) { categories.insert(.visuals, at: min(1, categories.count)) }
        }
        if lowerNotes.contains("q&a") || lowerNotes.contains("질문") || lowerNotes.contains("question") {
            if !categories.contains(.qa) { categories.append(.qa) }
        }

        let catalog = SignpostingCatalog.builtInPhrases(forLanguageCode: languageCode)
        var pickedPhrases: [PresentationPhrase] = []
        for cat in categories.prefix(5) {
            if let first = catalog.first(where: { $0.category == cat }) {
                pickedPhrases.append(first)
            }
        }

        let reason = "\(profile.label) 기준 · \(profile.structureSummary)"
        return PresentationRecommendation(
            checklist: Array(suggestedItems.prefix(profile.recommendedChecklistRange.upperBound)),
            phrases: pickedPhrases,
            rationale: reason,
            isAIGenerated: false
        )
    }

    /// Live context-aware signposting recommender: inspects active cue card + remaining time to surface
    /// the exact phrases needed *right now* during the talk.
    static func contextualLiveRecommendation(
        session: PresentationSession,
        cards: [PresentationCueCard],
        activeCardIndex: Int,
        languageCode: String
    ) -> ContextualSignpostSuggestion {
        let totalSecs = max(60.0, session.targetSeconds)
        let remaining = totalSecs - session.elapsedSeconds
        let progress = session.elapsedSeconds / totalSecs
        let catalog = SignpostingCatalog.builtInPhrases(forLanguageCode: languageCode)

        func pick(_ cat: SignpostCategory, badge: String, reason: String) -> ContextualSignpostSuggestion {
            let custom = session.customPhrases.filter { $0.category == cat }
            let builtIn = catalog.filter { $0.category == cat }
            return ContextualSignpostSuggestion(
                category: cat,
                badge: badge,
                reason: reason,
                phrases: Array((custom + builtIn).prefix(2))
            )
        }

        if session.inQAMode {
            return pick(.qa, badge: "Q&A 진행 중", reason: "질문 재확인 · 시간 확보 · 오프라인 전환 표현")
        }
        if session.elapsedSeconds > 15 && (remaining <= 90 || progress >= 0.82) {
            return pick(.timeControl, badge: "마무리 타이밍", reason: "남은 시간 20% 이하 · 깔끔한 요약·CTA 전환")
        }
        if session.targetMinutes >= 16 && progress >= 0.42 && progress <= 0.58 {
            return pick(.engagement, badge: "중간 집중력 환기", reason: "장시간 발표 중간 지점 · 청중 참여로 리듬 전환")
        }

        if cards.indices.contains(activeCardIndex) {
            let card = cards[activeCardIndex]
            let combined = (card.title + " " + card.bodyLines.joined(separator: " ")).lowercased()
            if combined.contains("q&a") || combined.contains("질문") || combined.contains("question") {
                return pick(.qa, badge: "현재 카드: Q&A", reason: "질의응답 시작 및 난처한 질문 대응")
            }
            if combined.contains("demo") || combined.contains("데모") || combined.contains("시연") || combined.contains("live") {
                return pick(.demo, badge: "현재 카드: 데모", reason: "라이브 데모 전환 및 로딩 지연 대처")
            }
            if combined.contains("%") || combined.contains("chart") || combined.contains("graph") || combined.contains("metric") || combined.contains("데이터") || combined.contains("성과") || combined.contains("지표") {
                return pick(.visuals, badge: "현재 카드: 데이터·지표", reason: "차트 시선 유도 및 수치 의미 강조")
            }
            if activeCardIndex == 0 {
                return pick(.opening, badge: "1번 카드 · 오프닝", reason: "강력한 훅(Hook)과 로드맵으로 시선 사로잡기")
            }
            if activeCardIndex == cards.count - 1 {
                return pick(.timeControl, badge: "마지막 카드 · 마무리", reason: "오프닝 회귀(Bookending) 및 핵심 3줄 정리")
            }
            return pick(.transition, badge: "섹션 \(activeCardIndex + 1) 전환", reason: "이전 내용 요약 후 자연스럽게 다음 포인트 연결")
        }

        return pick(.opening, badge: "발표 시작 추천", reason: "질문·사례 훅으로 도입 임팩트 강화")
    }

    static func parseAIRecommendationJSON(_ raw: String, languageCode: String, rationaleFallback: String) -> PresentationRecommendation? {
        var jsonText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```") {
            var lines = jsonText.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            jsonText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = jsonText.firstIndex(of: "{"), let end = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[start...end])
        }
        struct Payload: Decodable {
            struct CheckItem: Decodable {
                var title: String
                var stage: String?
                var minute: Int?
            }
            struct PhraseItem: Decodable {
                var category: String?
                var phrase: String
                var meaning: String?
            }
            var rationale: String?
            var checklist: [CheckItem]?
            var phrases: [PhraseItem]?
        }
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let items = (parsed.checklist ?? []).compactMap { entry -> PresentationChecklistItem? in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return PresentationChecklistItem(
                title: title,
                stageTag: entry.stage?.trimmingCharacters(in: .whitespacesAndNewlines),
                targetMinute: entry.minute
            )
        }
        let short = LanguageCatalog.language(for: languageCode)?.shortCode ?? "en"
        let phrases = (parsed.phrases ?? []).compactMap { entry -> PresentationPhrase? in
            let text = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PresentationPhrase(
                category: SignpostCategory.parseFlexible(entry.category ?? "transition"),
                phrase: text,
                meaning: entry.meaning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "AI 맞춤 전환구",
                languageCode: short,
                isCustom: true
            )
        }
        guard !items.isEmpty || !phrases.isEmpty else { return nil }
        return PresentationRecommendation(
            checklist: items,
            phrases: phrases,
            rationale: parsed.rationale?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? parsed.rationale!
                : rationaleFallback,
            isAIGenerated: true
        )
    }
}
