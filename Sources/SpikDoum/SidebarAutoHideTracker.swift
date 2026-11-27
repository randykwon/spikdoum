import SwiftUI
import AppKit

/// Pure, unit-testable geometry & hysteresis policy for the mouse-driven auto-hide left sidebar.
enum SidebarAutoHidePolicy {
    static let defaultSidebarWidth: CGFloat = 248
    static let revealEdgeWidth: CGFloat = 18
    static let keepOpenMargin: CGFloat = 14

    enum Action: Equatable {
        case reveal
        case keepOpen
        case scheduleHide
        case ignore
    }

    static func evaluate(
        pointInView: CGPoint,
        viewSize: CGSize,
        isRevealed: Bool,
        isPinned: Bool,
        isBusy: Bool,
        sidebarWidth: CGFloat = defaultSidebarWidth
    ) -> Action {
        guard !isPinned else { return .ignore }
        let insideBounds = pointInView.x >= 0
            && pointInView.x <= viewSize.width
            && pointInView.y >= 0
            && pointInView.y <= viewSize.height

        guard insideBounds else {
            return (isRevealed && !isBusy) ? .scheduleHide : .ignore
        }

        if !isRevealed {
            return pointInView.x <= revealEdgeWidth ? .reveal : .ignore
        }

        if pointInView.x <= sidebarWidth + keepOpenMargin {
            return .keepOpen
        }
        return isBusy ? .keepOpen : .scheduleHide
    }
}

/// Non-intrusive AppKit mouse monitor attached to the main window background.
/// Tracks pointer motion smoothly even across nested `List`, `TextField`, and `HSplitView` surfaces
/// without interfering with clicks, drags, context menus, or popovers.
struct LeftEdgeMouseMonitor: NSViewRepresentable {
    let isAutoHideEnabled: Bool
    let isRevealed: Bool
    let isBusy: Bool
    let sidebarWidth: CGFloat
    let onReveal: () -> Void
    let onHide: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TrackingHostView {
        let view = TrackingHostView()
        view.onMouseExitedWindow = { [weak coordinator = context.coordinator] in
            coordinator?.handleMouseExitedWindow()
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: TrackingHostView, context: Context) {
        context.coordinator.parent = self
        if !isAutoHideEnabled {
            context.coordinator.cancelTimers()
        }
    }

    static func dismantleNSView(_ nsView: TrackingHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class TrackingHostView: NSView {
        var onMouseExitedWindow: (() -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingAreaRef {
                removeTrackingArea(existing)
            }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onMouseExitedWindow?()
        }
    }

    @MainActor
    final class Coordinator {
        var parent: LeftEdgeMouseMonitor
        private weak var hostView: NSView?
        private var eventMonitor: Any?
        private var hideTask: Task<Void, Never>?

        init(parent: LeftEdgeMouseMonitor) {
            self.parent = parent
        }

        func attach(to view: NSView) {
            hostView = view
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.handlePointerEvent(event)
                return event
            }
        }

        func detach() {
            cancelTimers()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            hostView = nil
        }

        func cancelTimers() {
            hideTask?.cancel()
            hideTask = nil
        }

        private func hasBlockingOverlay(in window: NSWindow) -> Bool {
            if window.attachedSheet != nil { return true }
            if let childWindows = window.childWindows,
               childWindows.contains(where: { $0.isVisible && ($0.className.contains("Popover") || $0.className.contains("Menu")) }) {
                return true
            }
            return false
        }

        private func handlePointerEvent(_ event: NSEvent) {
            guard parent.isAutoHideEnabled,
                  let view = hostView,
                  let window = view.window,
                  event.window === window,
                  window.isVisible else { return }

            if hasBlockingOverlay(in: window) {
                cancelTimers()
                return
            }

            let point = view.convert(event.locationInWindow, from: nil)
            let action = SidebarAutoHidePolicy.evaluate(
                pointInView: point,
                viewSize: view.bounds.size,
                isRevealed: parent.isRevealed,
                isPinned: !parent.isAutoHideEnabled,
                isBusy: parent.isBusy,
                sidebarWidth: parent.sidebarWidth
            )
            apply(action)
        }

        func handleMouseExitedWindow() {
            guard parent.isAutoHideEnabled,
                  parent.isRevealed,
                  !parent.isBusy,
                  let window = hostView?.window,
                  !hasBlockingOverlay(in: window) else { return }
            apply(.scheduleHide)
        }

        private func apply(_ action: SidebarAutoHidePolicy.Action) {
            switch action {
            case .reveal:
                cancelTimers()
                parent.onReveal()
            case .keepOpen:
                cancelTimers()
            case .scheduleHide:
                guard hideTask == nil else { return }
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self else { return }
                    self.hideTask = nil
                    if self.parent.isAutoHideEnabled && self.parent.isRevealed && !self.parent.isBusy {
                        self.parent.onHide()
                    }
                }
            case .ignore:
                break
            }
        }
    }
}
