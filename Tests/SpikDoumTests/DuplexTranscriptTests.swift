import Testing
@testable import SpikDoum
@Test func headsetConversationCombinesBothSourcesWithoutRepeats() {
    var state = DuplexTranscript()
    _ = state.update(source: "마이크", text: "Hello")
    _ = state.update(source: "Mac 재생음", text: "Hi")
    let combined = state.update(source: "마이크", text: "Hello there")
    #expect(combined.contains("[마이크] Hello"))
    #expect(combined.contains("[Mac 재생음] Hi"))
    #expect(state.update(source: "마이크", text: "Hello there") == combined)
    let corrected = state.update(source: "Mac 재생음", text: "Hi, how are you?")
    #expect(corrected.contains("how are you?"))
    #expect(!corrected.contains("[Mac 재생음] Hi\n[Mac 재생음] Hi"))
}
