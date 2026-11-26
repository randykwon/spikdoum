import Foundation
import AVFoundation
import AudioToolbox

struct DeepgramResult: Decodable {
    var type: String
    var start: Double?
    var duration: Double?
    var isFinal: Bool?
    var channel: Channel?
    struct Channel: Decodable { var alternatives: [Alternative] }
    struct Alternative: Decodable { var transcript: String; var words: [Word]? }
    struct Word: Decodable { var word: String; var punctuatedWord: String?; var start: Double; var speaker: Int? }
}
struct DeepgramTranscript {
    private var finalized: [Int: DeepgramResult] = [:]
    private var interim: DeepgramResult?
    mutating func apply(_ result: DeepgramResult) {
        guard result.type == "Results", let start = result.start else { return }
        let key = Int((start * 1000).rounded())
        if result.isFinal == true {
            finalized[key] = result
            if (interim?.start ?? -.infinity) <= start { interim = nil }
        } else {
            let finalEnd = finalized.values.map { ($0.start ?? 0) + ($0.duration ?? 0) }.max() ?? -.infinity
            guard finalized[key] == nil, start >= finalEnd - 0.001 else { return }
            if start >= (interim?.start ?? -.infinity) { interim = result }
        }
    }
    var stable: String { finalized.sorted { $0.key < $1.key }.compactMap { $0.value.channel?.alternatives.first?.transcript }.filter { !$0.isEmpty }.joined(separator: "\n") }
    var full: String { [stable, interim?.channel?.alternatives.first?.transcript ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") }
    var turns: [SpeakerTurn] {
        let results = finalized.sorted { $0.key < $1.key }.map(\.value) + (interim.map { [$0] } ?? [])
        var turns: [SpeakerTurn] = []
        for result in results {
            guard let alternative = result.channel?.alternatives.first else { continue }
            if let words = alternative.words, !words.isEmpty {
                for word in words {
                    let speaker = word.speaker.map { $0 + 1 }
                    if turns.last?.speaker == speaker, !turns.isEmpty { turns[turns.count - 1].text += " " + (word.punctuatedWord ?? word.word) }
                    else { turns.append(SpeakerTurn(id: "dg-\(word.start)", speaker: speaker, start: word.start, text: word.punctuatedWord ?? word.word)) }
                }
            } else if !alternative.transcript.isEmpty {
                turns.append(SpeakerTurn(id: "dg-\(result.start ?? 0)", speaker: nil, start: result.start ?? 0, text: alternative.transcript))
            }
        }
        return turns
    }
}

final class PCMStreamSender {
    private let conversionQueue = DispatchQueue(label: "SpikDoum.PCM", qos: .userInitiated)
    private let continuation: AsyncStream<Data>.Continuation
    private var sending: Task<Void, Never>?
    var onError: ((String) -> Void)?
    init(socket: URLSessionWebSocketTask) {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(40))
        continuation = pair.continuation
        sending = Task { [weak self] in
            do {
                for await data in pair.stream {
                    try Task.checkCancellation()
                    try await socket.send(.data(data))
                }
            } catch { if !Task.isCancelled { self?.onError?("오디오 전송이 중단되었습니다. 네트워크를 확인해주세요.") } }
        }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let bytes = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        conversionQueue.async { [weak self] in
            guard let self else { return }
            let pcm = bytes.withUnsafeBytes { source -> Data in
                let floats = source.bindMemory(to: Float.self)
                let samples = floats.map { sample -> Int16 in
                    let finite = sample.isFinite ? sample : 0
                    return Int16(max(-32768, min(32767, Int(finite * 32767)))).littleEndian
                }
                return samples.withUnsafeBytes { Data($0) }
            }
            if case .dropped = self.continuation.yield(pcm) {
                self.onError?("네트워크 전송이 음성을 따라가지 못해 듣기를 중지했습니다. 연결을 확인해주세요.")
                self.stop()
            }
        }
    }
    func stop() { continuation.finish(); sending?.cancel() }
    deinit { continuation.finish(); sending?.cancel() }
}

@MainActor
final class CloudSpeechCapture {
    private var engine: AVAudioEngine?
    private var socket: URLSessionWebSocketTask?
    private var sender: PCMStreamSender?
    private var receiving: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var token = UUID()
    private var routeObserver: NSObjectProtocol?
    nonisolated static func request(key: String, sampleRate: Int, language: String) -> URLRequest {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var params = ["model": "nova-3", "language": "multi", "encoding": "linear16", "sample_rate": String(sampleRate), "channels": "1", "diarize_model": "v1", "interim_results": "true", "smart_format": "true", "endpointing": "300"]
        if language != LanguageCatalog.autoCode {
            params["language_hint"] = LanguageCatalog.whisperLanguageParameter(for: language)
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }
    func start(key: String, inputDeviceUID: String, language: String, onUpdate: @escaping (String, String, [SpeakerTurn]) -> Void, onError: @escaping (String) -> Void, onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) async throws {
        guard !key.isEmpty else { throw CloudFailure(message: "엔진 설정에서 Deepgram API 키를 저장해주세요.") }
        try await AudioPermissions.microphone()
        let configured = try AudioInputDevices.configuredEngine(uid: inputDeviceUID)
        let engine = configured.engine
        let input = engine.inputNode
        let format = configured.format
        let socket = URLSession.shared.webSocketTask(with: Self.request(key: key, sampleRate: Int(format.sampleRate), language: language))
        self.socket = socket
        socket.resume()
        do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        } } catch { socket.cancel(with: .goingAway, reason: nil); throw CloudFailure(message: "Deepgram 연결 실패. API 키·사용 한도·네트워크를 확인해주세요.") }
        let sessionToken = UUID()
        token = sessionToken
        let sender = PCMStreamSender(socket: socket)
        sender.onError = { error in Task { @MainActor in onError(error) } }
        self.sender = sender
        self.engine = engine
        receiving = Task { [weak self] in
            var transcript = DeepgramTranscript()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard let self, self.token == sessionToken else { return }
                    let result = try decoder.decode(DeepgramResult.self, from: data)
                    if result.type == "Error" { throw CloudFailure(message: "Deepgram에서 음성 처리 오류를 반환했습니다.") }
                    if result.type == "Results" { transcript.apply(result); onUpdate(transcript.full, transcript.stable, transcript.turns) }
                }
            } catch { if !Task.isCancelled, self?.token == sessionToken { onError("[CLOUD_STT_RECONNECT] 클라우드 STT 연결 종료: \(error.localizedDescription)") } }
        }
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                do { try await socket.send(.string("{\"type\":\"KeepAlive\"}")) }
                catch { return }
            }
        }
        let audioStartedAt = Date()
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.token == sessionToken else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard self.token == sessionToken else { return }
                if engine.isRunning && Date().timeIntervalSince(audioStartedAt) < 1.5 { return }
                if engine.isRunning { return }
                onError("[AUDIO_ROUTE_CHANGED] Bluetooth 입력 형식이 변경되었습니다.")
            }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sender.append(buffer)
            onAudioBuffer?(buffer)
        }
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
        token = UUID()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        sender?.stop(); sender = nil
        receiving?.cancel(); heartbeat?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    }
}
