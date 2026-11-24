import Foundation
import NaturalLanguage

struct TranslationWork {
    var retained: [TranslationEntry]
    var source: String
    var start: Int
    var end: Int
    var waitingForSentences = false
    var completedSentences = 0
    var prefix: String
}
enum TranslationPolicy {
    /// Returns the valid leading prefix of translations in a single O(N) pass without sentence tokenization.
    static func retained(transcript: String, entries: [TranslationEntry]) -> (entries: [TranslationEntry], cursor: Int, index: String.Index) {
        var cursor = 0
        var stringIndex = transcript.startIndex
        var retained: [TranslationEntry] = []
        for entry in entries {
            guard entry.engine == "apple-translation-v1", entry.sourceStart == cursor, let end = entry.sourceEnd,
                  end > cursor,
                  let nextIndex = transcript.index(stringIndex, offsetBy: end - cursor, limitedBy: transcript.endIndex),
                  transcript[stringIndex..<nextIndex] == entry.source else { break }
            retained.append(entry)
            cursor = end
            stringIndex = nextIndex
        }
        return (retained, cursor, stringIndex)
    }
    /// Reconcile only the invalid suffix after a partial STT revision.
    static func plan(transcript: String, entries: [TranslationEntry], flush: Bool = true) -> TranslationWork {
        let kept = retained(transcript: transcript, entries: entries)
        let cursor = kept.cursor
        let retained = kept.entries
        let pending = String(transcript[kept.index...])
        let hasSpeech = !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = pending
        var endings: [String.Index] = []
        let closing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’」』)]}"))
        let punctuation = CharacterSet(charactersIn: ".!?。！？")
        tokenizer.enumerateTokens(in: pending.startIndex..<pending.endIndex) { range, _ in
            let sentence = String(pending[range]).trimmingCharacters(in: closing)
            // Newlines and audio-source labels are not sentence endings.
            if let last = sentence.unicodeScalars.last, punctuation.contains(last) {
                // Keep common spoken abbreviations with the following sentence.
                let abbreviations = ["mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e."]
                if !abbreviations.contains(sentence.lowercased()) { endings.append(range.upperBound) }
            }
            return endings.count < 3
        }
        let waiting = hasSpeech && endings.count < 2 && !flush
        let source: String
        if waiting || !hasSpeech { source = "" }
        else if endings.count >= 2 { source = String(pending[..<endings[min(3, endings.count) - 1]]) }
        else {
            // Flush residual/unfinished speech on silence or at the maximum wait time.
            let leadingWhitespace = pending.prefix { $0.isWhitespace }.count
            source = String(pending.prefix(leadingWhitespace + 1200))
        }
        let end = cursor + source.count
        return TranslationWork(retained: retained, source: source, start: cursor,
                               end: end, waitingForSentences: waiting, completedSentences: endings.count,
                               prefix: String(transcript.prefix(end)))
    }
    static func shouldFlush(now: Date, lastChange: Date, batchStarted: Date?) -> Bool {
        now.timeIntervalSince(lastChange) >= 2 || batchStarted.map { now.timeIntervalSince($0) >= 6 } == true
    }
    static func isCurrent(_ work: TranslationWork, transcript: String) -> Bool {
        transcript.hasPrefix(work.prefix)
    }
}
