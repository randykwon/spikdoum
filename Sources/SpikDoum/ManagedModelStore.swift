import Foundation
import CryptoKit

struct ManagedModelStore: Sendable {
    let root: URL
    func file(_ model: ManagedModel) -> URL { root.appendingPathComponent(model.filename) }
    func receipt(_ model: ManagedModel) -> URL { root.appendingPathComponent(model.id + ".verified") }
    func installed(_ model: ManagedModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file(model).path)[.size] as? NSNumber)?.int64Value
        if model.isCustom { return (size ?? 0) > 0 }
        return size == model.bytes && (try? String(contentsOf: receipt(model), encoding: .utf8)) == model.sha256
    }
    func finalize(_ temporary: URL, model: ManagedModel, cancelled: () -> Bool = { false }) throws {
        guard let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber, size.int64Value == model.bytes else {
            throw CloudFailure(message: "모델 파일 크기가 일치하지 않습니다. 다시 다운로드해주세요.")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            if cancelled() { throw CancellationError() }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else { throw CloudFailure(message: "모델 SHA-256 검증에 실패했습니다. 손상된 파일은 적용하지 않습니다.") }
        if cancelled() { throw CancellationError() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Installation is published only after the complete file has been verified.
        if FileManager.default.fileExists(atPath: file(model).path) { try FileManager.default.removeItem(at: file(model)) }
        try FileManager.default.moveItem(at: temporary, to: file(model))
        try model.sha256.write(to: receipt(model), atomically: true, encoding: .utf8)
    }
    func remove(_ model: ManagedModel) throws {
        for path in [receipt(model), file(model)] where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

final class ManagedModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: ManagedModel
    private let store: ManagedModelStore
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var lastProgress = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    var progress: ((Double, Bool) -> Void)?
    var completion: ((Result<Void, Error>) -> Void)?
    init(model: ManagedModel, store: ManagedModelStore) { self.model = model; self.store = store }
    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session!.downloadTask(with: model.url)
        task!.resume()
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); task?.cancel() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }; completed = true
        completion?(result); session?.finishTasksAndInvalidate(); session = nil; task = nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(lastProgress) > 0.2 else { return }
        lastProgress = Date(); progress?(min(1, Double(totalBytesWritten) / Double(model.bytes)), false)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw CloudFailure(message: "모델 다운로드 서버가 정상 파일을 반환하지 않았습니다.") }
            progress?(1, true)
            try store.finalize(location, model: model, cancelled: isCancelled)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
}
