import Foundation

struct LLMClient {
    let settings: EngineSettings
    let key: String
    var session: URLSession = .shared

    func request(instructions: String, input: String, json: Bool = false) throws -> URLRequest {
        let isOpenAI = settings.llm == .openAI
        let base = isOpenAI ? "https://api.openai.com/v1" : settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw CloudFailure(message: "서버 주소는 http(s)://호스트:포트/v1 형태로 입력해주세요.")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [components.path, isOpenAI ? "responses" : "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw CloudFailure(message: "서버 주소가 올바르지 않습니다.") }
        if isOpenAI && key.isEmpty { throw CloudFailure(message: "엔진 설정에서 OpenAI API 키를 저장해주세요.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let model = isOpenAI ? settings.cloudModel : settings.serverModel
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure(message: "모델명을 입력해주세요.") }
        var body: [String: Any]
        if isOpenAI {
            body = ["model": model, "instructions": instructions, "input": input, "stream": true, "store": false, "max_output_tokens": json ? 1200 : 450,
                    "reasoning": ["effort": "none"]]
            if json { body["text"] = ["format": ["type": "json_object"]] }
        } else {
            body = ["model": model, "messages": [["role": "system", "content": instructions], ["role": "user", "content": input]], "stream": true, "max_tokens": json ? 1200 : 450]
            // JSON is requested in the prompt; avoid server-specific response_format support.
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func generate(instructions: String, input: String, json: Bool = false, onDelta: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String {
        let request = try request(instructions: instructions, input: input, json: json)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudFailure(message: "LLM 서버 요청 실패 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). 주소·키·모델명·사용 한도를 확인해주세요.")
        }
        var text = ""
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { completed = true; break }
            let event = try SSEPayload.decode(data)
            if let error = event.error { throw CloudFailure(message: error) }
            if let delta = event.delta { text += delta; await onDelta(text) }
            if event.done { completed = true; break }
        }
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudFailure(message: "LLM 응답이 비어 있거나 중간에 끊겼습니다. 서버 로그와 모델 설정을 확인해주세요.")
        }
        return text
    }
}
struct SSEPayload {
    var delta: String?
    var done = false
    var error: String?
    static func decode(_ string: String) throws -> Self {
        guard let data = string.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self() }
        let type = value["type"] as? String
        if type == "response.output_text.delta" { return Self(delta: value["delta"] as? String) }
        if type == "response.completed" { return Self(done: true) }
        if type == "response.failed" || type == "response.incomplete" || type == "error" || value["error"] != nil {
            return Self(error: "LLM 서버가 응답 생성 오류를 반환했습니다. 모델 지원 여부와 사용 한도를 확인해주세요.")
        }
        if let choices = value["choices"] as? [[String: Any]], let first = choices.first {
            let reason = first["finish_reason"] as? String
            let failure: String? = reason == "length" ? "응답 길이 제한에 도달했습니다." : reason == "content_filter" ? "응답이 안전 필터에 의해 중단되었습니다." : nil
            return Self(delta: (first["delta"] as? [String: Any])?["content"] as? String,
                        done: reason == "stop",
                        error: failure)
        }
        return Self()
    }
}
