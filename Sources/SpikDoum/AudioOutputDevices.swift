import Foundation
import CoreAudio

enum AudioOutputDevices {
    static func list() throws -> [AudioInputDevice] {
        try AudioInputDevices.list(scope: kAudioDevicePropertyScopeOutput).filter { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var allowed: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &allowed) == noErr && allowed != 0
        }
    }
    static func current() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw CaptureError.message("기본 출력 디바이스 조회 실패 (\(status))") }
        return device
    }
    static func setDefault(uid: String) throws {
        guard let device = try list().first(where: { $0.uid == uid }) else { throw CaptureError.message("선택한 출력 장치가 연결되어 있지 않습니다.") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        guard status == noErr else { throw CaptureError.message("출력 장치 변경 실패 (\(status)). 시스템 사운드 설정을 확인해주세요.") }
    }
}
