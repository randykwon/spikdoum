import Foundation

struct LocalTranslationSettings: Codable, Equatable {
    var endpoint = "http://10.0.1.5:8848/v1/translate"
    var timeout: Double = 30
    var requestJSON = #"{"text":"{{text}}","source_lang":"{{source}}","target_lang":"{{target}}"}"#
    var responsePath = ""
}

struct LocalTranslator {
    let settings: LocalTranslationSettings
    let key: String
    var session: URLSession = .shared

    func request(text: String, source: String, target: String = "ko") throws -> URLRequest {
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw CloudFailure(message: "로컬 번역 주소를 http(s)://호스트:포트/v1/translate 형태로 입력해주세요.")
        }
        guard let template = settings.requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: template), object is [String: Any] else {
            throw CloudFailure(message: "로컬 번역 요청 JSON이 올바르지 않습니다. 서버 API 문서의 형식에 맞춰 입력해주세요.")
        }
        guard Self.containsTextPlaceholder(object) else {
            throw CloudFailure(message: "요청 JSON에 {{text}}를 넣어 원문이 전송되도록 설정해주세요.")
        }
        let values = ["{{text}}": text, "{{source}}": source, "{{target}}": target]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = min(120, max(5, settings.timeout))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.replace(object, values: values))
        return request
    }
    func translate(_ text: String, source: String, target: String = "ko") async throws -> String {
        let request = try request(text: text, source: source, target: target)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw CloudFailure(message: "로컬 번역 서버의 HTTP 응답을 확인하지 못했습니다.") }
            guard (200..<300).contains(http.statusCode) else {
                throw CloudFailure(message: "로컬 번역 HTTP \(http.statusCode). 주소·인증·요청 JSON을 서버 문서와 확인해주세요.")
            }
            return try Self.parse(data, path: settings.responsePath)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudFailure(message: "로컬 번역 응답 시간 초과. 서버 실행 상태·모델 로딩·내부망 연결을 확인해주세요.")
        }
    }
    static func parse(_ data: Data, path: String = "") throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw CloudFailure(message: "로컬 번역 서버가 JSON 응답을 반환하지 않았습니다.")
        }
        if let value = object as? [String: Any], let choices = value["choices"] as? [[String: Any]],
           let reason = choices.first?["finish_reason"] as? String, reason == "length" || reason == "content_filter" {
            throw CloudFailure(message: "번역 응답이 완료되지 않았습니다 (\(reason)). 불완전한 결과는 저장하지 않습니다.")
        }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = path.isEmpty ? ["translation", "translated_text", "translatedText", "data.translation", "data.translated_text", "translations.0.text", "choices.0.message.content", "output", "text"] : [path]
        let result: String?
        if path.isEmpty, let plain = object as? String { result = plain }
        else { result = paths.lazy.compactMap { lookup($0, in: object) as? String }.first }
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudFailure(message: "응답에서 번역 문자열을 찾지 못했습니다. 고급 설정의 응답 경로(예: translation, data.translation)를 서버 형식에 맞춰주세요.")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func lookup(_ path: String, in object: Any) -> Any? {
        var value: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dictionary = value as? [String: Any] { value = dictionary[component] }
            else if let array = value as? [Any], let index = Int(component), array.indices.contains(index) { value = array[index] }
            else { return nil }
        }
        return value
    }
    private static func containsTextPlaceholder(_ object: Any) -> Bool {
        if let text = object as? String { return text.contains("{{text}}") }
        if let array = object as? [Any] { return array.contains(where: containsTextPlaceholder) }
        if let dictionary = object as? [String: Any] { return dictionary.values.contains(where: containsTextPlaceholder) }
        return false
    }
    private static func replace(_ object: Any, values: [String: String]) -> Any {
        if let string = object as? String {
            // Substitute the template once so placeholders occurring inside the user's text stay literal.
            let pattern = #"\{\{(?:text|source|target)\}\}"#
            let regex = try! NSRegularExpression(pattern: pattern)
            var value = string
            for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
                guard let original = Range(match.range, in: string), let range = Range(match.range, in: value), let replacement = values[String(string[original])] else { continue }
                value.replaceSubrange(range, with: replacement)
            }
            return value
        }
        if let array = object as? [Any] { return array.map { replace($0, values: values) } }
        if let dictionary = object as? [String: Any] { return dictionary.mapValues { replace($0, values: values) } }
        return object
    }
}
