import Foundation
import Testing
@testable import SpikDoum

private func result(start: Double, final: Bool, text: String) throws -> DeepgramResult {
    let object: [String: Any] = ["type": "Results", "start": start, "duration": 1.0, "is_final": final,
                                "channel": ["alternatives": [["transcript": text, "words": [["word": text, "start": start, "speaker": 0]]]]]]
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(DeepgramResult.self, from: JSONSerialization.data(withJSONObject: object))
}
@Test func finalizedSpeechIsNeverRepeatedByLateInterim() throws {
    var state = DeepgramTranscript()
    state.apply(try result(start: 0, final: false, text: "Hello"))
    #expect(state.full == "Hello")
    #expect(state.stable.isEmpty)
    state.apply(try result(start: 0, final: true, text: "Hello."))
    state.apply(try result(start: 0, final: false, text: "Hello"))
    state.apply(try result(start: 0, final: true, text: "Hello."))
    #expect(state.full == "Hello.")
    #expect(state.stable == "Hello.")
    state.apply(try result(start: 1, final: false, text: "How are you?"))
    #expect(state.full == "Hello.\nHow are you?")
    #expect(state.stable == "Hello.")
}
@Test func repeatedFinalAndOutOfOrderPacketsKeepStableOrder() throws {
    var state = DeepgramTranscript()
    state.apply(try result(start: 1, final: true, text: "Second"))
    state.apply(try result(start: 0, final: true, text: "First"))
    state.apply(try result(start: 1, final: true, text: "Second"))
    #expect(state.stable == "First\nSecond")
    #expect(state.turns.first?.speaker == 1)
}
@Test func compatibleServerRequestSupportsLANAndOptionalAuthentication() throws {
    var settings = EngineSettings(); settings.llm = .compatible
    settings.serverURL = "http://192.168.0.5:8000/v1/"; settings.serverModel = "local-model"
    let request = try LLMClient(settings: settings, key: "").request(instructions: "system", input: "hello")
    #expect(request.url?.absoluteString == "http://192.168.0.5:8000/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["model"] as? String == "local-model")
    #expect(body["stream"] as? Bool == true)
}
@Test func sseHandlesBothServerProtocolsAndTruncation() throws {
    #expect(try SSEPayload.decode("{\"type\":\"response.output_text.delta\",\"delta\":\"안녕\"}").delta == "안녕")
    #expect(try SSEPayload.decode("{\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}").delta == "hello")
    #expect(try SSEPayload.decode("{\"type\":\"response.incomplete\"}").error != nil)
    #expect(try SSEPayload.decode("{\"choices\":[{\"finish_reason\":\"length\"}]}").error != nil)
}
@Test func azureUsesDedicatedTranslationResult() throws {
    let data = Data("{\"value\":[{\"translations\":[{\"text\":\"안녕하세요\",\"language\":\"ko\"}]}]}".utf8)
    #expect(try AzureTranslator.parse(data) == "안녕하세요")
}
@Test func deepgramUsesMultilingualDiarizationAndCorrectAudioFormat() {
    let request = CloudSpeechCapture.request(key: "test", sampleRate: 48000, language: "ko-KR")
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
    #expect(params["language"] == "multi")
    #expect(params["encoding"] == "linear16")
    #expect(params["sample_rate"] == "48000")
    #expect(params["diarize_model"] == "v1")
}
