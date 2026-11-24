import AppKit
import Testing
@testable import SpikDoum

@MainActor @Test func readingSpaceShortcutOnlyAcceptsUnmodifiedSpace() {
    #expect(ReadingSpaceShortcut.matches(keyCode: 49, modifiers: []))
    #expect(ReadingSpaceShortcut.matches(keyCode: 49, modifiers: [.capsLock]))
    #expect(!ReadingSpaceShortcut.matches(keyCode: 36, modifiers: []))
    for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function] {
        #expect(!ReadingSpaceShortcut.matches(keyCode: 49, modifiers: modifier))
    }
}
