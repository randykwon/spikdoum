import SwiftUI

struct ReadingScrollControl: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.onScrollPhaseChange { _, phase in
            // Programmatic scrollTo uses .animating; only human interaction pauses follow.
            if phase == .tracking || phase == .interacting { model.pauseReading() }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { _ in
            model.pauseReading()
            return .ignored
        }
    }
}
extension View {
    func readingScrollControl(_ model: AppModel) -> some View { modifier(ReadingScrollControl(model: model)) }
}
