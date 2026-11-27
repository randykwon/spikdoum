import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct LearningScreenCapture: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var filename: String
    var capturedAt: Date = Date()
    var windowTitle: String
    var appName: String
    var transcriptExcerpt: String
    var translationExcerpt: String? = nil
    var userNote: String = ""
    var autoCaptured: Bool = false
    var sourceSpanID: UUID? = nil
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
}

struct ShareableWindowInfo: Identifiable, Equatable, Sendable {
    var id: CGWindowID
    var appName: String
    var bundleID: String
    var title: String
    var width: Int
    var height: Int

    var displayLabel: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return "\(appName) (\(width)×\(height))"
        }
        let shortTitle = trimmedTitle.count > 44 ? String(trimmedTitle.prefix(44)) + "…" : trimmedTitle
        return "\(appName) · \(shortTitle)"
    }
}

/// Fast, zero-dependency perceptual slide-change detector using a 16×16 grayscale luminance grid.
/// Distinguishes genuine slide/code/page changes from tiny cursor moves or video scrub ticks.
enum LearningScreenDiff {
    static let defaultThreshold: Double = 0.055

    static func luminanceFingerprint(of image: CGImage, grid: Int = 16) -> [UInt8] {
        let side = max(4, grid)
        var pixels = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return pixels
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    static func normalizedDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 1.0 }
        var totalDiff: Int = 0
        for i in 0..<lhs.count {
            totalDiff += abs(Int(lhs[i]) - Int(rhs[i]))
        }
        return Double(totalDiff) / (Double(lhs.count) * 255.0)
    }

    static func shouldSaveAutoCapture(
        previousFingerprint: [UInt8]?,
        currentFingerprint: [UInt8],
        threshold: Double = defaultThreshold
    ) -> Bool {
        guard let previousFingerprint, !previousFingerprint.isEmpty else { return true }
        return normalizedDifference(previousFingerprint, currentFingerprint) >= threshold
    }
}

/// Silently captures a chosen online-education window via ScreenCaptureKit (`SCScreenshotManager.captureImage`)
/// with zero shutter sound, zero screen flash, and zero focus steal — even while SpikDoum sits in front of it.
@MainActor
final class LearningWindowCapturer: ObservableObject {
    @Published private(set) var availableWindows: [ShareableWindowInfo] = []
    @Published var selectedWindowID: CGWindowID? = nil {
        didSet {
            if oldValue != selectedWindowID {
                lastFingerprint = nil
            }
        }
    }
    @Published var autoCaptureEnabled: Bool = UserDefaults.standard.bool(forKey: "learningAutoScreenCaptureV1") {
        didSet { UserDefaults.standard.set(autoCaptureEnabled, forKey: "learningAutoScreenCaptureV1") }
    }
    @Published var changeDetectionOnly: Bool = (UserDefaults.standard.object(forKey: "learningCaptureOnlyOnChangeV1") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(changeDetectionOnly, forKey: "learningCaptureOnlyOnChangeV1") }
    }
    @Published var intervalSeconds: Int = {
        let saved = UserDefaults.standard.integer(forKey: "learningCaptureIntervalSecV1")
        return [5, 10, 15, 30].contains(saved) ? saved : 5
    }() {
        didSet { UserDefaults.standard.set(intervalSeconds, forKey: "learningCaptureIntervalSecV1") }
    }
    @Published private(set) var isCapturing = false
    @Published var lastError: String? = nil

    private var lastFingerprint: [UInt8]? = nil

    var selectedWindow: ShareableWindowInfo? {
        guard let id = selectedWindowID else { return availableWindows.first }
        return availableWindows.first(where: { $0.id == id }) ?? availableWindows.first
    }

    func resetChangeFingerprint() {
        lastFingerprint = nil
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let ownBundle = Bundle.main.bundleIdentifier ?? "dev.spikdoum.app"
            let ignoredBundles: Set<String> = [
                ownBundle,
                "com.apple.dock",
                "com.apple.WindowManager",
                "com.apple.controlcenter",
                "com.apple.notificationcenterui",
                "com.apple.SystemUIServer"
            ]
            let priorityKeywords = ["chrome", "safari", "arc", "edge", "firefox", "brave", "zoom", "teams", "webex", "vlc", "quicktime", "powerpoint", "keynote", "preview", "youtube", "meet"]

            let mapped: [ShareableWindowInfo] = content.windows.compactMap { win in
                guard let app = win.owningApplication else { return nil }
                let bid = app.bundleIdentifier
                if ignoredBundles.contains(bid) { return nil }
                let w = Int(win.frame.width.rounded())
                let h = Int(win.frame.height.rounded())
                guard w >= 240, h >= 160 else { return nil }
                let title = (win.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let appName = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !appName.isEmpty else { return nil }
                // Filter out invisible helper windows with empty titles unless it's a known media/browser app.
                if title.isEmpty && !priorityKeywords.contains(where: { bid.lowercased().contains($0) || appName.lowercased().contains($0) }) {
                    return nil
                }
                return ShareableWindowInfo(
                    id: win.windowID,
                    appName: appName,
                    bundleID: bid,
                    title: title,
                    width: w,
                    height: h
                )
            }

            let sorted = mapped.sorted { a, b in
                let aPrio = priorityKeywords.contains(where: { a.bundleID.lowercased().contains($0) || a.appName.lowercased().contains($0) })
                let bPrio = priorityKeywords.contains(where: { b.bundleID.lowercased().contains($0) || b.appName.lowercased().contains($0) })
                if aPrio != bPrio { return aPrio }
                let aArea = a.width * a.height
                let bArea = b.width * b.height
                return aArea > bArea
            }

            availableWindows = sorted
            if let currentID = selectedWindowID, !sorted.contains(where: { $0.id == currentID }) {
                selectedWindowID = sorted.first?.id
            } else if selectedWindowID == nil {
                selectedWindowID = sorted.first?.id
            }
            lastError = nil
        } catch {
            lastError = "화면 캡처 권한을 확인해주세요: \(error.localizedDescription)"
        }
    }

    struct CaptureOutcome: Sendable {
        var filename: String
        var windowTitle: String
        var appName: String
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// Captures the target online-education window silently with zero shutter sound or visual flash.
    /// Returns `.success(nil)` when `onlyIfChanged == true` and the screen content has not meaningfully changed.
    func captureSilently(
        conversationID: UUID,
        recordingsRoot: URL,
        onlyIfChanged: Bool
    ) async -> Result<CaptureOutcome?, CloudFailure> {
        guard !isCapturing else { return .success(nil) }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            var targetID = selectedWindowID
            if targetID == nil || !content.windows.contains(where: { $0.windowID == targetID }) {
                await refreshWindows()
                targetID = selectedWindowID
            }
            guard let chosenID = targetID,
                  let scWindow = content.windows.first(where: { $0.windowID == chosenID }) else {
                return .failure(CloudFailure(message: "캡처할 교육 창을 찾지 못했습니다. 상단에서 캡처할 창을 선택해주세요."))
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let rawWidth = max(320, Int(scWindow.frame.width * 2))
            let rawHeight = max(200, Int(scWindow.frame.height * 2))
            let maxWidth = 1600
            if rawWidth > maxWidth {
                let scale = Double(maxWidth) / Double(rawWidth)
                config.width = maxWidth
                config.height = max(200, Int((Double(rawHeight) * scale).rounded()))
            } else {
                config.width = rawWidth
                config.height = rawHeight
            }
            config.showsCursor = false
            config.scalesToFit = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let fingerprint = LearningScreenDiff.luminanceFingerprint(of: cgImage)
            if onlyIfChanged && !LearningScreenDiff.shouldSaveAutoCapture(
                previousFingerprint: lastFingerprint,
                currentFingerprint: fingerprint
            ) {
                return .success(nil)
            }
            lastFingerprint = fingerprint

            let folder = RecordingStorage.conversationFolder(for: conversationID, root: recordingsRoot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = "screen-\(UUID().uuidString).jpg"
            let url = folder.appendingPathComponent(filename)

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else {
                return .failure(CloudFailure(message: "캡처 이미지 인코딩에 실패했습니다."))
            }
            try jpegData.write(to: url, options: .atomic)

            let appName = scWindow.owningApplication?.applicationName ?? "창"
            let title = (scWindow.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = nil
            return .success(CaptureOutcome(
                filename: filename,
                windowTitle: title.isEmpty ? appName : title,
                appName: appName,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height
            ))
        } catch {
            let msg = "화면 캡처 실패: \(error.localizedDescription)"
            lastError = msg
            return .failure(CloudFailure(message: msg))
        }
    }
}
