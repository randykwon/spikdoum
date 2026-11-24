import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures playback before it reaches speakers/headphones. No video frames are consumed or stored.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "SpikDoum.system-audio", qos: .userInitiated)
    var onLevel: ((Double) -> Void)?
    private var lastLevelAt = Date.distantPast
    private var consecutiveCopyFailures = 0
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?
    func start(target: MeetingAudioTarget = .all) async throws {
        stop()
        consecutiveCopyFailures = 0
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let applications = content.applications.filter { target.matches(bundleID: $0.bundleIdentifier) }
        if target != .all && applications.isEmpty { throw CaptureError.message("\(target.title)을 먼저 실행하고 회의에 참여해주세요. 브라우저에서 Zoom을 사용하는 경우 해당 브라우저 또는 전체 Mac 소리를 선택하세요.") }
        let window = content.windows.first { window in
            guard let app = window.owningApplication else { return false }
            return target != .all && target.matches(bundleID: app.bundleIdentifier)
        }
        let matchingDisplay = window.flatMap { window in content.displays.first { $0.frame.intersects(window.frame) } }
        guard let display = matchingDisplay ?? content.displays.first else { throw CaptureError.message("Mac 재생음 수집에 사용할 디스플레이가 없습니다.") }
        let config = SCStreamConfiguration()
        config.width = 16; config.height = 16
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        let filter: SCContentFilter
        if target == .all { filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []) }
        else { filter = SCContentFilter(display: display, including: applications, exceptingWindows: []) }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        do { try await capture.startCapture() }
        catch { stream = nil; throw error }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        if status == noErr {
            consecutiveCopyFailures = 0
            if Date().timeIntervalSince(lastLevelAt) > 0.5 {
                lastLevelAt = Date()
                var peak: Float = 0
                if let channel = pcm.floatChannelData?[0] {
                    for index in stride(from: 0, to: frames, by: 8) { peak = max(peak, abs(channel[index])) }
                }
                onLevel?(min(1, Double(peak)))
            }
            onBuffer?(pcm)
        } else {
            consecutiveCopyFailures += 1
            if consecutiveCopyFailures >= 20 {
                onError?("[SYSTEM_AUDIO_RECONNECT] Mac 오디오 버퍼 변환 실패 (\(status))")
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        // Do not auto-retry if screen/system audio permission was explicitly denied.
        let denied = nsError.localizedDescription.contains("TCC") || nsError.code == -3801
        let prefix = denied ? "" : "[SYSTEM_AUDIO_RECONNECT] "
        onError?("\(prefix)Mac 재생음 수집 중단: \(error.localizedDescription)")
    }
    func stop() {
        guard let capture = stream else { return }
        stream = nil
        capture.stopCapture { _ in }
    }
}
