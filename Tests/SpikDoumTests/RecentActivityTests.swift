import Foundation
import Testing
@testable import SpikDoum
@Test func recentSpeechPreservesOldTimesAndReplacesCorrections() {
    let start = Date(timeIntervalSince1970: 1000)
    let first = RecentActivity.update(old: "", new: "Hello", spans: [], at: start)
    let next = RecentActivity.update(old: "Hello", new: "Hello there", spans: first, at: start.addingTimeInterval(10))
    #expect(next.count == 2)
    #expect(next[0].date == start)
    let corrected = RecentActivity.update(old: "Hello there", new: "Hello everyone", spans: next, at: start.addingTimeInterval(11))
    #expect(corrected.map(\.text).joined() == "Hello everyone")
    #expect(corrected[0].date == start)
    let translation = TranslationEntry(source: "everyone", translated: "여러분", sourceStart: 6, sourceEnd: 14)
    #expect(RecentActivity.sourceDate(for: translation, spans: corrected) == start.addingTimeInterval(11))
}
@Test func liveWordsAreGroupedInsteadOfMakingOneCardPerWord() {
    let start = Date()
    let first = RecentActivity.update(old: "", new: "Hello", spans: [], at: start)
    let next = RecentActivity.update(old: "Hello", new: "Hello there", spans: first, at: start.addingTimeInterval(1))
    #expect(next.count == 1)
    #expect(next[0].id == first[0].id)
    #expect(next[0].text == "Hello there")
}
