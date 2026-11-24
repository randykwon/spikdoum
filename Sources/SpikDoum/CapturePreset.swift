import Foundation

enum CapturePreset: String, CaseIterable {
    case youtube, googleMeet, zoom, inPerson
    var title: String {
        switch self { case .youtube: return "유튜브"; case .googleMeet: return "Google Meet"; case .zoom: return "Zoom"; case .inPerson: return "대면 대화" }
    }
    func plan(browser: MeetingAudioTarget = .chrome) -> CapturePresetPlan {
        switch self {
        case .youtube: return CapturePresetPlan(systemOnly: true, systemAudio: true, target: .all, automaticAdvice: false)
        case .googleMeet:
            let browsers: [MeetingAudioTarget] = [.all, .chrome, .safari, .edge, .firefox]
            return CapturePresetPlan(systemOnly: false, systemAudio: true, target: browsers.contains(browser) ? browser : .chrome, automaticAdvice: true)
        case .zoom: return CapturePresetPlan(systemOnly: false, systemAudio: true, target: .zoom, automaticAdvice: true)
        case .inPerson: return CapturePresetPlan(systemOnly: false, systemAudio: false, target: .all, automaticAdvice: true)
        }
    }
}
struct CapturePresetPlan: Equatable {
    var systemOnly: Bool
    var systemAudio: Bool
    var target: MeetingAudioTarget
    var automaticAdvice: Bool
}
