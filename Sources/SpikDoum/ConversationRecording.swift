import Foundation
import AVFoundation

struct AudioClipRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var filename: String
    var startedAt: Date
    var endedAt: Date
    var duration: Double
    var sourceSummary: String
}

enum RecordingStorage {
    static func recordingsRoot(nextTo conversationsFile: URL) -> URL {
        conversationsFile.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
    }

    static func conversationFolder(for conversationID: UUID, root: URL) -> URL {
        root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    static func clipURL(conversationID: UUID, filename: String, root: URL) -> URL {
        conversationFolder(for: conversationID, root: root).appendingPathComponent(filename)
    }
}

/// Records microphone and/or Mac system playback audio into a compact AAC (.m4a) file off the audio render thread.
/// Mixes dual sources into a single time-aligned mono track and finalizes synchronously on stop so clips are never corrupted.
final class ConversationAudioRecorder: @unchecked Sendable {
    enum Source { case mic, system }

    private static let sampleRate: Double = 24000
    private static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "SpikDoum.AudioRecorder", qos: .utility)
    private var active = false
    private var dualSource = false
    private var file: AVAudioFile?
    private var clipID = UUID()
    private var filename = ""
    private var fileURL: URL?
    private var startedAt = Date()
    private var sourceSummary = ""
    private var writtenFrames: Int64 = 0
    private var converters: [Source: (format: AVAudioFormat, converter: AVAudioConverter)] = [:]
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []

    func start(conversationID: UUID, recordingsRoot: URL, dualSource: Bool, sourceSummary: String) throws {
        var startupError: Error?
        queue.sync {
            self.resetState()
            let folder = RecordingStorage.conversationFolder(for: conversationID, root: recordingsRoot)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let id = UUID()
                let name = "\(id.uuidString).m4a"
                let url = folder.appendingPathComponent(name)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
                let audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                self.file = audioFile
                self.clipID = id
                self.filename = name
                self.fileURL = url
                self.startedAt = Date()
                self.dualSource = dualSource
                self.sourceSummary = sourceSummary
                self.writtenFrames = 0
                self.active = true
            } catch {
                startupError = error
            }
        }
        if let startupError { throw startupError }
    }

    func append(_ buffer: AVAudioPCMBuffer, source: Source) {
        guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            self?.consume(copy, source: source)
        }
    }

    func stopAndFinalize() -> AudioClipRecord? {
        queue.sync {
            guard active else { return nil }
            active = false
            if dualSource {
                flushDual(drainAll: true)
            }
            let frames = writtenFrames
            let url = fileURL
            let id = clipID
            let name = filename
            let start = startedAt
            let summary = sourceSummary
            // Closing AVAudioFile flushes the AAC encoder and writes the MP4 moov atom.
            file = nil
            resetState()

            let duration = Double(frames) / Self.sampleRate
            guard duration >= 0.25, let url, FileManager.default.fileExists(atPath: url.path) else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return nil
            }
            return AudioClipRecord(
                id: id,
                filename: name,
                startedAt: start,
                endedAt: start.addingTimeInterval(duration),
                duration: duration,
                sourceSummary: summary
            )
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, source: Source) {
        guard active, file != nil else { return }
        guard let samples = convertToMono(buffer, source: source), !samples.isEmpty else { return }

        if !dualSource {
            padGapIfNeeded(beforeAdding: samples.count)
            writeSamples(samples)
        } else {
            if source == .mic { micQueue.append(contentsOf: samples) }
            else { systemQueue.append(contentsOf: samples) }
            flushDual(drainAll: false)
        }
    }

    private func padGapIfNeeded(beforeAdding incomingCount: Int) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let expectedFrames = Int64(elapsed * Self.sampleRate)
        let gap = expectedFrames - writtenFrames - Int64(incomingCount)
        // Pad gaps > 200ms (e.g. paused media or device switch) up to 30s so audio stays wall-clock aligned with events.
        let minGap = Int64(Self.sampleRate * 0.20)
        let maxPad = Int64(Self.sampleRate * 30.0)
        guard gap >= minGap else { return }
        var remaining = Int(min(gap, maxPad))
        let silenceChunk = [Float](repeating: 0, count: 4096)
        while remaining > 0 {
            let chunk = min(remaining, silenceChunk.count)
            writeSamples(Array(silenceChunk.prefix(chunk)))
            remaining -= chunk
        }
    }

    private func flushDual(drainAll: Bool) {
        let overlap = min(micQueue.count, systemQueue.count)
        if overlap > 0 {
            var mixed = [Float]()
            mixed.reserveCapacity(overlap)
            for i in 0..<overlap {
                let value = (micQueue[i] + systemQueue[i]) * 0.85
                mixed.append(max(-1.0, min(1.0, value)))
            }
            micQueue.removeFirst(overlap)
            systemQueue.removeFirst(overlap)
            writeSamples(mixed)
        }
        let maxLead = drainAll ? 0 : Int(Self.sampleRate * 0.15)
        if micQueue.count > maxLead {
            let count = micQueue.count - maxLead
            writeSamples(Array(micQueue.prefix(count)))
            micQueue.removeFirst(count)
        }
        if systemQueue.count > maxLead {
            let count = systemQueue.count - maxLead
            writeSamples(Array(systemQueue.prefix(count)))
            systemQueue.removeFirst(count)
        }
    }

    private func convertToMono(_ buffer: AVAudioPCMBuffer, source: Source) -> [Float]? {
        let converter: AVAudioConverter
        if let existing = converters[source], existing.format == buffer.format {
            converter = existing.converter
        } else {
            guard let created = AVAudioConverter(from: buffer.format, to: Self.canonicalFormat) else { return nil }
            converters[source] = (buffer.format, created)
            converter = created
        }
        let ratio = Self.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return nil }
        var result = [Float]()
        result.reserveCapacity(Int(output.frameLength))
        for i in 0..<Int(output.frameLength) {
            let sample = channel[i]
            result.append(sample.isFinite ? max(-1.0, min(1.0, sample)) : 0)
        }
        return result
    }

    private func writeSamples(_ samples: [Float]) {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                memcpy(destination, base, samples.count * MemoryLayout<Float>.size)
            }
        }
        do {
            try file.write(from: buffer)
            writtenFrames += Int64(samples.count)
        } catch {
            // Do not crash live STT if disk fills up; stop recording quietly.
            active = false
        }
    }

    private func resetState() {
        file = nil
        fileURL = nil
        converters.removeAll()
        micQueue.removeAll()
        systemQueue.removeAll()
        writtenFrames = 0
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(source, target) {
            if let from = input.mData, let to = output.mData {
                memcpy(to, from, Int(min(input.mDataByteSize, output.mDataByteSize)))
            }
        }
        return copy
    }
}
