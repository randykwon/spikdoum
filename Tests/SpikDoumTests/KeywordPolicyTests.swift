import Foundation
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
@Test func relatedKeywordsParseCleanAndMergeAcrossHistory() throws {
    let json = """
    ```json
    {"items":[{"term":"예산","related":["비용","승인","예산","비용","지출","한도","추가초과"]},{"term":"일정","related":["마감","스케줄"]}]}
    ```
    """
    let parsed = try KeywordPolicy.parseWithRelated(json)
    #expect(parsed.terms == ["예산", "일정"])
    let valid = KeywordPolicy.clean(parsed.terms, source: "이번 분기 예산과 일정을 검토합니다.")
    let cleaned = KeywordPolicy.cleanRelated(parsed.related, validTerms: valid)
    #expect(cleaned["예산"] == ["비용", "승인", "지출", "한도"])
    #expect(cleaned["일정"] == ["마감", "스케줄"])

    let older = ConversationKeywords(terms: ["예산"], date: Date(timeIntervalSince1970: 10), source: "예산", relatedTerms: ["예산": ["결산", "비용"]])
    let newer = ConversationKeywords(terms: ["예산", "일정"], date: Date(timeIntervalSince1970: 20), source: "예산 일정", relatedTerms: cleaned)
    let merged = KeywordPolicy.mergedRelated(current: newer, history: [older])
    #expect(merged["예산"] == ["비용", "승인", "지출", "한도", "결산"])
    #expect(merged["일정"] == ["마감", "스케줄"])
}
@Test func basicEverydayWordsAreExcludedFromKeywordsAndRelatedTerms() {
    let source = "안녕하세요 오늘 시간 괜찮아요? Kubernetes와 RAG 파이프라인의 Quantization 성능을 확인합니다. ありがとう"
    let cleaned = KeywordPolicy.clean(["안녕하세요", "오늘", "시간", "ありがとう", "Kubernetes", "RAG", "Quantization"], source: source)
    #expect(cleaned == ["Kubernetes", "RAG", "Quantization"])

    let cleanedRelated = KeywordPolicy.cleanRelated(
        ["Kubernetes": ["오늘", "시간", "컨테이너 오케스트레이션", "Pod", "K8s"]],
        validTerms: cleaned
    )
    #expect(cleanedRelated["Kubernetes"] == ["컨테이너 오케스트레이션", "Pod", "K8s"])

    let legacySnapshot = ConversationKeywords(terms: ["감사 인사", "오늘", "Quantization"], date: Date(), source: source)
    #expect(KeywordPolicy.merged(current: legacySnapshot, history: []) == ["Quantization"])
}
