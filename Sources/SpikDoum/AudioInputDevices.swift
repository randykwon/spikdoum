import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDevices {
    static func list(scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput) throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        try check(status)
        return ids.compactMap { id in
            guard hasChannels(id, scope: scope), let uid = string(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: string(id, selector: kAudioObjectPropertyName) ?? "입력 장치 \(id)")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func effectiveSelection(preferredUID: String, available: [AudioInputDevice]) -> (uid: String, fellBackToDefault: Bool) {
        guard !preferredUID.isEmpty else { return ("", false) }
        if available.contains(where: { $0.uid == preferredUID }) { return (preferredUID, false) }
        return available.isEmpty ? (preferredUID, false) : ("", true)
    }
    static func resolve(uid: String) throws -> AudioDeviceID {
        if !uid.isEmpty {
            guard let device = try list().first(where: { $0.uid == uid }) else { throw CaptureError.message("선택한 입력 디바이스가 연결되어 있지 않습니다. 장치를 다시 선택해주세요.") }
            return device.id
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id))
        guard id != kAudioObjectUnknown else { throw CaptureError.message("기본 입력 디바이스가 없습니다.") }
        return id
    }
    static func configuredEngine(uid: String) throws -> (engine: AVAudioEngine, format: AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.message("오디오 입력 장치 초기화 실패") }
        var id = try resolve(uid: uid)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard status == noErr else { throw CaptureError.message("입력 디바이스 연결 실패 (\(status))") }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.message("사용 가능한 마이크가 없습니다.") }
        return (engine, format)
    }
    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func hasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.message("입력 디바이스 조회 실패 (\(status))") }
    }
}
