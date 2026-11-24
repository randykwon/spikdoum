import Foundation

enum DeletionMode: String, CaseIterable { case archive, permanent }

enum ConversationLifecycle {
    /// Remove a conversation from the live store and application-managed restart backups.
    /// Reads every candidate before writing, so a malformed backup never silently bypasses removal.
    static func persistRemoval(id: UUID, remaining: [Conversation], file: URL) throws {
        try persistRemoval(ids: [id], remaining: remaining, file: file)
    }
    static func persistRemoval(ids: Set<UUID>, remaining: [Conversation], file: URL) throws {
        guard !ids.isEmpty else { return }
        let removedIDs = Set(ids.map { $0.uuidString.lowercased() })
        let folder = file.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("conversations.before-restart.") && $0.pathExtension == "json" }
        var rewrites: [(URL, Data)] = []
        for backup in backups {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: backup))
            guard let rows = value as? [[String: Any]] else { throw CloudFailure(message: "백업 형식을 확인하지 못해 삭제를 중단했습니다.") }
            let kept = rows.filter { !removedIDs.contains(($0["id"] as? String)?.lowercased() ?? "") }
            if kept.count != rows.count { rewrites.append((backup, try JSONSerialization.data(withJSONObject: kept))) }
        }
        let liveData = try JSONEncoder().encode(remaining)
        for (backup, data) in rewrites { try data.write(to: backup, options: .atomic) }
        try liveData.write(to: file, options: .atomic)
        let recordingsRoot = RecordingStorage.recordingsRoot(nextTo: file)
        for id in ids {
            let clipFolder = RecordingStorage.conversationFolder(for: id, root: recordingsRoot)
            if FileManager.default.fileExists(atPath: clipFolder.path) {
                try? FileManager.default.removeItem(at: clipFolder)
            }
        }
    }
}
