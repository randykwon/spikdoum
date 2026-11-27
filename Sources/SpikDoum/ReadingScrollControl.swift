import SwiftUI

struct ReadingScrollControl: ViewModifier {
    @ObservedObject var model: AppModel
    var enabled: Bool = true
    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, phase in
            // Programmatic scrollTo uses .animating; only human interaction pauses follow.
            guard enabled else { return }
            if phase == .tracking || phase == .interacting { model.pauseReading() }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { _ in
            guard enabled else { return .ignored }
            model.pauseReading()
            return .ignored
        }
    }
}
extension View {
    func readingScrollControl(_ model: AppModel, enabled: Bool = true) -> some View {
        modifier(ReadingScrollControl(model: model, enabled: enabled))
    }
}
