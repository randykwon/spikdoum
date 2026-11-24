import SwiftUI
import AppKit

/// Only the conversation window handles plain Space; text input and modal UI keep it.
struct ReadingSpaceShortcut: NSViewRepresentable {
    var enabled: Bool
    var toggle: () -> Void

    static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 49 && modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view)
        context.coordinator.enabled = enabled
        context.coordinator.toggle = toggle
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.toggle = toggle
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    @MainActor final class Coordinator {
        var enabled = false
        var toggle: (() -> Void)?
        private weak var view: NSView?
        private var monitor: Any?
        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.view?.window,
                      (NSApp.keyWindow === window || event.window === window), window.attachedSheet == nil, NSApp.modalWindow == nil,
                      ReadingSpaceShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
                let responder = window.firstResponder
                if let editor = responder as? NSTextView, editor.isEditable { return event }
                if let field = responder as? NSTextField, field.isEditable { return event }
                if let control = responder as? NSControl, control.currentEditor() != nil { return event }
                if let input = responder as? NSTextInputClient, input.hasMarkedText() { return event }
                // Holding Space must neither repeatedly toggle nor scroll the reading view.
                if !event.isARepeat { self.toggle?() }
                return nil
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
