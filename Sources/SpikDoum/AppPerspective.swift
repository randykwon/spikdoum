import SwiftUI
import AppKit

enum AppPerspective: String, CaseIterable, Identifiable, Codable, Sendable {
    static let storageKey = "appPerspectiveV1"

    case standard
    case presentation
    case meeting
    case learning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "기본"
        case .presentation: return "프레젠테이션"
        case .meeting: return "미팅"
        case .learning: return "온라인 교육"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "rectangle.3.group"
        case .presentation: return "play.rectangle.on.rectangle"
        case .meeting: return "person.2.wave.2"
        case .learning: return "graduationcap"
        }
    }

    var accentColor: Color {
        switch self {
        case .standard: return .accentColor
        case .presentation: return .purple
        case .meeting: return .teal
        case .learning: return .indigo
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "실시간 다국어 통번역 · 코치 · 요약"
        case .presentation: return "발표 타이머 · 큐카드 · 체크리스트 · Q&A"
        case .meeting: return "마이크 + Mac 양방향 · 구간 요약 · 코치"
        case .learning: return "Mac 소리 자막 · 키워드 단어장 · 복습 요약"
        }
    }

    /// Recommended audio routing applied only when switching while NOT currently listening.
    var recommendedAudio: (includeSystem: Bool, systemOnly: Bool)? {
        switch self {
        case .standard: return nil
        case .presentation: return (false, false)
        case .meeting: return (true, false)
        case .learning: return (true, true)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: storageKey),
              let value = Self(rawValue: raw) else {
            return .standard
        }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

/// Controls macOS window capture visibility (`NSWindow.sharingType = .none`) so presenter notes,
/// timers, and translations can be hidden during screen sharing.
struct WindowPrivacyController: NSViewRepresentable {
    let hideFromScreenShare: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let desired: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
            if window.sharingType != desired {
                window.sharingType = desired
            }
        }
    }
}
