import Foundation

struct ManagedSTTClient {
    let key: String
    var session: URLSession = .shared
    static func wave(pcm: Data, sampleRate: UInt32 = 16000) -> Data {
        var result = Data()
        func string(_ value: String) { result.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        string("RIFF"); number(UInt32(pcm.count + 36)); string("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(sampleRate); number(sampleRate * 2); number(UInt16(2)); number(UInt16(16)); string("data"); number(UInt32(pcm.count)); result.append(pcm)
        return result
    }
    func request(wave: Data, language: String, prompt: String = "") -> URLRequest {
        let boundary = "SpikDoum-" + UUID().uuidString
        var request = URLRequest(url: ManagedRole.stt.baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let sttLang = LanguageCatalog.whisperLanguageParameter(for: language)
        var fields: [(String, String)] = [
            ("response_format", "json"),
            ("language", sttLang),
            ("temperature", "0"),
            ("no_speech_thold", "0.65")
        ]
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            fields.append(("prompt", String(trimmedPrompt.suffix(120))))
        }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wave); append("\r\n--\(boundary)--\r\n"); request.httpBody = body
        return request
    }
    func transcribe(wave: Data, language: String, prompt: String = "") async throws -> String {
        let (data, response) = try await session.data(for: request(wave: wave, language: language, prompt: prompt))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudFailure(message: "자체 STT 서버 응답 오류 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). 모델 관리에서 상태를 확인해주세요.") }
        struct Result: Decodable { var text: String }
        return try JSONDecoder().decode(Result.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
