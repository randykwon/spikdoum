import Foundation
import Testing
@testable import SpikDoum

@Test func localTranslationPostsToExactEndpointAndEscapesOriginalText() throws {
    let text = "\"Quoted\"\n한글 {{target}} \\ end"
    let client = LocalTranslator(settings: LocalTranslationSettings(), key: "test-key")
    let request = try client.request(text: text, source: "en")
    #expect(request.url?.absoluteString == "http://10.0.1.5:8848/v1/translate")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
    #expect(body["text"] == text)
    #expect(body["source_lang"] == "en")
    #expect(body["target_lang"] == "ko")
}

@Test func localTranslationSupportsCustomNestedRequestWithoutAuthentication() throws {
    var settings = LocalTranslationSettings()
    settings.requestJSON = #"{"messages":[{"role":"user","content":"Translate to {{target}}: {{text}}"}],"stream":false}"#
    let request = try LocalTranslator(settings: settings, key: "").request(text: "Hi", source: "en")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.first?["content"] == "Translate to ko: Hi")
    #expect(body["stream"] as? Bool == false)
}

@Test func localTranslationReadsDedicatedFieldsAndCustomArrayPaths() throws {
    let direct = Data(#"{"text":"Hello","translation":"안녕하세요"}"#.utf8)
    #expect(try LocalTranslator.parse(direct) == "안녕하세요")
    let nested = Data(#"{"result":{"items":[{"korean":"좋은 하루입니다."}]}}"#.utf8)
    #expect(try LocalTranslator.parse(nested, path: "result.items.0.korean") == "좋은 하루입니다.")
    #expect(throws: (any Error).self) { try LocalTranslator.parse(Data(#"{"detail":"error"}"#.utf8)) }
    #expect(throws: (any Error).self) { try LocalTranslator.parse(Data(#"{"translation":" "}"#.utf8)) }
    #expect(throws: (any Error).self) { try LocalTranslator.parse(Data("<html>error</html>".utf8)) }
    #expect(throws: (any Error).self) { try LocalTranslator.parse(Data(#"{"choices":[{"message":{"content":"부분 번역"},"finish_reason":"length"}]}"#.utf8)) }
}

@Test func localTranslationRejectsUnsafeURLAndMissingSourceTemplate() {
    var settings = LocalTranslationSettings()
    settings.endpoint = "file:///tmp/translation.json"
    #expect(throws: (any Error).self) { try LocalTranslator(settings: settings, key: "").request(text: "hello", source: "en") }
    settings.endpoint = "http://user:password@localhost:8848/v1/translate"
    #expect(throws: (any Error).self) { try LocalTranslator(settings: settings, key: "").request(text: "hello", source: "en") }
    settings.endpoint = "http://localhost:8848/v1/translate"
    settings.requestJSON = #"{"text":"hardcoded text"}"#
    #expect(throws: (any Error).self) { try LocalTranslator(settings: settings, key: "").request(text: "hello", source: "en") }
}

@Test func localTranslationMigrationPreservesExistingEngineConfiguration() throws {
    var previous = EngineSettings()
    previous.llm = .compatible
    previous.serverURL = "http://192.168.1.9:8000/v1"
    previous.serverModel = "existing-model"
    previous.translation = .azure
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
    object.removeValue(forKey: "localTranslation")
    let loaded = try JSONDecoder().decode(EngineSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(loaded.llm == .compatible)
    #expect(loaded.serverURL == previous.serverURL)
    #expect(loaded.serverModel == previous.serverModel)
    #expect(loaded.translation == .azure)
    #expect(loaded.localTranslation.endpoint == "http://10.0.1.5:8848/v1/translate")
    var local = loaded
    local.translation = .local
    local.localTranslation.responsePath = "data.translation"
    #expect(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(local)) == local)
}

private final class LocalTranslationStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/error" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"translation":"안녕하세요. 어떻게 지내세요?"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func localTranslationTransportAcceptsSuccessAndRejectsHTTPError() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LocalTranslationStub.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var settings = LocalTranslationSettings()
    settings.endpoint = "http://translate.invalid/v1/translate"
    #expect(try await LocalTranslator(settings: settings, key: "", session: session).translate("Hello. How are you?", source: "en") == "안녕하세요. 어떻게 지내세요?")
    settings.endpoint = "http://translate.invalid/error"
    await #expect(throws: (any Error).self) { try await LocalTranslator(settings: settings, key: "", session: session).translate("Hello", source: "en") }
}
