import Foundation
import Testing
@testable import SpikDoum
@Test func permanentRemovalPurgesOnlyTargetAcrossAppBackups() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var target = Conversation(); target.transcript = "private conversation"
    var kept = Conversation(); kept.transcript = "keep me"; kept.archivedAt = Date()
    let file = directory.appendingPathComponent("conversations.json")
    let backup = directory.appendingPathComponent("conversations.before-restart.test.json")
    let original = try JSONEncoder().encode([target, kept])
    try original.write(to: file); try original.write(to: backup)
    try ConversationLifecycle.persistRemoval(id: target.id, remaining: [kept], file: file)
    for url in [file, backup] {
        let restored = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
        #expect(restored.map(\.id) == [kept.id])
        #expect(restored[0].archivedAt != nil)
        #expect(restored[0].transcript == "keep me")
    }
}
@Test func malformedBackupDoesNotDeleteLiveConversation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let item = Conversation()
    let file = directory.appendingPathComponent("conversations.json")
    let original = try JSONEncoder().encode([item]); try original.write(to: file)
    try Data("broken".utf8).write(to: directory.appendingPathComponent("conversations.before-restart.bad.json"))
    #expect(throws: (any Error).self) { try ConversationLifecycle.persistRemoval(id: item.id, remaining: [], file: file) }
    #expect(try Data(contentsOf: file) == original)
}

@Test func bulkRemovalPurgesAllSelectedAndPreservesUnselectedAcrossBackups() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Conversation(title: "first")
    let second = Conversation(title: "second", archivedAt: Date())
    let kept = Conversation(title: "keep", transcript: "unchanged")
    let file = directory.appendingPathComponent("conversations.json")
    let backup = directory.appendingPathComponent("conversations.before-restart.bulk.json")
    let original = try JSONEncoder().encode([first, kept, second])
    try original.write(to: file); try original.write(to: backup)
    try ConversationLifecycle.persistRemoval(ids: [first.id, second.id], remaining: [kept], file: file)
    for url in [file, backup] {
        let restored = try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
        #expect(restored.map(\.id) == [kept.id])
        #expect(restored.first?.transcript == "unchanged")
    }
    try ConversationLifecycle.persistRemoval(ids: [kept.id], remaining: [], file: file)
    #expect(try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: file)).isEmpty)
}

@Test func bulkRemovalRejectsMalformedBackupBeforeAnyRewrite() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Conversation(), second = Conversation()
    let file = directory.appendingPathComponent("conversations.json")
    let backup = directory.appendingPathComponent("conversations.before-restart.valid.json")
    let original = try JSONEncoder().encode([first, second])
    try original.write(to: file); try original.write(to: backup)
    try Data("broken".utf8).write(to: directory.appendingPathComponent("conversations.before-restart.invalid.json"))
    #expect(throws: (any Error).self) { try ConversationLifecycle.persistRemoval(ids: [first.id, second.id], remaining: [], file: file) }
    #expect(try Data(contentsOf: file) == original)
    #expect(try Data(contentsOf: backup) == original)
}
