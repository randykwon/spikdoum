import Testing
@testable import SpikDoum
@Test func keywordsAreGroundedDeduplicatedAndBounded() {
    let source = "Zoom meeting on Friday: budget review with Alice, Swift and C++."
    let terms = KeywordPolicy.clean(["Zoom", "zoom", "Friday", "Alice", "C++", "invented", "", "unsupported\nsentence"], source: source)
    #expect(terms == ["Zoom", "Friday", "Alice", "C++"])
    #expect(KeywordPolicy.clean(["없는 키워드"], source: "회의 예산 일정").isEmpty)
}
@Test func compatibleServerKeywordJSONSupportsCodeFence() throws {
    #expect(try KeywordPolicy.parse("```json\n{\"keywords\":[\"일정\",\"예산\"]}\n```") == ["일정", "예산"])
    #expect(throws: (any Error).self) { try KeywordPolicy.parse("설명만 있는 잘못된 응답") }
}
