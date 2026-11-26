import SwiftUI

/// 5-stage Speed ↔ Accuracy selector for both STT and Translation.
enum SpeedQualityTier: Int, CaseIterable, Identifiable, Codable, Sendable {
    case ultraFast = 1
    case fast = 2
    case balanced = 3
    case accurate = 4
    case maxAccuracy = 5

    static let sttStorageKey = "sttSpeedQualityTierV1"
    static let translationStorageKey = "translationSpeedQualityTierV1"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ultraFast: return "초신속"
        case .fast: return "신속"
        case .balanced: return "비교적 정확"
        case .accurate: return "정확"
        case .maxAccuracy: return "최고 정확"
        }
    }

    var shortBadge: String {
        switch self {
        case .ultraFast: return "1·초신속"
        case .fast: return "2·신속"
        case .balanced: return "3·비교적 정확"
        case .accurate: return "4·정확"
        case .maxAccuracy: return "5·최고정확"
        }
    }

    var icon: String {
        switch self {
        case .ultraFast: return "bolt.fill"
        case .fast: return "hare.fill"
        case .balanced: return "scale.3d"
        case .accurate: return "checkmark.seal.fill"
        case .maxAccuracy: return "crown.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .ultraFast: return .orange
        case .fast: return .teal
        case .balanced: return .blue
        case .accurate: return .indigo
        case .maxAccuracy: return .purple
        }
    }

    var sttSummary: String {
        switch self {
        case .ultraFast: return "Parakeet ANE / Apple 실시간 · 최저 지연 (~0.1~0.4초)"
        case .fast: return "Parakeet ANE / Whisper Base · 0.45초 실시간 스트리밍"
        case .balanced: return "Whisper Small · 0.55초 실시간 스트리밍 (균형)"
        case .accurate: return "Whisper Large v3 Turbo Q5 · 0.65초 스트리밍 (추천)"
        case .maxAccuracy: return "Whisper Large v3 Q5 · 고정밀 문장 단위 인식"
        }
    }

    var translationSummary: String {
        switch self {
        case .ultraFast: return "Apple 기기 내 번역 (~30ms 즉시 출력)"
        case .fast: return "Qwen2.5 0.5B Q4 · 초고속 스트리밍 번역"
        case .balanced: return "Qwen2.5 1.5B Q4 · 빠르고 자연스러운 번역"
        case .accurate: return "Qwen3 4B Q4 · 고정밀 문맥 번역 (추천)"
        case .maxAccuracy: return "대형/최고품질 로컬 번역 모델 (Qwen3 4B~12B)"
        }
    }

    /// Whisper `-ac` (audio context frames, 50 frames = 1 second).
    /// Using 384~768 instead of default 0 (1500 frames / 30s) cuts M5 Metal encoding latency by 2.5–3.5×.
    var whisperAudioContext: Int {
        switch self {
        case .ultraFast, .fast, .balanced: return 384   // ~7.68s context
        case .accurate: return 512                       // ~10.24s context
        case .maxAccuracy: return 768                    // ~15.36s context
        }
    }

    var whisperBestOf: Int {
        self == .maxAccuracy ? 2 : 1
    }

    /// Sliding-window interim streaming interval for local Whisper.
    /// `nil` disables interim polling in max-accuracy mode so full utterances are decoded cleanly.
    var whisperStreamingInterval: TimeInterval? {
        switch self {
        case .ultraFast: return 0.28
        case .fast: return 0.35
        case .balanced: return 0.45
        case .accurate: return 0.55
        case .maxAccuracy: return nil
        }
    }

    var preferredWhisperModelIDs: [String] {
        switch self {
        case .ultraFast:
            return ["whisper-tiny", "whisper-base", "whisper-small", "whisper-large-v3-turbo-q5"]
        case .fast:
            return ["whisper-base", "whisper-tiny", "whisper-small", "whisper-large-v3-turbo-q5"]
        case .balanced:
            return ["whisper-small", "whisper-medium-q5", "whisper-large-v3-turbo-q5", "whisper-base"]
        case .accurate:
            return ["whisper-large-v3-turbo-q5", "whisper-large-v3-turbo-q8", "whisper-large-v3-turbo", "whisper-small"]
        case .maxAccuracy:
            return ["whisper-large-v3-q5", "whisper-large-v3-turbo", "whisper-large-v3-turbo-q8", "whisper-large-v3-turbo-q5"]
        }
    }

    var preferredTranslationModelIDs: [String] {
        switch self {
        case .ultraFast:
            return [] // Always uses native Apple Translation (~30ms)
        case .fast:
            return ["qwen25-05b-q4", "qwen25-15b-q4", "qwen3-4b-q4"]
        case .balanced:
            return ["qwen25-15b-q4", "gemma2-2b-q4", "qwen3-17b-q8", "qwen25-05b-q4"]
        case .accurate:
            return ["qwen3-4b-q4", "qwen3-17b-q8", "gemma2-2b-q4", "qwen25-15b-q4"]
        case .maxAccuracy:
            return ["gemma3-12b-q4", "qwen3-8b-q4", "qwen3-4b-q4", "qwen3-17b-q8"]
        }
    }

    /// Languages supported natively by NVIDIA Parakeet TDT v3 (25 European languages).
    static let parakeetSupportedShortCodes: Set<String> = [
        "en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru",
        "sk", "sl", "es", "sv", "uk"
    ]

    static func supportsParakeet(languageCode: String, preferredAutoCodes: [String] = []) -> Bool {
        if languageCode == LanguageCatalog.autoCode {
            // In auto mode, Parakeet TDT v3 is safe when the user explicitly constrained candidates to European languages only.
            guard !preferredAutoCodes.isEmpty else { return false }
            return preferredAutoCodes.allSatisfy { supportsParakeet(languageCode: $0) }
        }
        let short = LanguageCatalog.language(for: languageCode)?.shortCode
            ?? languageCode.split(separator: "-").first.map { String($0).lowercased() }
            ?? ""
        return parakeetSupportedShortCodes.contains(short)
    }

    struct ResolvedSTTPlan: Equatable, Sendable {
        var engine: STTEngine
        var managedModelID: String?
        var streamingInterval: TimeInterval?
        var audioContext: Int
        var bestOf: Int
        var reason: String
    }

    struct ResolvedTranslationPlan: Equatable, Sendable {
        var engine: TranslationEngine
        var managedModelID: String?
        var reason: String
    }

    func resolveSTTPlan(
        languageCode: String,
        installedWhisperIDs: Set<String>,
        parakeetReady: Bool,
        appleModernReady: Bool
    ) -> ResolvedSTTPlan {
        let canUseParakeet = parakeetReady && Self.supportsParakeet(languageCode: languageCode)
        let bestWhisper = preferredWhisperModelIDs.first { installedWhisperIDs.contains($0) }

        switch self {
        case .ultraFast:
            if canUseParakeet {
                return ResolvedSTTPlan(engine: .parakeet, managedModelID: nil, streamingInterval: 0.25, audioContext: whisperAudioContext, bestOf: 1, reason: "Parakeet ANE 초저지연")
            }
            // Apple STT does not support multilingual "auto" detection; use ultra-fast Whisper (~60–130ms) instead.
            if languageCode == LanguageCatalog.autoCode, let modelID = bestWhisper {
                return ResolvedSTTPlan(engine: .managed, managedModelID: modelID, streamingInterval: whisperStreamingInterval, audioContext: whisperAudioContext, bestOf: 1, reason: "다국어 자동 인식 초고속 Whisper")
            }
            if appleModernReady || bestWhisper == nil {
                return ResolvedSTTPlan(engine: .apple, managedModelID: nil, streamingInterval: nil, audioContext: whisperAudioContext, bestOf: 1, reason: appleModernReady ? "Apple 실시간 스트리밍" : "Apple 기기 내 STT")
            }
            return ResolvedSTTPlan(engine: .managed, managedModelID: bestWhisper, streamingInterval: whisperStreamingInterval, audioContext: whisperAudioContext, bestOf: 1, reason: "Whisper 초고속 스트리밍")

        case .fast:
            if canUseParakeet {
                return ResolvedSTTPlan(engine: .parakeet, managedModelID: nil, streamingInterval: 0.40, audioContext: whisperAudioContext, bestOf: 1, reason: "Parakeet ANE 고속")
            }
            if let modelID = bestWhisper {
                return ResolvedSTTPlan(engine: .managed, managedModelID: modelID, streamingInterval: whisperStreamingInterval, audioContext: whisperAudioContext, bestOf: 1, reason: "Whisper 고속 스트리밍")
            }
            return ResolvedSTTPlan(engine: .apple, managedModelID: nil, streamingInterval: nil, audioContext: whisperAudioContext, bestOf: 1, reason: "Apple STT")

        case .balanced, .accurate, .maxAccuracy:
            if let modelID = bestWhisper {
                return ResolvedSTTPlan(engine: .managed, managedModelID: modelID, streamingInterval: whisperStreamingInterval, audioContext: whisperAudioContext, bestOf: whisperBestOf, reason: title)
            }
            return ResolvedSTTPlan(engine: .apple, managedModelID: nil, streamingInterval: nil, audioContext: whisperAudioContext, bestOf: 1, reason: "설치된 Whisper 모델 없음 · Apple 폴백")
        }
    }

    func resolveTranslationPlan(installedTranslationIDs: Set<String>) -> ResolvedTranslationPlan {
        if self == .ultraFast {
            return ResolvedTranslationPlan(engine: .apple, managedModelID: nil, reason: "Apple 기기 내 즉시 번역")
        }
        if let modelID = preferredTranslationModelIDs.first(where: { installedTranslationIDs.contains($0) }) {
            return ResolvedTranslationPlan(engine: .managed, managedModelID: modelID, reason: title)
        }
        return ResolvedTranslationPlan(engine: .apple, managedModelID: nil, reason: "설치된 자체 모델 없음 · Apple 번역")
    }

    static func loadSTT(defaults: UserDefaults = .standard) -> Self {
        let raw = defaults.integer(forKey: sttStorageKey)
        return Self(rawValue: raw) ?? .accurate
    }

    static func loadTranslation(defaults: UserDefaults = .standard) -> Self {
        let raw = defaults.integer(forKey: translationStorageKey)
        return Self(rawValue: raw) ?? .ultraFast
    }

    func saveSTT(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.sttStorageKey)
    }

    func saveTranslation(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.translationStorageKey)
    }
}
