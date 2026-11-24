import Foundation

import Testing
@testable import SpikDoum
@Test func avoidsRepeatedAdvice() {
    let text = "이번 프로젝트 일정과 예산에 대해 논의하고 싶습니다."
    #expect(AdvicePolicy.shouldGenerate(text: text, previous: ""))
    #expect(!AdvicePolicy.shouldGenerate(text: text, previous: text))
    #expect(!AdvicePolicy.shouldGenerate(text: "네", previous: ""))
    #expect(AdvicePolicy.shouldGenerate(text: text + " 현재 일정이 촉박해서 우선순위를 다시 정해야 할 것 같은데 어떻게 생각하세요?", previous: text))
}
@Test func boundsContext() {
    let input = String(repeating: "가", count: 4000) + "마지막 발언"
    #expect(AdvicePolicy.context(input).count == 3000)
    #expect(AdvicePolicy.context(input).hasSuffix("마지막 발언"))
}

@Test func loadsOlderHistoryWithoutTranslations() throws {
    var item = Conversation()
    item.transcript = "Hello, how are you?"
    let data = try JSONEncoder().encode(item)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "translations")
    let older = try JSONSerialization.data(withJSONObject: json)
    let restored = try JSONDecoder().decode(Conversation.self, from: older)
    #expect(restored.transcript == item.transcript)
    #expect(restored.translations == nil)
}
@Test func savesSourceAndTranslationTogether() throws {
    var item = Conversation()
    item.translations = [TranslationEntry(source: "Hello", translated: "안녕하세요")]
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(item))
    #expect(restored.translations?.first?.source == "Hello")
    #expect(restored.translations?.first?.translated == "안녕하세요")
}

@Test func translationRevisionRetainsEarlierValidEntries() {
    let first = TranslationEntry(source: "Hello. ", translated: "안녕하세요.", sourceStart: 0, sourceEnd: 7)
    let second = TranslationEntry(source: "I can go", translated: "갈 수 있어요", sourceStart: 7, sourceEnd: 15)
    let plan = TranslationPolicy.plan(transcript: "Hello. I cannot go", entries: [first, second])
    #expect(plan.retained.map(\.id) == [first.id])
    #expect(plan.source == "I cannot go")
    #expect(plan.start == 7)
}
@Test func translationDoesNotRepeatUnchangedOrAppendedText() {
    let entry = TranslationEntry(source: "Hello", translated: "안녕하세요", sourceStart: 0, sourceEnd: 5)
    #expect(TranslationPolicy.plan(transcript: "Hello", entries: [entry]).source.isEmpty)
    #expect(TranslationPolicy.plan(transcript: "Hello there", entries: [entry]).source == " there")
}
@Test func translationRejectsStaleRecognitionSnapshot() {
    let plan = TranslationPolicy.plan(transcript: "I can go", entries: [])
    #expect(!TranslationPolicy.isCurrent(plan, transcript: "I cannot go"))
    #expect(TranslationPolicy.isCurrent(plan, transcript: "I can go tomorrow"))
}
@Test func summaryAccumulatesAndRebuildsAfterCorrection() {
    let state = SummaryState(text: "이전 요약", coveredSource: "첫 발언", updatedAt: Date())
    let append = SummaryPolicy.work(source: "첫 발언 다음 발언", state: state)
    #expect(append?.source == " 다음 발언")
    #expect(append?.previous == "이전 요약")
    let edit = SummaryPolicy.work(source: "수정된 발언", state: state)
    #expect(edit?.previous == "")
    #expect(SummaryPolicy.work(source: "첫 발언", state: state) == nil)
}
@Test func missingInputDeviceFailsRatherThanUsingAnotherMicrophone() {
    #expect(throws: (any Error).self) { try AudioInputDevices.resolve(uid: "spikdoum-nonexistent-test-device") }
}

@Test func oldGenerativeTranslationsAreReplaced() {
    var old = TranslationEntry(source: "Hello", translated: "틀린 반복 번역", sourceStart: 0, sourceEnd: 5)
    old.engine = nil
    let plan = TranslationPolicy.plan(transcript: "Hello", entries: [old])
    #expect(plan.retained.isEmpty)
    #expect(plan.source == "Hello")
}

@Test func adviceIgnoresRecognitionFormattingAndSmallCorrections() {
    let old = "We should review the project timeline before making a decision."
    #expect(!AdvicePolicy.shouldGenerate(text: "We should review the project timeline, before making a decision!", previous: old))
    #expect(!AdvicePolicy.shouldGenerate(text: "We must review the project timeline before making a decision.", previous: old))
    let long = String(repeating: old, count: 60)
    #expect(!AdvicePolicy.shouldGenerate(text: long + " Okay.", previous: long))
    #expect(AdvicePolicy.shouldGenerate(text: long + " The customer now requires delivery by Friday with a smaller budget.", previous: long))
}
@Test func adviceSuppressesRepeatedOutput() {
    #expect(AdvicePolicy.isDuplicate("조언: 일정을 먼저 확인해 주세요!", recent: ["조언: 일정을 먼저 확인해 주세요."]))
    #expect(AdvicePolicy.isDuplicate("변경 없음", recent: []))
    #expect(!AdvicePolicy.isDuplicate("먼저 고객의 예산 범위를 물어보세요.", recent: ["회의 참석자들의 일정을 확인하세요."]))
}
