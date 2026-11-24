import Foundation
import Testing
@testable import SpikDoum

@Test func leadingLineBreakDoesNotBlockFollowingSpeech() {
    let entry = TranslationEntry(source: "Hello", translated: "안녕", sourceStart: 0, sourceEnd: 5)
    let text = "Hello\nAnd then one more surprising thing that I've seen is " + String(repeating: "new speech ", count: 35)
    let work = TranslationPolicy.plan(transcript: text, entries: [entry])
    #expect(!work.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(work.source.hasPrefix("\nAnd"))
    #expect(work.start == 5)
    #expect(work.end > 6)
}

@Test func translationDrainsMultilineBacklogWithoutGapsOrDuplicates() {
    let text = "[Mac 재생음] Hello.\n" + String(repeating: "\nAnother long paragraph with no punctuation and new words ", count: 25) + "\n마지막 문장입니다. 👋"
    var entries: [TranslationEntry] = []
    for _ in 0..<100 {
        let work = TranslationPolicy.plan(transcript: text, entries: entries)
        if work.source.isEmpty { break }
        #expect(!work.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(work.start == entries.last?.sourceEnd ?? 0)
        entries = work.retained + [TranslationEntry(source: work.source, translated: "test", sourceStart: work.start, sourceEnd: work.end)]
    }
    #expect(entries.map(\.source).joined() == text)
    #expect(TranslationPolicy.plan(transcript: text, entries: entries).source.isEmpty)
}

@Test func lengthyWhitespaceDoesNotHidePendingWords() {
    let text = String(repeating: "\n ", count: 150) + "Please translate these words"
    let work = TranslationPolicy.plan(transcript: text, entries: [])
    #expect(work.source == text)
}

@Test func panelFontsPersistAndStayWithinReadableBounds() throws {
    let suite = "SpikDoum.FontTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var fonts = PanelTypography()
    fonts.adjust(by: 100)
    #expect(PanelTypography.paths.allSatisfy { fonts[keyPath: $0] == 40 })
    fonts.adjust(by: -100)
    #expect(PanelTypography.paths.allSatisfy { fonts[keyPath: $0] == 12 })
    fonts.translation = 27
    fonts.save(defaults: defaults)
    #expect(PanelTypography.load(defaults: defaults) == fonts)
}
