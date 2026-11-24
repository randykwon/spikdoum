import AVFoundation
import Foundation

struct SpeakerInterval: Decodable {
    var segment: String
    var start: Double
    var end: Double
    var speaker: Int?
    var confidence: Double
}

/// Runs locally. Audio writes and model work never run on the audio render thread.
final class SpeakerAnalyzer {
    private let queue = DispatchQueue(label: "SpikDoum.speaker", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "SpikDoum.speaker.output")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var stopped = false
    var onInterval: ((SpeakerInterval) -> Void)?
    var onStatus: ((String) -> Void)?

    func start() throws {
        guard let resources = Bundle.main.resourceURL else { throw CaptureError.message("화자 분석 리소스가 없습니다.") }
        let executable = resources.appendingPathComponent("SpeakerWorker/SpeakerWorker")
        let model = resources.appendingPathComponent("speaker.onnx")
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: model.path) else {
            throw CaptureError.message("화자 분석 모델이 포함된 앱으로 실행해주세요.")
        }
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.arguments = [model.path]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.outputQueue.async { [weak self] in self?.receive(data) }
        }
        task.terminationHandler = { [weak self] _ in self?.onStatus?("화자 분석이 중지되었습니다. STT는 계속 사용할 수 있습니다.") }
        process = task
        try task.run()
        onStatus?("화자 분석 모델 준비 중…")
    }
    func reset(segment: String) {
        queue.async { [weak self] in self?.write(["kind": "reset", "segment": segment]) }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let data = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let rate = buffer.format.sampleRate
        queue.async { [weak self] in self?.write(["kind": "audio", "rate": rate, "audio": data.base64EncodedString()]) }
    }
    private func write(_ object: [String: Any]) {
        guard !stopped, let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.write(contentsOf: data)
        } catch {
            stopped = true
            onStatus?("화자 분석 연결이 종료되었습니다.")
        }
    }
    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if let interval = try? JSONDecoder().decode(SpeakerInterval.self, from: line) { onInterval?(interval) }
            else if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if let error = object["error"] as? String { onStatus?("화자 분석 실패: \(error)") }
                else if object["status"] as? String == "ready" { onStatus?("화자 분석 중 · 약 2초 단위 추정") }
            }
        }
    }
    func stop() {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        // Terminate before closing the input so a blocked pipe write can finish.
        queue.async { [weak self] in
            self?.stopped = true
            try? self?.input?.close()
        }
    }
    deinit { process?.terminate() }
}
