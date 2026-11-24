import Foundation
struct AzureTranslator {
    let key: String
    let region: String
    var session: URLSession = .shared
    func translate(_ text: String, target: String = "ko") async throws -> String {
        guard !key.isEmpty else { throw CloudFailure(message: "엔진 설정에서 Azure Translator 키를 저장해주세요.") }
        var request = URLRequest(url: URL(string: "https://api.cognitive.microsofttranslator.com/translate?api-version=2026-06-06")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !region.isEmpty { request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        // Omit source language: each phrase may switch between languages.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["inputs": [["text": text, "targets": [["language": target]]]]])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CloudFailure(message: "Azure 번역 실패 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). 키와 리전을 확인해주세요.")
        }
        return try Self.parse(data)
    }
    static func parse(_ data: Data) throws -> String {
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard let text = value.value.first?.translations.first?.text, !text.isEmpty else { throw CloudFailure(message: "Azure 번역 결과가 비어 있습니다.") }
        return text
    }
    private struct Envelope: Decodable { var value: [Item] }
    private struct Item: Decodable { var translations: [Translation] }
    private struct Translation: Decodable { var text: String }
}
