import Foundation

/// A value snapshot keeps rows, translations and their time window still while reading.
struct ReadingState {
    private(set) var conversation: Conversation?
    private(set) var referenceDate: Date?
    mutating func pause(_ current: Conversation?, listening: Bool, now: Date = Date()) {
        conversation = current
        let dates = (current?.transcriptSpans ?? []).map(\.date) + (current?.advice ?? []).map(\.date) + (current?.translations ?? []).compactMap(\.date)
        referenceDate = listening ? now : dates.max() ?? now
    }
    mutating func resume() { conversation = nil; referenceDate = nil }
    func display(current: Conversation?) -> Conversation? {
        guard let conversation, conversation.id == current?.id else { return current }
        return conversation
    }
}
