import Foundation
import AVFoundation
import CryptoKit
import Darwin
import Testing
@testable import SpikDoum

private func fixtureModel(data: Data, hash: String? = nil) -> ManagedModel {
    ManagedModel(id: "test-model", name: "Test", role: .stt, repository: "test/test", revision: String(repeating: "a", count: 40), filename: "test.bin", bytes: Int64(data.count), sha256: hash ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), note: "test")
}
@Test func managedModelInstallationValidatesBytesHashAndReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("model contents".utf8), temporary = root.appendingPathComponent("download.part")
    let store = ManagedModelStore(root: root.appendingPathComponent("models")), model = fixtureModel(data: data)
    try data.write(to: temporary)
    try store.finalize(temporary, model: model)
    #expect(store.installed(model))
    #expect(try Data(contentsOf: store.file(model)) == data)
    try store.remove(model)
    #expect(!store.installed(model))
    try data.write(to: temporary)
    #expect(throws: (any Error).self) { try store.finalize(temporary, model: fixtureModel(data: data, hash: String(repeating: "0", count: 64))) }
    #expect(!FileManager.default.fileExists(atPath: store.file(model).path))
}
@Test func managedModelCancellationAndTruncationNeverPublishAnInstalledModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data(repeating: 7, count: 100), temporary = root.appendingPathComponent("download.part")
    let store = ManagedModelStore(root: root.appendingPathComponent("models")), model = fixtureModel(data: data)
    try Data(data.prefix(20)).write(to: temporary)
    #expect(throws: (any Error).self) { try store.finalize(temporary, model: model) }
    try data.write(to: temporary)
    #expect(throws: (any Error).self) { try store.finalize(temporary, model: model, cancelled: { true }) }
    #expect(!store.installed(model))
}
@Test func managedCatalogUsesPinnedVerifiedModelsAndLoopbackArguments() {
    #expect(Set(ManagedModelCatalog.all.map(\.id)).count == ManagedModelCatalog.all.count)
    #expect(Set(ManagedModelCatalog.all.map(\.filename)).count == ManagedModelCatalog.all.count)
    #expect(ManagedModelCatalog.all.filter { $0.role == .stt }.count >= 9)
    #expect(ManagedModelCatalog.all.filter { $0.role == .translation }.count >= 10)
    for model in ManagedModelCatalog.all {
        #expect(model.url.scheme == "https")
        #expect(model.revision.count == 40)
        #expect(model.sha256.count == 64)
        #expect(model.bytes > 0)
    }
    for role in ManagedRole.allCases {
        let path = URL(fileURLWithPath: "/tmp/a model/file.bin")
        let args = ManagedModelManager.arguments(role: role, model: path)
        #expect(args.contains(path.path))
        #expect(args.contains("127.0.0.1"))
        #expect(!args.contains("0.0.0.0"))
        if role == .translation {
            #expect(args.contains("--reasoning"))
            #expect(args.contains("off"))
        }
    }
    #expect(ManagedModelManager.stripThinkingTags("<think>internal reasoning</think>\n안녕하세요.") == "안녕하세요.")
}

@MainActor @Test func customLocalModelImportSelectAndRemoveWorkCleanly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let suite = "SpikDoum.CustomModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let sourceGGUF = root.appendingPathComponent("MyCustomTranslator.gguf")
    try Data("gguf-bytes".utf8).write(to: sourceGGUF)

    let manager = ManagedModelManager(root: root.appendingPathComponent("models"), defaults: defaults)
    defer { manager.shutdown() }

    // Reject wrong extension for STT.
    #expect(throws: (any Error).self) { try manager.importCustomModel(from: sourceGGUF, role: .stt) }

    let imported = try manager.importCustomModel(from: sourceGGUF, role: .translation)
    #expect(imported.isCustom)
    #expect(manager.installed.contains(imported.id))
    await manager.select(imported)
    #expect(manager.selected(.translation)?.id == imported.id)

    await manager.remove(imported)
    #expect(!manager.installed.contains(imported.id))
    #expect(manager.customModels.isEmpty)
}
@Test func managedSTTProducesValidPCMHeaderAndAuthenticatedMultipartUpload() throws {
    let pcm = Data([1, 0, 2, 0]), wave = ManagedSTTClient.wave(pcm: pcm)
    #expect(wave.count == 48)
    #expect(String(data: wave.prefix(4), encoding: .utf8) == "RIFF")
    #expect(String(data: wave.subdata(in: 36..<40), encoding: .utf8) == "data")
    #expect(wave.suffix(4) == pcm)
    let request = ManagedSTTClient(key: "test-token").request(wave: wave, language: "en-US")
    #expect(request.url?.host == "127.0.0.1")
    #expect(request.url?.path == "/inference")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    let body = request.httpBody!
    #expect(body.range(of: wave) != nil)
    #expect(String(decoding: body, as: UTF8.self).contains("name=\"language\"\r\n\r\nen"))
}
@Test func managedPortProbeDoesNotAdoptOrTerminateAnExistingServer() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0); defer { close(fd) }
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    #expect(bound == 0); #expect(listen(fd, 1) == 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
    #expect(!ManagedModelManager.portAvailable(Int(UInt16(bigEndian: address.sin_port))))
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SPIKDOUM_MANAGED_E2E"] == "1"))
func managedRuntimeDownloadsTranscribesTranslatesAndRestarts() async throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let manager = ManagedModelManager(runtimeRoot: cwd.appendingPathComponent(".runtime-build/bin"))
    defer { manager.shutdown() }
    let stt = try #require(ManagedModelCatalog.model("whisper-base"))
    let translation = try #require(ManagedModelCatalog.model("qwen25-15b-q4"))
    for item in [stt, translation] {
        print("MANAGED E2E: downloading/verifying \(item.id)")
        try await manager.download(item)
        #expect(manager.installed.contains(item.id))
        await manager.select(item)
    }
    print("MANAGED E2E: starting STT")
    try await manager.ensureReady(.stt)
    let sttPID = manager.servers[.stt]?.pid
    let wave = try Data(contentsOf: cwd.appendingPathComponent(".runtime-src/whisper/samples/jfk.wav"))
    let speech = try await ManagedSTTClient(key: manager.authorization(.stt)).transcribe(wave: wave, language: "en")
    #expect(speech.lowercased().contains("country"))
    print("MANAGED E2E: STT confirmed")
    await #expect(throws: (any Error).self) { try await ManagedSTTClient(key: "invalid-key").transcribe(wave: wave, language: "en") }
    let capture = ManagedSpeechCapture()
    var captured = ""
    var captureError: String?
    try await capture.start(language: "en-US", externalAudio: true, inputDeviceUID: "", key: manager.authorization(.stt), onText: { captured = $0 }, onError: { captureError = $0 }, onLatency: { manager.record(.stt, latency: $0) })
    let audio = try AVAudioFile(forReading: cwd.appendingPathComponent(".runtime-src/whisper/samples/jfk.wav"))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 2048))
    while audio.framePosition < audio.length {
        try audio.read(into: buffer, frameCount: 2048)
        capture.appendExternalAudio(buffer)
        await Task.yield()
    }
    await capture.finish(); capture.stop()
    #expect(captureError == nil)
    #expect(captured.lowercased().contains("country"))
    print("MANAGED E2E: PCM capture, conversion and final drain confirmed")
    print("MANAGED E2E: starting translation")
    let translated = try await manager.translate("Hello. How are you?", source: "en")
    #expect(translated.range(of: "[가-힣]", options: .regularExpression) != nil)
    let translationPID = manager.servers[.translation]?.pid
    print("MANAGED E2E: Korean translation confirmed")
    try await manager.restart(.stt)
    try await manager.restart(.translation)
    #expect(manager.servers[.stt]?.pid != sttPID)
    #expect(manager.servers[.translation]?.pid != translationPID)
    await manager.poll()
    #expect(manager.servers[.stt]?.memoryMB ?? 0 > 0)
    #expect(manager.servers[.translation]?.memoryMB ?? 0 > 0)
    await manager.stop(.stt); await manager.stop(.translation)
    #expect(manager.servers[.stt]?.pid == nil)
    #expect(manager.servers[.translation]?.pid == nil)
    print("MANAGED E2E: restart, monitoring and stop confirmed")
}

@Test func managedAudioConvertsStereo48kAndDrainsTheFinalPartialChunk() async throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    final class Collected: @unchecked Sendable {
        let lock = NSLock(); var bytes = 0; var chunks = 0
        func append(_ data: Data) { lock.lock(); bytes += data.count; chunks += 1; lock.unlock() }
        func value() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (bytes, chunks) }
    }
    let collected = Collected(), sink = ManagedAudioBufferer()
    sink.start { collected.append($0) }
    var cursor = 0
    while cursor < 48000 * 4 {
        let count = min(1024, 48000 * 4 - cursor)
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            for i in 0..<count { buffer.floatChannelData![channel][i] = Float(sin(Double(cursor + i) * 2 * .pi * 440 / 48000)) * 0.2 }
        }
        sink.append(buffer); cursor += count
    }
    let tail = await sink.finish()
    let result = collected.value()
    #expect(result.1 == 1)
    #expect(tail != nil)
    #expect((127000...128100).contains(result.0 + (tail?.count ?? 0)))
}
