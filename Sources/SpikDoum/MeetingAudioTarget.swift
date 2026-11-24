import Foundation

enum MeetingAudioTarget: String, CaseIterable {
    case all, zoom, chrome, safari, edge, firefox
    var title: String {
        switch self {
        case .all: return "전체 Mac 소리 · 호환 모드"
        case .zoom: return "Zoom 앱"
        case .chrome: return "Google Meet · Chrome"
        case .safari: return "Google Meet · Safari"
        case .edge: return "Google Meet · Edge"
        case .firefox: return "Google Meet · Firefox"
        }
    }
    func matches(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let prefix: String
        switch self {
        case .all: return true
        case .zoom: prefix = "us.zoom.xos"
        case .chrome: prefix = "com.google.chrome"
        case .safari: prefix = "com.apple.safari"
        case .edge: prefix = "com.microsoft.edgemac"
        case .firefox: prefix = "org.mozilla.firefox"
        }
        return id == prefix || id.hasPrefix(prefix + ".")
    }
}
