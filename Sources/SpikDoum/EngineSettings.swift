import Foundation
import Security

enum STTEngine: String, Codable, CaseIterable { case apple, deepgram, managed, parakeet }
enum TranslationEngine: String, Codable, CaseIterable { case apple, azure, local, managed }
enum LLMEngine: String, Codable, CaseIterable { case apple, managed, openAI, compatible }

enum LLMTaskRole: String, CaseIterable, Sendable {
    case coach
    case summary
    case keywords

    var title: String {
        switch self {
        case .coach: return "대화 코치"
        case .summary: return "대화 요약 · 스크립트"
        case .keywords: return "핵심 키워드"
        }
    }
}

/// Optional per-task LLM override allowing lightweight/fast engines for keywords or high-precision engines for summaries.
enum LLMTaskOverride: String, Codable, CaseIterable, Identifiable, Sendable {
    case followMain
    case apple
    case managed
    case openAI
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followMain: return "메인 LLM과 동일 (통합)"
        case .apple: return "Apple Intelligence (초경량)"
        case .managed: return "자체 로컬 LLM"
        case .openAI: return "OpenAI API"
        case .compatible: return "외부 로컬 서버"
        }
    }

    func resolved(fallback: LLMEngine) -> LLMEngine {
        switch self {
        case .followMain: return fallback
        case .apple: return .apple
        case .managed: return .managed
        case .openAI: return .openAI
        case .compatible: return .compatible
        }
    }
}

struct EngineSettings: Codable, Equatable {
    var stt: STTEngine = .apple
    var translation: TranslationEngine = .apple
    var llm: LLMEngine = .apple
    var keywordLLM: LLMTaskOverride = .followMain
    var summaryLLM: LLMTaskOverride = .followMain
    var serverURL = "http://localhost:11434/v1"
    var serverModel = "qwen3:8b"
    var cloudModel = "gpt-6-luna"
    var azureRegion = "koreacentral"
    var localTranslation = LocalTranslationSettings()
    init() {}
    private enum CodingKeys: String, CodingKey {
        case stt, translation, llm, keywordLLM, summaryLLM, serverURL, serverModel, cloudModel, azureRegion, localTranslation
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stt = try values.decodeIfPresent(STTEngine.self, forKey: .stt) ?? stt
        translation = try values.decodeIfPresent(TranslationEngine.self, forKey: .translation) ?? translation
        llm = try values.decodeIfPresent(LLMEngine.self, forKey: .llm) ?? llm
        keywordLLM = try values.decodeIfPresent(LLMTaskOverride.self, forKey: .keywordLLM) ?? keywordLLM
        summaryLLM = try values.decodeIfPresent(LLMTaskOverride.self, forKey: .summaryLLM) ?? summaryLLM
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL) ?? serverURL
        serverModel = try values.decodeIfPresent(String.self, forKey: .serverModel) ?? serverModel
        cloudModel = try values.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        azureRegion = try values.decodeIfPresent(String.self, forKey: .azureRegion) ?? azureRegion
        localTranslation = try values.decodeIfPresent(LocalTranslationSettings.self, forKey: .localTranslation) ?? localTranslation
    }

    func effectiveLLM(for task: LLMTaskRole) -> LLMEngine {
        switch task {
        case .coach: return llm
        case .keywords: return keywordLLM.resolved(fallback: llm)
        case .summary: return summaryLLM.resolved(fallback: llm)
        }
    }

    var usesAppleLLMForAnyTask: Bool {
        effectiveLLM(for: .coach) == .apple
            || effectiveLLM(for: .summary) == .apple
            || effectiveLLM(for: .keywords) == .apple
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "engineSettings"), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "engineSettings") } }
}
enum SecretStore {
    static let service = "dev.spikdoum.api"
    private static let legacyService = "dev.speakhelper.api"
    static func read(_ name: String) -> String {
        for candidate in [service, legacyService] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: candidate,
                                       kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return ""
    }
    static func write(_ value: String, name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let bytes = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            if update == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = bytes
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || (value.isEmpty && status == errSecItemNotFound) else { throw CaptureError.message("API 키 저장 실패 (\(status))") }
    }
}

struct CloudFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
