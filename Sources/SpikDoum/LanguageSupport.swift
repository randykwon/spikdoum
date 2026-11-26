import Foundation
import NaturalLanguage

enum ResolvedUILanguage: String, CaseIterable, Equatable, Sendable {
    case ko, en, ja, zhHans

    static func fromSystem() -> Self {
        for preferred in Locale.preferredLanguages {
            let lower = preferred.lowercased()
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("zh") { return .zhHans }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

enum AppInterfaceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system, ko, en, ja, zhHans
    var id: String { rawValue }

    var resolved: ResolvedUILanguage {
        switch self {
        case .system: return .fromSystem()
        case .ko: return .ko
        case .en: return .en
        case .ja: return .ja
        case .zhHans: return .zhHans
        }
    }

    func displayName(in ui: ResolvedUILanguage) -> String {
        switch self {
        case .system: return L10n.t("lang.system", lang: ui)
        case .ko: return "한국어 (Korean)"
        case .en: return "English"
        case .ja: return "日本語 (Japanese)"
        case .zhHans: return "简体中文 (Chinese)"
        }
    }
}

struct SupportedLanguage: Identifiable, Equatable, Hashable, Sendable {
    let code: String                // BCP-47 locale e.g. "en-US", "ko-KR", "zh-CN"
    let shortCode: String           // ISO 639-1 e.g. "en", "ko", "zh"
    let azureCode: String           // Azure Translator code e.g. "zh-Hans", "zh-Hant"
    let translationCode: String     // Apple Translation Locale.Language identifier
    let englishName: String
    let nativeName: String
    let koName: String
    let jaName: String
    let zhName: String

    var id: String { code }

    func displayName(in ui: ResolvedUILanguage) -> String {
        switch ui {
        case .ko: return koName
        case .en: return englishName
        case .ja: return jaName
        case .zhHans: return zhName
        }
    }
}

enum AutoLanguageMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Allows speakers to freely switch languages sentence-by-sentence (English ↔ Korean ↔ Japanese ↔ etc.).
    case multilingualSwitch
    /// Locks Whisper onto the detected language after 2 matching utterances for maximum monolingual speed.
    case singleLanguageFast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .multilingualSwitch: return "다국어 자유 전환 (권장)"
        case .singleLanguageFast: return "단일 언어 빠른 잠금"
        }
    }

    var description: String {
        switch self {
        case .multilingualSwitch: return "한 대화에서 여러 언어가 섞여 나와도 문장마다 자동 전환"
        case .singleLanguageFast: return "주 언어가 확인되면 고정해 추론 속도를 높임"
        }
    }
}

struct AutoLanguagePreferences: Codable, Equatable, Sendable {
    static let storageKey = "autoLanguagePreferencesV1"

    var mode: AutoLanguageMode = .multilingualSwitch
    /// Optional BCP-47 candidate language codes (e.g. ["en-US", "ko-KR", "ja-JP"]).
    /// Empty means unrestricted (all supported languages allowed).
    var preferredCodes: [String] = []

    mutating func toggleCandidate(_ code: String) {
        guard LanguageCatalog.language(for: code) != nil else { return }
        if let idx = preferredCodes.firstIndex(of: code) {
            preferredCodes.remove(at: idx)
        } else {
            preferredCodes.append(code)
        }
    }

    var shortSummary: String {
        guard !preferredCodes.isEmpty else { return "전체 언어" }
        return preferredCodes
            .compactMap { LanguageCatalog.language(for: $0)?.shortCode.uppercased() }
            .joined(separator: "·")
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

struct LanguageDetectionResult: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case whisperAcoustic
        case script
        case nlRecognizer
    }

    let language: SupportedLanguage
    let confidence: Double
    let source: Source
}

enum LanguageCatalog {
    static let autoCode = "auto"

    static let all: [SupportedLanguage] = [
        SupportedLanguage(code: "en-US", shortCode: "en", azureCode: "en", translationCode: "en", englishName: "English", nativeName: "English", koName: "영어", jaName: "英語", zhName: "英语"),
        SupportedLanguage(code: "ko-KR", shortCode: "ko", azureCode: "ko", translationCode: "ko", englishName: "Korean", nativeName: "한국어", koName: "한국어", jaName: "韓国語", zhName: "韩语"),
        SupportedLanguage(code: "ja-JP", shortCode: "ja", azureCode: "ja", translationCode: "ja", englishName: "Japanese", nativeName: "日本語", koName: "일본어", jaName: "日本語", zhName: "日语"),
        SupportedLanguage(code: "zh-CN", shortCode: "zh", azureCode: "zh-Hans", translationCode: "zh-Hans", englishName: "Chinese (Simplified)", nativeName: "中文(简体)", koName: "중국어(간체)", jaName: "中国語(簡体)", zhName: "中文(简体)"),
        SupportedLanguage(code: "zh-TW", shortCode: "zh", azureCode: "zh-Hant", translationCode: "zh-Hant", englishName: "Chinese (Traditional)", nativeName: "中文(繁體)", koName: "중국어(번체)", jaName: "中国語(繁体)", zhName: "中文(繁体)"),
        SupportedLanguage(code: "es-ES", shortCode: "es", azureCode: "es", translationCode: "es", englishName: "Spanish", nativeName: "Español", koName: "스페인어", jaName: "スペイン語", zhName: "西班牙语"),
        SupportedLanguage(code: "fr-FR", shortCode: "fr", azureCode: "fr", translationCode: "fr", englishName: "French", nativeName: "Français", koName: "프랑스어", jaName: "フランス語", zhName: "法语"),
        SupportedLanguage(code: "de-DE", shortCode: "de", azureCode: "de", translationCode: "de", englishName: "German", nativeName: "Deutsch", koName: "독일어", jaName: "ドイツ語", zhName: "德语"),
        SupportedLanguage(code: "pt-BR", shortCode: "pt", azureCode: "pt", translationCode: "pt", englishName: "Portuguese", nativeName: "Português", koName: "포르투갈어", jaName: "ポルトガル語", zhName: "葡萄牙语"),
        SupportedLanguage(code: "it-IT", shortCode: "it", azureCode: "it", translationCode: "it", englishName: "Italian", nativeName: "Italiano", koName: "이탈리아어", jaName: "イタリア語", zhName: "意大利语"),
        SupportedLanguage(code: "ru-RU", shortCode: "ru", azureCode: "ru", translationCode: "ru", englishName: "Russian", nativeName: "Русский", koName: "러시아어", jaName: "ロシア語", zhName: "俄语"),
        SupportedLanguage(code: "vi-VN", shortCode: "vi", azureCode: "vi", translationCode: "vi", englishName: "Vietnamese", nativeName: "Tiếng Việt", koName: "베트남어", jaName: "ベトナム語", zhName: "越南语"),
        SupportedLanguage(code: "th-TH", shortCode: "th", azureCode: "th", translationCode: "th", englishName: "Thai", nativeName: "ไทย", koName: "태국어", jaName: "タイ語", zhName: "泰语"),
        SupportedLanguage(code: "id-ID", shortCode: "id", azureCode: "id", translationCode: "id", englishName: "Indonesian", nativeName: "Bahasa Indonesia", koName: "인도네시아어", jaName: "インドネシア語", zhName: "印尼语"),
        SupportedLanguage(code: "hi-IN", shortCode: "hi", azureCode: "hi", translationCode: "hi", englishName: "Hindi", nativeName: "हिन्दी", koName: "힌디어", jaName: "ヒンディー語", zhName: "印地语"),
        SupportedLanguage(code: "ar-SA", shortCode: "ar", azureCode: "ar", translationCode: "ar", englishName: "Arabic", nativeName: "العربية", koName: "아랍어", jaName: "アラビア語", zhName: "阿拉伯语"),
        SupportedLanguage(code: "nl-NL", shortCode: "nl", azureCode: "nl", translationCode: "nl", englishName: "Dutch", nativeName: "Nederlands", koName: "네덜란드어", jaName: "オランダ語", zhName: "荷兰语"),
        SupportedLanguage(code: "tr-TR", shortCode: "tr", azureCode: "tr", translationCode: "tr", englishName: "Turkish", nativeName: "Türkçe", koName: "튀르키예어", jaName: "トルコ語", zhName: "土耳其语")
    ]

    static func language(for code: String) -> SupportedLanguage? {
        all.first { $0.code == code || $0.shortCode == code || $0.translationCode == code }
    }

    /// Maps Whisper `verbose_json` language identifiers (e.g. `"japanese"`, `"ja"`, `"korean"`, `"chinese"`, `"english"`)
    /// to a supported language entry.
    static func language(forWhisperName raw: String) -> SupportedLanguage? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "auto" else { return nil }
        if let direct = language(for: key) { return direct }
        switch key {
        case "english": return language(for: "en-US")
        case "korean": return language(for: "ko-KR")
        case "japanese": return language(for: "ja-JP")
        case "chinese", "mandarin", "cantonese": return language(for: "zh-CN")
        case "spanish": return language(for: "es-ES")
        case "french": return language(for: "fr-FR")
        case "german": return language(for: "de-DE")
        case "portuguese": return language(for: "pt-BR")
        case "italian": return language(for: "it-IT")
        case "russian": return language(for: "ru-RU")
        case "vietnamese": return language(for: "vi-VN")
        case "thai": return language(for: "th-TH")
        case "indonesian": return language(for: "id-ID")
        case "hindi": return language(for: "hi-IN")
        case "arabic": return language(for: "ar-SA")
        case "dutch": return language(for: "nl-NL")
        case "turkish": return language(for: "tr-TR")
        default: return nil
        }
    }

    static func whisperLanguageParameter(for code: String) -> String {
        if code == autoCode { return "auto" }
        return language(for: code)?.shortCode ?? String(code.prefix(2))
    }

    static func displayName(for code: String, in ui: ResolvedUILanguage) -> String {
        if code == autoCode { return L10n.t("lang.auto", lang: ui) }
        return language(for: code)?.displayName(in: ui) ?? code
    }

    static func nlLanguage(for code: String) -> NLLanguage? {
        switch code {
        case "en-US", "en": return .english
        case "ko-KR", "ko": return .korean
        case "ja-JP", "ja": return .japanese
        case "zh-CN", "zh-Hans": return .simplifiedChinese
        case "zh-TW", "zh-Hant": return .traditionalChinese
        case "es-ES", "es": return .spanish
        case "fr-FR", "fr": return .french
        case "de-DE", "de": return .german
        case "pt-BR", "pt": return .portuguese
        case "it-IT", "it": return .italian
        case "ru-RU", "ru": return .russian
        case "vi-VN", "vi": return .vietnamese
        case "th-TH", "th": return .thai
        case "id-ID", "id": return .indonesian
        case "hi-IN", "hi": return .hindi
        case "ar-SA", "ar": return .arabic
        case "nl-NL", "nl": return .dutch
        case "tr-TR", "tr": return .turkish
        default: return nil
        }
    }

    static func supportedLanguage(for nl: NLLanguage) -> SupportedLanguage? {
        switch nl {
        case .english: return language(for: "en-US")
        case .korean: return language(for: "ko-KR")
        case .japanese: return language(for: "ja-JP")
        case .simplifiedChinese: return language(for: "zh-CN")
        case .traditionalChinese: return language(for: "zh-TW")
        case .spanish: return language(for: "es-ES")
        case .french: return language(for: "fr-FR")
        case .german: return language(for: "de-DE")
        case .portuguese: return language(for: "pt-BR")
        case .italian: return language(for: "it-IT")
        case .russian: return language(for: "ru-RU")
        case .vietnamese: return language(for: "vi-VN")
        case .thai: return language(for: "th-TH")
        case .indonesian: return language(for: "id-ID")
        case .hindi: return language(for: "hi-IN")
        case .arabic: return language(for: "ar-SA")
        case .dutch: return language(for: "nl-NL")
        case .turkish: return language(for: "tr-TR")
        default: return nil
        }
    }

    /// Detects the spoken language of a transcript snippet while ignoring bracketed source labels
    /// such as `[마이크]` or `[Mac 재생음]`. Uses script-first heuristics for short & code-switched
    /// CJK/non-Latin utterances before falling back to constrained `NLLanguageRecognizer`.
    static func detectLanguage(for text: String, preferredCodes: [String] = []) -> SupportedLanguage? {
        detectLanguageDetailed(for: text, preferredCodes: preferredCodes)?.language
    }

    static func detectLanguageDetailed(for text: String, preferredCodes: [String] = []) -> LanguageDetectionResult? {
        let strippedLines = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                while trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                    trimmed = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
        let sample = strippedLines.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        // 1. Script-first detection handles 2-char CJK/non-Latin phrases & code-switching (e.g. "API 에러", "Q3 レビュー").
        var hangul = 0, kana = 0, han = 0, thai = 0, arabic = 0, devanagari = 0, cyrillic = 0, letters = 0
        for scalar in sample.unicodeScalars {
            let v = scalar.value
            if CharacterSet.letters.contains(scalar) { letters += 1 }
            if (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) { hangul += 1 }
            else if (0x3040...0x30FF).contains(v) { kana += 1 }
            else if (0x4E00...0x9FFF).contains(v) { han += 1 }
            else if (0x0E00...0x0E7F).contains(v) { thai += 1 }
            else if (0x0600...0x06FF).contains(v) { arabic += 1 }
            else if (0x0900...0x097F).contains(v) { devanagari += 1 }
            else if (0x0400...0x04FF).contains(v) { cyrillic += 1 }
        }

        if kana >= 1 && kana >= hangul, let ja = language(for: "ja-JP") {
            return LanguageDetectionResult(language: ja, confidence: 0.96, source: .script)
        }
        if hangul >= 2 || (hangul >= 1 && letters > 0 && Double(hangul) / Double(letters) >= 0.3), let ko = language(for: "ko-KR") {
            return LanguageDetectionResult(language: ko, confidence: 0.96, source: .script)
        }
        if thai >= 2, let th = language(for: "th-TH") {
            return LanguageDetectionResult(language: th, confidence: 0.96, source: .script)
        }
        if arabic >= 2, let ar = language(for: "ar-SA") {
            return LanguageDetectionResult(language: ar, confidence: 0.96, source: .script)
        }
        if devanagari >= 2, let hi = language(for: "hi-IN") {
            return LanguageDetectionResult(language: hi, confidence: 0.96, source: .script)
        }
        if cyrillic >= 2, let ru = language(for: "ru-RU") {
            return LanguageDetectionResult(language: ru, confidence: 0.95, source: .script)
        }
        if han >= 2 && hangul == 0 && kana == 0 {
            let prefersJA = preferredCodes.contains("ja-JP") && !preferredCodes.contains("zh-CN") && !preferredCodes.contains("zh-TW")
            if prefersJA, let ja = language(for: "ja-JP") {
                return LanguageDetectionResult(language: ja, confidence: 0.85, source: .script)
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
            recognizer.processString(sample)
            if let top = recognizer.dominantLanguage, let spec = supportedLanguage(for: top) {
                let conf = recognizer.languageHypotheses(withMaximum: 3)[top] ?? 0.85
                return LanguageDetectionResult(language: spec, confidence: max(0.75, conf), source: .nlRecognizer)
            }
            if let zh = language(for: "zh-CN") {
                return LanguageDetectionResult(language: zh, confidence: 0.80, source: .script)
            }
        }

        // 2. Latin-script phrases need >= 4 chars so tiny interjections like "ok" do not trigger noisy flips.
        guard sample.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        let constraints = preferredCodes.compactMap { nlLanguage(for: $0) }
        if !constraints.isEmpty {
            recognizer.languageConstraints = constraints
        }
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let dominant = recognizer.dominantLanguage,
              let spec = supportedLanguage(for: dominant) else { return nil }
        let confidence = hypotheses[dominant] ?? 0
        let minConfidence = constraints.isEmpty ? 0.35 : 0.25
        guard confidence >= minConfidence else { return nil }
        return LanguageDetectionResult(language: spec, confidence: confidence, source: .nlRecognizer)
    }

    /// Verifies that generated text (e.g., a summary) is actually written in the expected language.
    /// Small on-device LLMs sometimes drift into English when given English source text despite target-language instructions.
    static func matchesExpectedLanguage(_ text: String, expected: SupportedLanguage) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return true }
        switch expected.shortCode {
        case "ko":
            let hangulCount = trimmed.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            return hangulCount >= 3
        case "ja":
            let kanaCount = trimmed.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) }.count
            if kanaCount >= 2 { return true }
            return detectLanguage(for: trimmed)?.shortCode == "ja"
        case "zh":
            let cjkCount = trimmed.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
            let hangulOrKana = trimmed.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3040...0x30FF).contains($0.value) }.count
            return cjkCount >= 3 && hangulOrKana == 0
        default:
            guard let detected = detectLanguage(for: trimmed) else { return true }
            return detected.shortCode == expected.shortCode
        }
    }
}

enum L10n {
    static func t(_ key: String, lang: ResolvedUILanguage) -> String {
        if let table = strings[key], let value = table[lang] { return value }
        if let table = strings[key], let fallback = table[.en] ?? table[.ko] { return fallback }
        return key
    }

    private static let strings: [String: [ResolvedUILanguage: String]] = [
        "lang.system": [.ko: "시스템 기본", .en: "System Default", .ja: "システム設定", .zhHans: "跟随系统"],
        "lang.auto": [.ko: "자동 감지", .en: "Auto-Detect", .ja: "自動検出", .zhHans: "自动检测"],
        "app.tagline": [.ko: "대화에 집중하세요", .en: "Stay focused on the conversation", .ja: "会話に集中しましょう", .zhHans: "专注于对话"],
        "app.localStorageNotice": [.ko: "대화와 조언은 이 Mac에 저장됩니다.", .en: "Conversations and advice are stored locally on this Mac.", .ja: "会話とアドバイスはこのMacに保存されます。", .zhHans: "对话与建议均保存在本机。"],

        // Sidebar & Menu
        "menu.conversation": [.ko: "대화", .en: "Conversation", .ja: "会話", .zhHans: "对话"],
        "action.newConversation": [.ko: "새 대화", .en: "New Conversation", .ja: "新しい会話", .zhHans: "新对话"],
        "action.autoListenOnNew": [.ko: "새 대화 시 자동 듣기", .en: "Auto-listen on New", .ja: "新規会話で自動開始", .zhHans: "新建对话时自动开始监听"],
        "action.getAdviceNow": [.ko: "지금 조언 받기", .en: "Get Advice Now", .ja: "今すぐアドバイス", .zhHans: "立即获取建议"],
        "action.startListening": [.ko: "듣기 시작", .en: "Start Listening", .ja: "聞き取り開始", .zhHans: "开始监听"],
        "action.stopListening": [.ko: "듣기 중지", .en: "Stop Listening", .ja: "聞き取り停止", .zhHans: "停止监听"],
        "action.finishingAudio": [.ko: "마지막 음성 처리 중…", .en: "Finishing audio…", .ja: "最後の音声を処理中…", .zhHans: "正在处理最后音频…"],
        "action.preparingModel": [.ko: "모델 준비 중…", .en: "Preparing model…", .ja: "モデル準備中…", .zhHans: "正在准备模型…"],
        "action.checkingPermissions": [.ko: "권한 확인 중…", .en: "Checking permissions…", .ja: "権限を確認中…", .zhHans: "正在检查权限…"],
        "action.replay": [.ko: "다시 재생", .en: "Replay", .ja: "再生", .zhHans: "回放"],
        "action.replayMenu": [.ko: "대화 다시 재생…", .en: "Replay Conversation…", .ja: "会話を再生…", .zhHans: "回放对话…"],
        "action.exportMarkdown": [.ko: "Markdown 내보내기…", .en: "Export Markdown…", .ja: "Markdown書き出し…", .zhHans: "导出 Markdown…"],
        "action.restore": [.ko: "복원", .en: "Restore", .ja: "復元", .zhHans: "恢复"],
        "action.done": [.ko: "완료", .en: "Done", .ja: "完了", .zhHans: "完成"],
        "action.close": [.ko: "닫기", .en: "Close", .ja: "閉じる", .zhHans: "关闭"],
        "action.cancel": [.ko: "취소", .en: "Cancel", .ja: "キャンセル", .zhHans: "取消"],
        "action.copy": [.ko: "복사", .en: "Copy", .ja: "コピー", .zhHans: "复制"],
        "action.copied": [.ko: "복사됨", .en: "Copied", .ja: "コピー済み", .zhHans: "已复制"],

        // Tabs & Controls
        "tab.conversations": [.ko: "대화", .en: "Chats", .ja: "会話", .zhHans: "对话"],
        "tab.archive": [.ko: "아카이브", .en: "Archive", .ja: "アーカイブ", .zhHans: "归档"],
        "search.placeholder": [.ko: "대화 검색…", .en: "Search conversations…", .ja: "会話を検索…", .zhHans: "搜索对话…"],
        "select.multi": [.ko: "여러 개 선택", .en: "Select", .ja: "複数選択", .zhHans: "多选"],
        "select.done": [.ko: "선택 완료", .en: "Done", .ja: "選択完了", .zhHans: "完成选择"],
        "select.all": [.ko: "전체 선택", .en: "Select All", .ja: "すべて選択", .zhHans: "全选"],
        "select.none": [.ko: "선택 해제", .en: "Deselect", .ja: "選択解除", .zhHans: "取消全选"],

        // Top Live Bar & View Modes
        "live.header": [.ko: "실시간 대화", .en: "Live Conversation", .ja: "リアルタイム会話", .zhHans: "实时对话"],
        "range.all": [.ko: "전체 기록", .en: "All History", .ja: "全履歴", .zhHans: "全部记录"],
        "range.2min": [.ko: "최근 2분", .en: "Last 2 min", .ja: "直近2分", .zhHans: "最近2分钟"],
        "range.1min": [.ko: "최근 1분", .en: "Last 1 min", .ja: "直近1分", .zhHans: "最近1分钟"],
        "view.linked": [.ko: "연결 보기", .en: "Linked View", .ja: "連携表示", .zhHans: "联动视图"],
        "view.3panel": [.ko: "3패널 보기", .en: "Split View", .ja: "パネル表示", .zhHans: "分栏视图"],
        "reading.pause": [.ko: "읽기 고정", .en: "Freeze View", .ja: "表示固定", .zhHans: "锁定阅读"],
        "reading.resume": [.ko: "최신으로 이동", .en: "Jump to Live", .ja: "最新へ移動", .zhHans: "回到最新"],
        "reading.pausedReceiving": [.ko: "읽기 고정 · 새 내용 수신 중", .en: "Frozen · Receiving live updates", .ja: "表示固定 · 受信中", .zhHans: "已锁定 · 后台接收中"],
        "reading.paused": [.ko: "읽기 고정 중", .en: "View Frozen", .ja: "表示固定中", .zhHans: "阅读已锁定"],

        // Panels
        "panel.sttLive": [.ko: "LIVE · 대화 원문", .en: "LIVE · Transcript", .ja: "LIVE · 文字起こし", .zhHans: "LIVE · 实时转写"],
        "panel.stt": [.ko: "대화 원문", .en: "Transcript", .ja: "文字起こし", .zhHans: "对话原文"],
        "panel.translation": [.ko: "번역", .en: "Translation", .ja: "翻訳", .zhHans: "翻译"],
        "panel.coach": [.ko: "대화 코치", .en: "Coach", .ja: "会話コーチ", .zhHans: "对话助手"],
        "panel.summary": [.ko: "대화 요약", .en: "Summary", .ja: "会話要約", .zhHans: "对话摘要"],
        "panel.fullScript": [.ko: "전체 스크립트", .en: "Full Script", .ja: "全体スクリプト", .zhHans: "完整文稿"],
        "panel.summaryScriptToggle": [.ko: "요약 · 전체 스크립트 패널", .en: "Summary & Script Panel", .ja: "要約・スクリプトパネル", .zhHans: "摘要与文稿面板"],
        "panel.coachWindow": [.ko: "작은 조언창", .en: "Floating Coach", .ja: "フローティングコーチ", .zhHans: "悬浮建议窗"],
        "panel.toggleSidebarShow": [.ko: "대화 목록 펼치기", .en: "Show Sidebar", .ja: "サイドバーを表示", .zhHans: "展开对话列表"],
        "panel.toggleSidebarHide": [.ko: "대화 목록 접기", .en: "Hide Sidebar", .ja: "サイドバーを隠す", .zhHans: "收起对话列表"],
        "panel.focus": [.ko: "집중 모드", .en: "Focus Mode", .ja: "集中モード", .zhHans: "专注模式"],
        "panel.restoreLayout": [.ko: "화면 복원", .en: "Restore Layout", .ja: "表示を戻す", .zhHans: "恢复布局"],
        "panel.resetOrder": [.ko: "패널 순서 초기화", .en: "Reset Panel Order", .ja: "パネル順をリセット", .zhHans: "重置面板顺序"],
        "panel.moveLeft": [.ko: "왼쪽으로 이동", .en: "Move Left", .ja: "左へ移動", .zhHans: "向左移动"],
        "panel.moveRight": [.ko: "오른쪽으로 이동", .en: "Move Right", .ja: "右へ移動", .zhHans: "向右移动"],
        "panel.swapVertical": [.ko: "요약 · 스크립트 상하 전환", .en: "Swap Summary / Script Vertically", .ja: "要約・スクリプトの上下入替", .zhHans: "上下互换摘要与文稿"],
        "panel.dragHint": [.ko: "드래그하여 다른 패널 위치로 이동", .en: "Drag to reorder this panel", .ja: "ドラッグしてパネル位置を移動", .zhHans: "拖动以调整面板位置"],

        // Keywords & Summary & Script
        "keywords.accumulated": [.ko: "누적 대화 키워드", .en: "Keywords", .ja: "累積キーワード", .zhHans: "累计关键词"],
        "keywords.recent": [.ko: "최근 대화 키워드", .en: "Recent Keywords", .ja: "直近キーワード", .zhHans: "近期关键词"],
        "summary.all": [.ko: "전체 요약", .en: "Overall", .ja: "全体要約", .zhHans: "整体摘要"],
        "summary.speakers": [.ko: "화자별", .en: "Speakers", .ja: "話者別", .zhHans: "按说话人"],
        "summary.history": [.ko: "이력", .en: "History", .ja: "履歴", .zhHans: "历史"],
        "summary.refresh": [.ko: "갱신", .en: "Refresh", .ja: "更新", .zhHans: "刷新"],
        "script.polishAI": [.ko: "AI 문단 정리", .en: "AI Polish", .ja: "AI段落整理", .zhHans: "AI 段落整理"],
        "script.polishContinue": [.ko: "이어 정리", .en: "Update Polish", .ja: "続きを整理", .zhHans: "继续整理"],
        "script.polishRedo": [.ko: "다시 정리", .en: "Re-polish", .ja: "再整理", .zhHans: "重新整理"],
        "script.mode.organized": [.ko: "문단 정리", .en: "Polished", .ja: "段落整理", .zhHans: "段落整理"],
        "script.mode.bilingual": [.ko: "원문+번역", .en: "Bilingual", .ja: "原文+翻訳", .zhHans: "原文+翻译"],
        "script.mode.translated": [.ko: "번역만", .en: "Translated", .ja: "翻訳のみ", .zhHans: "仅翻译"],
        "script.mode.original": [.ko: "원문만", .en: "Original", .ja: "原文のみ", .zhHans: "仅原文"],

        // Settings
        "settings.title": [.ko: "앱 설정", .en: "Settings", .ja: "設定", .zhHans: "设置"],
        "settings.captureTitle": [.ko: "듣기 설정", .en: "Capture Settings", .ja: "聞き取り設定", .zhHans: "监听设置"],
        "settings.uiLanguage": [.ko: "앱 표시 언어", .en: "Interface Language", .ja: "表示言語", .zhHans: "界面语言"],
        "settings.sourceLanguage": [.ko: "STT 인식 언어", .en: "STT Speech Language", .ja: "STT 音声認識言語", .zhHans: "STT 语音识别语言"],
        "settings.sttMode": [.ko: "STT 언어 방식", .en: "STT Language Mode", .ja: "STT 言語モード", .zhHans: "STT 语言模式"],
        "stt.mode.auto": [.ko: "자동 인식", .en: "Auto-Detect", .ja: "自動認識", .zhHans: "自动识别"],
        "stt.mode.fixed": [.ko: "언어 지정", .en: "Specific Language", .ja: "言語を指定", .zhHans: "指定语言"],
        "settings.targetLanguage": [.ko: "번역 · 조언 언어 (내 언어)", .en: "Output Language", .ja: "翻訳・アドバイス言語", .zhHans: "翻译与建议语言"],
        "settings.presets": [.ko: "추천 설정", .en: "Quick Presets", .ja: "おすすめ設定", .zhHans: "推荐预设"],
        "settings.goalPlaceholder": [.ko: "이번 대화의 목표", .en: "Conversation goal", .ja: "この会話の目標", .zhHans: "本次对话目标"],
        "settings.recordAudio": [.ko: "다시 재생용 원본 음성 함께 녹음 (.m4a · 이 Mac에만 저장)", .en: "Record original audio for replay (.m4a · stored locally)", .ja: "再生用に音声を録音 (.m4a・ローカル保存)", .zhHans: "同时录制原声用于回放（.m4a · 仅存本机）"],
        "settings.autoStartNew": [.ko: "새 대화를 누르면 자동으로 듣기 시작", .en: "Automatically start listening on New Conversation", .ja: "新しい会話の作成時に自動で聞き取り開始", .zhHans: "点击新对话时自动开始监听"],

        // Tray
        "tray.quickMode": [.ko: "빠른 모드 전환", .en: "Quick Presets", .ja: "クイック切替", .zhHans: "快速模式"],
        "tray.openMain": [.ko: "메인 창 열기", .en: "Open Window", .ja: "メイン画面を開く", .zhHans: "打开主窗口"],
        "tray.recent": [.ko: "최근 대화", .en: "Recent", .ja: "最近の会話", .zhHans: "最近对话"],
        "tray.launchAtLogin": [.ko: "Mac 로그인 시 자동 실행", .en: "Launch at Login", .ja: "ログイン時に自動起動", .zhHans: "登录 Mac 时自动启动"],
        "tray.quit": [.ko: "SpikDoum 종료", .en: "Quit SpikDoum", .ja: "SpikDoumを終了", .zhHans: "退出 SpikDoum"],
        "preset.youtube": [.ko: "유튜브", .en: "YouTube", .ja: "YouTube", .zhHans: "YouTube"],
        "preset.inPerson": [.ko: "대면 대화", .en: "In-Person", .ja: "対面会話", .zhHans: "面对面"],

        // Replay
        "replay.play": [.ko: "재생", .en: "Play", .ja: "再生", .zhHans: "播放"],
        "replay.pause": [.ko: "일시정지", .en: "Pause", .ja: "一時停止", .zhHans: "暂停"],
        "replay.openFolder": [.ko: "녹음 폴더 열기", .en: "Open Recordings", .ja: "録音フォルダ", .zhHans: "打开录音文件夹"],
        "replay.markers": [.ko: "주요 시점", .en: "Markers", .ja: "タイムライン", .zhHans: "关键节点"]
    ]
}
