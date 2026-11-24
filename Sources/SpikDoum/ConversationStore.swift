import Foundation

/// Serialized background persistence for conversations.json so JSON encoding and atomic disk writes
/// do not stall the MainActor during live capture, while coalescing bursts to the latest snapshot.
final class ConversationStore: @unchecked Sendable {
    let file: URL
    private let queue = DispatchQueue(label: "SpikDoum.ConversationStore", qos: .utility)
    private let lock = NSLock()
    private var latest: [Conversation]?
    private var scheduled = false

    init(file: URL) {
        self.file = file
    }

    func load() throws -> [Conversation] {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: file))
    }

    func saveAsync(_ conversations: [Conversation], onError: @escaping @Sendable (String) -> Void) {
        lock.lock()
        latest = conversations
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drainPending(onError: onError)
        }
    }

    func saveSync(_ conversations: [Conversation]) throws {
        lock.lock()
        latest = nil
        scheduled = false
        lock.unlock()
        var failure: Error?
        queue.sync {
            do {
                try Self.write(conversations, to: self.file)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    func cancelAndDrain() {
        lock.lock()
        latest = nil
        scheduled = false
        lock.unlock()
        queue.sync {}
    }

    private func drainPending(onError: @escaping @Sendable (String) -> Void) {
        while true {
            lock.lock()
            let snapshot = latest
            latest = nil
            if snapshot == nil {
                scheduled = false
                lock.unlock()
                return
            }
            lock.unlock()
            guard let snapshot else { return }
            do {
                try Self.write(snapshot, to: file)
            } catch {
                onError("기록 저장 실패: \(error.localizedDescription)")
            }
        }
    }

    private static func write(_ conversations: [Conversation], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(conversations).write(to: file, options: .atomic)
    }
}
