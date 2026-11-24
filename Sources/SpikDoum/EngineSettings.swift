import Foundation
import Security

enum STTEngine: String, Codable, CaseIterable { case apple, deepgram, managed }
enum TranslationEngine: String, Codable, CaseIterable { case apple, azure, local, managed }
enum LLMEngine: String, Codable, CaseIterable { case apple, openAI, compatible }
struct EngineSettings: Codable, Equatable {
    var stt: STTEngine = .apple
    var translation: TranslationEngine = .apple
    var llm: LLMEngine = .apple
    var serverURL = "http://localhost:11434/v1"
    var serverModel = "qwen3:8b"
    var cloudModel = "gpt-6-luna"
    var azureRegion = "koreacentral"
    var localTranslation = LocalTranslationSettings()
    init() {}
    private enum CodingKeys: String, CodingKey {
        case stt, translation, llm, serverURL, serverModel, cloudModel, azureRegion, localTranslation
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stt = try values.decodeIfPresent(STTEngine.self, forKey: .stt) ?? stt
        translation = try values.decodeIfPresent(TranslationEngine.self, forKey: .translation) ?? translation
        llm = try values.decodeIfPresent(LLMEngine.self, forKey: .llm) ?? llm
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL) ?? serverURL
        serverModel = try values.decodeIfPresent(String.self, forKey: .serverModel) ?? serverModel
        cloudModel = try values.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        azureRegion = try values.decodeIfPresent(String.self, forKey: .azureRegion) ?? azureRegion
        localTranslation = try values.decodeIfPresent(LocalTranslationSettings.self, forKey: .localTranslation) ?? localTranslation
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
