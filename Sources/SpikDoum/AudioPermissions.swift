import AVFoundation
import Speech

enum AudioPermissions {
    static func microphone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.message("마이크 권한이 거부되었습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 허용해주세요.") }
        default: throw CaptureError.message("마이크 권한을 사용할 수 없습니다. 시스템 설정에서 SpikDoum을 허용해주세요.")
        }
    }
    static func speech() async throws {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return }
        guard current == .notDetermined else { throw CaptureError.message("시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 SpikDoum을 허용해주세요.") }
        let status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard status == .authorized else { throw CaptureError.message("음성 인식 권한이 허용되지 않았습니다.") }
    }
    static var status: String {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        return "마이크: \(mic == .authorized ? "허용됨" : mic == .notDetermined ? "첫 사용 시 요청" : "설정에서 허용 필요") · 음성 인식: \(speech == .authorized ? "허용됨" : speech == .notDetermined ? "첫 사용 시 요청" : "설정에서 허용 필요")"
    }
}
