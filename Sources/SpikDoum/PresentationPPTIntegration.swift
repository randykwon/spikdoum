import Foundation
import AppKit
import UniformTypeIdentifiers

struct ImportedPPTSlide: Equatable, Sendable {
    var number: Int
    var title: String
    var bullets: [String]
    var speakerNotes: [String]
}

enum PPTXSlideImporter {
    enum ImportError: LocalizedError {
        case invalidArchive(String)
        case noSlidesFound

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let detail): return "PPTX 파일을 읽지 못했습니다: \(detail)"
            case .noSlidesFound: return "PPTX 파일에서 슬라이드를 찾지 못했습니다."
            }
        }
    }

    @MainActor
    static func pickPPTXFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "PowerPoint(.pptx) 발표 파일 불러오기"
        panel.prompt = "불러오기"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let pptxType = UTType(filenameExtension: "pptx") {
            panel.allowedContentTypes = [pptxType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func importPPTX(from url: URL) throws -> [ImportedPPTSlide] {
        let entries = try listZipEntries(at: url)
        let slideNumbers = entries.compactMap { entry -> Int? in
            guard entry.hasPrefix("ppt/slides/slide"), entry.hasSuffix(".xml") else { return nil }
            let middle = entry.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
            return Int(middle)
        }.sorted()

        guard !slideNumbers.isEmpty else { throw ImportError.noSlidesFound }

        let entrySet = Set(entries)
        var imported: [ImportedPPTSlide] = []
        for num in slideNumbers {
            let slideEntry = "ppt/slides/slide\(num).xml"
            let slideData = try readZipEntry(slideEntry, from: url)
            let slideParagraphs = parseDrawingMLParagraphs(slideData)
                .filter { !isStandaloneSlideNumber($0, slideNumber: num) }

            let title = slideParagraphs.first ?? "슬라이드 \(num)"
            let bullets = Array(slideParagraphs.dropFirst())

            var notes: [String] = []
            let relsEntry = "ppt/slides/_rels/slide\(num).xml.rels"
            var resolvedNoteEntry: String? = nil
            if entrySet.contains(relsEntry), let relsData = try? readZipEntry(relsEntry, from: url) {
                resolvedNoteEntry = parseNotesTarget(fromRels: relsData)
            }
            if resolvedNoteEntry == nil {
                let fallback = "ppt/notesSlides/notesSlide\(num).xml"
                if entrySet.contains(fallback) { resolvedNoteEntry = fallback }
            }
            if let noteEntry = resolvedNoteEntry, let noteData = try? readZipEntry(noteEntry, from: url) {
                notes = parseDrawingMLParagraphs(noteData)
                    .filter { !isStandaloneSlideNumber($0, slideNumber: num) }
            }

            imported.append(ImportedPPTSlide(
                number: num,
                title: String(title.prefix(80)),
                bullets: bullets,
                speakerNotes: notes
            ))
        }
        return imported
    }

    /// Formats imported PowerPoint slides and speaker notes into SpikDoum cue-card Markdown (`# Slide [N분]`).
    static func formatAsCueCardMarkdown(slides: [ImportedPPTSlide], totalMinutes: Int) -> String {
        guard !slides.isEmpty else { return "" }
        let perSlide = max(0.5, Double(max(1, totalMinutes)) / Double(slides.count))
        let defaultDurationTag: String = {
            if perSlide < 1.0 { return "[\(Int((perSlide * 60).rounded()))s]" }
            if abs(perSlide.rounded() - perSlide) < 0.15 { return "[\(Int(perSlide.rounded()))분]" }
            return String(format: "[%.1f분]", perSlide)
        }()

        return slides.map { slide in
            let durationTag = extractExplicitDurationTag(from: slide.speakerNotes) ?? defaultDurationTag
            var lines: [String] = ["# \(slide.number). \(slide.title) \(durationTag)"]
            if !slide.speakerNotes.isEmpty {
                // Preserve full speaker notes (e.g. bilingual Korean + English presenter scripts) without truncating.
                for note in slide.speakerNotes {
                    lines.append("- \(note)")
                }
                if !slide.bullets.isEmpty {
                    lines.append("> 슬라이드 화면: \(slide.bullets.prefix(3).joined(separator: " · "))")
                }
            } else if !slide.bullets.isEmpty {
                for bullet in slide.bullets.prefix(8) {
                    lines.append("- \(bullet)")
                }
            } else {
                lines.append("- (발표 메모를 추가하세요)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Detects an explicit per-slide time allocation written inside speaker notes
    /// (e.g. `예상 배분 시간: 0:45 (누적 0:45)` or `배분 시간: 1:30` or `Time: 2:00`).
    static func extractExplicitDurationTag(from notes: [String]) -> String? {
        guard let timeRegex = try? NSRegularExpression(pattern: #"(?:^|[\s:\(])(\d{1,2}):(\d{2})(?:\b|\s|\)|$)"#) else {
            return nil
        }
        for line in notes.prefix(3) {
            let lower = line.lowercased()
            guard lower.contains("시간") || lower.contains("배분") || lower.contains("time") || lower.contains("duration") else {
                continue
            }
            if let match = timeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let mRange = Range(match.range(at: 1), in: line),
               let sRange = Range(match.range(at: 2), in: line),
               let mins = Int(line[mRange]),
               let secs = Int(line[sRange]),
               secs < 60, (mins > 0 || secs > 0) {
                return String(format: "[%d:%02d]", mins, secs)
            }
        }
        return nil
    }

    /// Parses OOXML `<a:p>` paragraphs (`<a:t>` text runs) cleanly without external dependencies.
    static func parseDrawingMLParagraphs(_ xmlData: Data) -> [String] {
        final class ParagraphXMLDelegate: NSObject, XMLParserDelegate {
            var paragraphs: [String] = []
            private var currentParagraph = ""
            private var insideParagraph = false
            private var insideTextRun = false

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
                if local == "p" {
                    insideParagraph = true
                    currentParagraph = ""
                } else if local == "t" && insideParagraph {
                    insideTextRun = true
                } else if local == "br" && insideParagraph {
                    currentParagraph += " "
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if insideTextRun {
                    currentParagraph += string
                }
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
                if local == "t" {
                    insideTextRun = false
                } else if local == "p" {
                    let cleaned = currentParagraph
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !cleaned.isEmpty {
                        paragraphs.append(cleaned)
                    }
                    insideParagraph = false
                    currentParagraph = ""
                }
            }
        }

        let delegate = ParagraphXMLDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        parser.parse()
        return delegate.paragraphs
    }

    static func parseNotesTarget(fromRels xmlData: Data) -> String? {
        final class RelsDelegate: NSObject, XMLParserDelegate {
            var target: String?
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
                guard local == "Relationship",
                      let type = attributeDict["Type"], type.contains("notesSlide"),
                      let rawTarget = attributeDict["Target"] else { return }
                let cleaned = rawTarget
                    .replacingOccurrences(of: "../", with: "ppt/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                target = cleaned.hasPrefix("ppt/") ? cleaned : "ppt/notesSlides/\(URL(fileURLWithPath: cleaned).lastPathComponent)"
            }
        }
        let delegate = RelsDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        parser.parse()
        return delegate.target
    }

    private static func isStandaloneSlideNumber(_ text: String, slideNumber: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == String(slideNumber)
    }

    private static func listZipEntries(at url: URL) throws -> [String] {
        let output = try runUnzip(arguments: ["-Z1", url.path])
        return String(decoding: output, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func readZipEntry(_ entry: String, from url: URL) throws -> Data {
        try runUnzip(arguments: ["-p", url.path, entry])
    }

    private static func runUnzip(arguments: [String], timeoutSeconds: TimeInterval = 5.0) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ImportError.invalidArchive(error.localizedDescription)
        }
        let readGroup = DispatchGroup()
        var data = Data()
        var errData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = done.wait(timeout: .now() + 0.3)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw ImportError.invalidArchive("PPTX 파일 읽기 시간 초과")
        }
        _ = readGroup.wait(timeout: .now() + 1.0)
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.invalidArchive(msg.isEmpty ? "압축 해제 실패 (코드 \(process.terminationStatus))" : msg)
        }
        return data
    }
}

enum PPTScreenMode: String, Equatable, Sendable {
    case normal
    case black
    case white
    case paused

    var label: String {
        switch self {
        case .normal: return "정상 화면"
        case .black: return "블랙 화면"
        case .white: return "화이트 화면"
        case .paused: return "일시정지"
        }
    }
}

struct PPTSlideSnapshot: Equatable, Sendable {
    var appName: String
    var presentationName: String
    var currentSlide: Int
    var totalSlides: Int
    var isSlideShowRunning: Bool
    var screenMode: PPTScreenMode
    var presentationPath: String = ""
}

enum PPTSlideShowMode: String, CaseIterable, Equatable, Sendable {
    case windowed
    case fullScreen

    static let storageKey = "pptSlideShowModeV1"

    var label: String {
        switch self {
        case .windowed: return "창 모드"
        case .fullScreen: return "전체 화면"
        }
    }

    var appleScriptType: String {
        switch self {
        case .windowed: return "slide show type window"
        case .fullScreen: return "slide show type speaker"
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: storageKey),
              let value = Self(rawValue: raw) else {
            return .windowed
        }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

enum PPTControlAction: Equatable, Sendable {
    case startShowFromBeginning(PPTSlideShowMode)
    case startShowFromCurrent(PPTSlideShowMode)
    case endShow
    case nextSlide
    case previousSlide
    case firstSlide
    case lastSlide
    case goToSlide(Int)
    case toggleBlackScreen
    case toggleWhiteScreen
    case bringToFront
}

enum PPTProviderApp: String, Equatable, Sendable {
    case powerPoint = "PowerPoint"
    case keynote = "Keynote"

    var bundleIdentifier: String {
        switch self {
        case .powerPoint: return "com.microsoft.Powerpoint"
        case .keynote: return "com.apple.iWork.Keynote"
        }
    }

    var applicationName: String {
        switch self {
        case .powerPoint: return "Microsoft PowerPoint"
        case .keynote: return "Keynote"
        }
    }
}

/// Deadlock-free compiled AppleScript runner using `osacompile` + `/usr/bin/osascript` with a hard timeout.
/// Unlike in-process `NSAppleScript` on a background queue (which deadlocks in HIToolbox `WNEInternal` on `delay`),
/// each `/usr/bin/osascript` process runs on its own main thread, skips dictionary recompilation via cached `.scpt` files,
/// and never blocks SpikDoum's UI thread.
private final class AppleScriptExecutor: @unchecked Sendable {
    static let shared = AppleScriptExecutor()
    private let queue = DispatchQueue(label: "SpikDoum.PPT.AppleScript", qos: .userInitiated)
    private let cacheDir: URL
    private var compiledPaths: [String: URL] = [:]

    private init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpikDoum-PPT-Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
    }

    func run(_ source: String, timeoutSeconds: TimeInterval = 8.0) async -> Result<String, CloudFailure> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.runSync(source, timeoutSeconds: timeoutSeconds)
                continuation.resume(returning: result)
            }
        }
    }

    private func runSync(_ source: String, timeoutSeconds: TimeInterval) -> Result<String, CloudFailure> {
        let scriptURL: URL?
        if let existing = compiledPaths[source], FileManager.default.fileExists(atPath: existing.path) {
            scriptURL = existing
        } else {
            let fileURL = cacheDir.appendingPathComponent("ppt-\(Self.stableHash(source)).scpt")
            let compileResult = Self.runProcess(
                executable: "/usr/bin/osacompile",
                arguments: ["-o", fileURL.path, "-e", source],
                timeoutSeconds: 6.0
            )
            if case .success = compileResult, FileManager.default.fileExists(atPath: fileURL.path) {
                if compiledPaths.count > 32 { compiledPaths.removeAll() }
                compiledPaths[source] = fileURL
                scriptURL = fileURL
            } else {
                scriptURL = nil
            }
        }

        let args = scriptURL.map { [$0.path] } ?? ["-e", source]
        return Self.runProcess(executable: "/usr/bin/osascript", arguments: args, timeoutSeconds: timeoutSeconds)
    }

    private static func runProcess(executable: String, arguments: [String], timeoutSeconds: TimeInterval) -> Result<String, CloudFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure(CloudFailure(message: error.localizedDescription))
        }

        // Drain stdout & stderr concurrently while the process runs so >64KB outputs
        // (such as full speaker notes across 20+ slides) never deadlock on the OS pipe buffer.
        let readGroup = DispatchGroup()
        var outData = Data()
        var errData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let waitResult = done.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            if process.isRunning { process.terminate() }
            _ = done.wait(timeout: .now() + 0.5)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            return .failure(CloudFailure(message: "PowerPoint 응답 시간이 초과되었습니다. PowerPoint에 열려 있는 팝업 창이 없는지 확인해주세요."))
        }

        _ = readGroup.wait(timeout: .now() + 1.0)
        if process.terminationStatus == 0 {
            return .success(String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(CloudFailure(message: errText.isEmpty ? "osascript 종료 코드 \(process.terminationStatus)" : errText))
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

/// Polls and controls Microsoft PowerPoint (and Apple Keynote) via macOS AppleScript
/// so presenters can run slide shows, advance/jump slides, toggle blackout screens, and keep
/// SpikDoum's cue cards & floating Presenter HUD bi-directionally synchronized.
@MainActor
final class PPTSlideSyncMonitor: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var connectedApp: String? = nil
    @Published private(set) var presentationName: String? = nil
    @Published private(set) var presentationPath: String? = nil
    @Published private(set) var currentSlideNumber: Int? = nil
    @Published private(set) var totalSlides: Int? = nil
    @Published private(set) var isSlideShowRunning = false
    @Published private(set) var screenMode: PPTScreenMode = .normal
    @Published private(set) var statusLabel = "PPT 연동 꺼짐"
    @Published private(set) var isSendingCommand = false
    @Published var isImportingNotes = false
    @Published var lastControlError: String? = nil
    @Published var autoSyncCueCardsToPPT = true
    @Published var autoImportNotes: Bool = (UserDefaults.standard.object(forKey: "pptAutoImportNotesV1") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoImportNotes, forKey: "pptAutoImportNotesV1") }
    }
    @Published var slideShowMode: PPTSlideShowMode = PPTSlideShowMode.load() {
        didSet { slideShowMode.save() }
    }

    var onSlideChange: ((Int) -> Void)?
    var onDeckSnapshot: ((PPTSlideSnapshot, Bool, Bool) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var lastDeckSignature: String? = nil
    private var wasSlideShowRunning = false

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            statusLabel = "PowerPoint · Keynote 감지 대기…"
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
            statusLabel = connectedApp != nil ? "\(connectedApp!) 연결됨 (자동 추적 꺼짐)" : "PPT 연동 꺼짐"
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isEnabled = false
        connectedApp = nil
        presentationName = nil
        presentationPath = nil
        currentSlideNumber = nil
        totalSlides = nil
        isSlideShowRunning = false
        screenMode = .normal
        lastDeckSignature = nil
        wasSlideShowRunning = false
        statusLabel = "PPT 연동 꺼짐"
    }

    /// Performs a single lightweight status refresh (without forcing continuous polling).
    func refreshNow() {
        Task { [weak self] in
            let snapshot = await Self.queryActiveSnapshot()
            guard let self else { return }
            self.applySnapshot(snapshot, notifySlideChange: self.isEnabled)
        }
    }

    /// Queries the active PowerPoint/Keynote snapshot synchronously from an async context.
    func fetchCurrentSnapshot() async -> PPTSlideSnapshot? {
        let snapshot = await Self.queryActiveSnapshot()
        applySnapshot(snapshot, notifySlideChange: isEnabled)
        return snapshot
    }

    /// Executes a PowerPoint (or Keynote) presentation remote command off the MainActor
    /// and immediately reflects the updated slide state.
    func perform(_ action: PPTControlAction) {
        guard !isSendingCommand else { return }
        isSendingCommand = true
        lastControlError = nil
        Task { [weak self] in
            let outcome = await Self.executeControlAction(action)
            guard let self else { return }
            self.isSendingCommand = false
            switch outcome {
            case .success(let snapshot):
                self.lastControlError = nil
                self.applySnapshot(snapshot, notifySlideChange: true)
            case .failure(let error):
                self.lastControlError = error.localizedDescription
            }
        }
    }

    private func applySnapshot(_ snapshot: PPTSlideSnapshot?, notifySlideChange: Bool) {
        if let snapshot {
            let deckKey = "\(snapshot.appName)|\(snapshot.presentationPath.isEmpty ? snapshot.presentationName : snapshot.presentationPath)|\(snapshot.totalSlides)"
            let deckChanged = (lastDeckSignature != deckKey) && (!snapshot.presentationName.isEmpty || snapshot.totalSlides > 0)
            let becameSlideShow = !wasSlideShowRunning && snapshot.isSlideShowRunning
            lastDeckSignature = deckKey
            wasSlideShowRunning = snapshot.isSlideShowRunning

            connectedApp = snapshot.appName
            presentationName = snapshot.presentationName.isEmpty ? nil : snapshot.presentationName
            presentationPath = snapshot.presentationPath.isEmpty ? nil : snapshot.presentationPath
            totalSlides = snapshot.totalSlides > 0 ? snapshot.totalSlides : nil
            isSlideShowRunning = snapshot.isSlideShowRunning
            screenMode = snapshot.screenMode
            let totalSuffix = snapshot.totalSlides > 0 ? "/\(snapshot.totalSlides)" : ""
            let showBadge = snapshot.isSlideShowRunning ? " · 쇼 진행 중" : ""
            statusLabel = "\(snapshot.appName) #\(snapshot.currentSlide)\(totalSuffix)\(showBadge)"
            if currentSlideNumber != snapshot.currentSlide {
                currentSlideNumber = snapshot.currentSlide
                if notifySlideChange {
                    onSlideChange?(snapshot.currentSlide)
                }
            }
            if deckChanged || becameSlideShow {
                onDeckSnapshot?(snapshot, becameSlideShow, deckChanged)
            }
        } else {
            connectedApp = nil
            presentationName = nil
            presentationPath = nil
            currentSlideNumber = nil
            totalSlides = nil
            isSlideShowRunning = false
            screenMode = .normal
            lastDeckSignature = nil
            wasSlideShowRunning = false
            statusLabel = isEnabled ? "PowerPoint · Keynote 창 대기 중" : "PPT 연동 꺼짐"
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Self.queryActiveSnapshot()
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.applySnapshot(snapshot, notifySlideChange: true)
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    // MARK: - Pure AppleScript Parsing & Generation (Unit-Testable)

    nonisolated static func parseSnapshot(_ raw: String) -> PPTSlideSnapshot? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let mainPart: String
        let pathPart: String
        if let tabIdx = line.firstIndex(of: "\t") {
            mainPart = String(line[..<tabIdx])
            pathPart = String(line[line.index(after: tabIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            mainPart = line
            pathPart = ""
        }
        let parts = mainPart.components(separatedBy: "|")
        guard parts.count >= 2, let slideNum = Int(parts[1].trimmingCharacters(in: .whitespaces)), slideNum >= 1 else {
            return nil
        }
        let appName = parts[0].trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty else { return nil }
        let total = parts.count >= 3 ? (Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
        let running = parts.count >= 4 ? (parts[3].trimmingCharacters(in: .whitespaces) == "1") : false
        let modeRaw = parts.count >= 5 ? parts[4].trimmingCharacters(in: .whitespaces).lowercased() : "normal"
        let mode: PPTScreenMode
        if modeRaw.contains("black") { mode = .black }
        else if modeRaw.contains("white") { mode = .white }
        else if modeRaw.contains("pause") { mode = .paused }
        else { mode = .normal }
        let deckName = parts.count >= 6 ? parts[5...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return PPTSlideSnapshot(
            appName: appName,
            presentationName: deckName,
            currentSlide: slideNum,
            totalSlides: max(0, total),
            isSlideShowRunning: running,
            screenMode: mode,
            presentationPath: pathPart
        )
    }

    private nonisolated static let powerPointStatusSnippet: String = """
        on pptStatus()
            tell application "Microsoft PowerPoint"
                set totalCnt to 0
                set deckName to ""
                set deckPath to ""
                try
                    set totalCnt to count of slides of active presentation
                end try
                try
                    set deckName to name of active presentation as string
                end try
                try
                    set deckPath to full name of active presentation as string
                end try
                if (count of slide show windows) > 0 then
                    set ssv to slide show view of slide show window 1
                    set curIdx to 1
                    try
                        set curIdx to slide index of slide of ssv
                    on error
                        try
                            set curIdx to current show position of ssv
                        end try
                    end try
                    set stText to "normal"
                    try
                        set stVal to slide state of ssv
                        if stVal is slide show state black screen then
                            set stText to "black"
                        else if stVal is slide show state white screen then
                            set stText to "white"
                        else if stVal is slide show state paused then
                            set stText to "paused"
                        end if
                    end try
                    return "PowerPoint|" & (curIdx as string) & "|" & (totalCnt as string) & "|1|" & stText & "|" & deckName & tab & deckPath
                else if (count of document windows) > 0 then
                    set curIdx to 1
                    try
                        set curIdx to slide index of slide of view of active window
                    end try
                    return "PowerPoint|" & (curIdx as string) & "|" & (totalCnt as string) & "|0|normal|" & deckName & tab & deckPath
                end if
            end tell
            return ""
        end pptStatus
    """

    private nonisolated static let keynoteStatusSnippet: String = """
        on keynoteStatus()
            tell application "Keynote"
                if (count of documents) > 0 then
                    set doc to front document
                    set curIdx to slide number of current slide of doc
                    set totalCnt to count of slides of doc
                    set isPlaying to "0"
                    try
                        if playing then set isPlaying to "1"
                    end try
                    set deckName to ""
                    try
                        set deckName to name of doc as string
                    end try
                    set deckPath to ""
                    try
                        set deckPath to POSIX path of (file of doc as alias)
                    end try
                    return "Keynote|" & (curIdx as string) & "|" & (totalCnt as string) & "|" & isPlaying & "|normal|" & deckName & tab & deckPath
                end if
            end tell
            return ""
        end keynoteStatus
    """

    nonisolated static func runningPresentationApps() -> [PPTProviderApp] {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var found: [PPTProviderApp] = []
        if runningBundleIDs.contains(PPTProviderApp.powerPoint.bundleIdentifier) {
            found.append(.powerPoint)
        }
        if runningBundleIDs.contains(PPTProviderApp.keynote.bundleIdentifier) {
            found.append(.keynote)
        }
        return found
    }

    nonisolated static func buildQueryScript(for app: PPTProviderApp = .powerPoint) -> String {
        switch app {
        case .powerPoint:
            return """
            \(powerPointStatusSnippet)
            return my pptStatus()
            """
        case .keynote:
            return """
            \(keynoteStatusSnippet)
            return my keynoteStatus()
            """
        }
    }

    nonisolated static func buildControlScript(for action: PPTControlAction, app: PPTProviderApp = .powerPoint) -> String {
        let pptActionBlock: String
        let keynoteActionBlock: String

        switch action {
        case .startShowFromBeginning(let mode):
            pptActionBlock = """
                if (count of presentations) = 0 then error "NO_DECK"
                if (count of slide show windows) = 0 then
                    activate
                    set totalCnt to count of slides of active presentation
                    set sss to slide show settings of active presentation
                    try
                        set show type of sss to \(mode.appleScriptType)
                    end try
                    try
                        set range type of sss to slide show range show all
                        set starting slide of sss to 1
                        set ending slide of sss to totalCnt
                    end try
                    run slide show sss
                    repeat 15 times
                        if (count of slide show windows) > 0 then exit repeat
                        delay 0.1
                    end repeat
                else
                    go to first slide (slide show view of slide show window 1)
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                tell front document to start from slide 1
            """

        case .startShowFromCurrent(let mode):
            pptActionBlock = """
                if (count of presentations) = 0 then error "NO_DECK"
                if (count of slide show windows) = 0 then
                    set curIdx to 1
                    try
                        set curIdx to slide index of slide of view of active window
                    end try
                    activate
                    set totalCnt to count of slides of active presentation
                    set sss to slide show settings of active presentation
                    try
                        set show type of sss to \(mode.appleScriptType)
                    end try
                    try
                        set range type of sss to slide show range show all
                        set starting slide of sss to 1
                        set ending slide of sss to totalCnt
                    end try
                    run slide show sss
                    repeat 15 times
                        if (count of slide show windows) > 0 then exit repeat
                        delay 0.1
                    end repeat
                    if (count of slide show windows) > 0 and curIdx > 1 then
                        set ssv to slide show view of slide show window 1
                        set actualIdx to 1
                        try
                            set actualIdx to slide index of slide of ssv
                        end try
                        if curIdx > actualIdx then
                            repeat (curIdx - actualIdx) times
                                go to next slide ssv
                            end repeat
                        end if
                    end if
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                tell front document to start from current slide
            """

        case .endShow:
            pptActionBlock = """
                if (count of slide show windows) > 0 then
                    exit slide show (slide show view of slide show window 1)
                end if
            """
            keynoteActionBlock = """
                if (count of documents) > 0 then
                    try
                        stop front document
                    end try
                end if
            """

        case .nextSlide:
            pptActionBlock = """
                if (count of slide show windows) > 0 then
                    go to next slide (slide show view of slide show window 1)
                else if (count of document windows) > 0 then
                    set curIdx to slide index of slide of view of active window
                    set totalCnt to count of slides of active presentation
                    if curIdx < totalCnt then
                        go to slide (view of active window) number (curIdx + 1)
                    end if
                else
                    error "NO_DECK"
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                if playing then
                    show next
                else
                    tell front document
                        set curIdx to slide number of current slide
                        set totalCnt to count of slides
                        if curIdx < totalCnt then set current slide to slide (curIdx + 1)
                    end tell
                end if
            """

        case .previousSlide:
            pptActionBlock = """
                if (count of slide show windows) > 0 then
                    go to previous slide (slide show view of slide show window 1)
                else if (count of document windows) > 0 then
                    set curIdx to slide index of slide of view of active window
                    if curIdx > 1 then
                        go to slide (view of active window) number (curIdx - 1)
                    end if
                else
                    error "NO_DECK"
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                if playing then
                    show previous
                else
                    tell front document
                        set curIdx to slide number of current slide
                        if curIdx > 1 then set current slide to slide (curIdx - 1)
                    end tell
                end if
            """

        case .firstSlide:
            pptActionBlock = """
                if (count of slide show windows) > 0 then
                    go to first slide (slide show view of slide show window 1)
                else if (count of document windows) > 0 then
                    go to slide (view of active window) number 1
                else
                    error "NO_DECK"
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                tell front document to set current slide to slide 1
            """

        case .lastSlide:
            pptActionBlock = """
                if (count of slide show windows) > 0 then
                    go to last slide (slide show view of slide show window 1)
                else if (count of document windows) > 0 then
                    set totalCnt to count of slides of active presentation
                    if totalCnt >= 1 then go to slide (view of active window) number totalCnt
                else
                    error "NO_DECK"
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                tell front document
                    set totalCnt to count of slides
                    if totalCnt >= 1 then set current slide to slide totalCnt
                end tell
            """

        case .goToSlide(let rawTarget):
            let target = max(1, rawTarget)
            pptActionBlock = """
                if (count of presentations) = 0 then error "NO_DECK"
                set totalCnt to count of slides of active presentation
                set targetIdx to \(target)
                if targetIdx > totalCnt then set targetIdx to totalCnt
                if targetIdx < 1 then set targetIdx to 1
                if (count of slide show windows) > 0 then
                    set ssv to slide show view of slide show window 1
                    set curIdx to 1
                    try
                        set curIdx to slide index of slide of ssv
                    end try
                    if targetIdx = 1 then
                        go to first slide ssv
                    else if targetIdx = totalCnt then
                        go to last slide ssv
                    else if targetIdx > curIdx then
                        repeat (targetIdx - curIdx) times
                            go to next slide ssv
                        end repeat
                    else if targetIdx < curIdx then
                        repeat (curIdx - targetIdx) times
                            go to previous slide ssv
                        end repeat
                    end if
                else if (count of document windows) > 0 then
                    go to slide (view of active window) number targetIdx
                end if
            """
            keynoteActionBlock = """
                if (count of documents) = 0 then error "NO_DECK"
                tell front document
                    set totalCnt to count of slides
                    set targetIdx to \(target)
                    if targetIdx > totalCnt then set targetIdx to totalCnt
                    if targetIdx < 1 then set targetIdx to 1
                    set current slide to slide targetIdx
                end tell
            """

        case .toggleBlackScreen:
            pptActionBlock = """
                if (count of slide show windows) = 0 then error "SHOW_NOT_RUNNING"
                set ssv to slide show view of slide show window 1
                if (slide state of ssv) is slide show state black screen then
                    set slide state of ssv to slide show state running
                else
                    set slide state of ssv to slide show state black screen
                end if
            """
            keynoteActionBlock = """
                error "SHOW_BLACKOUT_PPT_ONLY"
            """

        case .toggleWhiteScreen:
            pptActionBlock = """
                if (count of slide show windows) = 0 then error "SHOW_NOT_RUNNING"
                set ssv to slide show view of slide show window 1
                if (slide state of ssv) is slide show state white screen then
                    set slide state of ssv to slide show state running
                else
                    set slide state of ssv to slide show state white screen
                end if
            """
            keynoteActionBlock = """
                error "SHOW_BLACKOUT_PPT_ONLY"
            """

        case .bringToFront:
            pptActionBlock = """
                activate
            """
            keynoteActionBlock = """
                activate
            """
        }

        switch app {
        case .powerPoint:
            return """
            \(powerPointStatusSnippet)
            tell application "Microsoft PowerPoint"
                \(pptActionBlock)
            end tell
            return my pptStatus()
            """
        case .keynote:
            return """
            \(keynoteStatusSnippet)
            tell application "Keynote"
                \(keynoteActionBlock)
            end tell
            return my keynoteStatus()
            """
        }
    }

    /// Never launches PowerPoint/Keynote — detects running apps directly via `NSWorkspace` (zero System Events permission needed).
    nonisolated private static func queryActiveSnapshot() async -> PPTSlideSnapshot? {
        let apps = runningPresentationApps()
        guard !apps.isEmpty else { return nil }
        for app in apps {
            if case .success(let out) = await AppleScriptExecutor.shared.run(buildQueryScript(for: app), timeoutSeconds: 4.0),
               let snapshot = parseSnapshot(out) {
                return snapshot
            }
        }
        return nil
    }

    nonisolated private static func executeControlAction(_ action: PPTControlAction) async -> Result<PPTSlideSnapshot?, CloudFailure> {
        let apps = runningPresentationApps()
        guard let targetApp = apps.first else {
            return .failure(CloudFailure(message: "Microsoft PowerPoint(또는 Keynote)가 실행 중이 아닙니다. 발표 파일을 먼저 열어주세요."))
        }
        let timeout: TimeInterval = {
            switch action {
            case .startShowFromBeginning, .startShowFromCurrent: return 12.0
            default: return 8.0
            }
        }()
        switch await AppleScriptExecutor.shared.run(buildControlScript(for: action, app: targetApp), timeoutSeconds: timeout) {
        case .success(let output):
            return .success(parseSnapshot(output))
        case .failure(let failure):
            let errMsg = failure.message
            if errMsg.contains("NO_APP") {
                return .failure(CloudFailure(message: "Microsoft PowerPoint(또는 Keynote)가 실행 중이 아닙니다. 발표 파일을 먼저 열어주세요."))
            }
            if errMsg.contains("NO_DECK") {
                return .failure(CloudFailure(message: "열려 있는 \(targetApp.rawValue) 프레젠테이션 파일이 없습니다."))
            }
            if errMsg.contains("SHOW_NOT_RUNNING") {
                return .failure(CloudFailure(message: "블랙/화이트 화면 전환은 슬라이드 쇼 실행 중에만 사용할 수 있습니다."))
            }
            if errMsg.contains("SHOW_BLACKOUT_PPT_ONLY") {
                return .failure(CloudFailure(message: "블랙/화이트 화면 제어는 Microsoft PowerPoint 슬라이드 쇼에서 지원됩니다."))
            }
            if errMsg.contains("-1743") || errMsg.lowercased().contains("not authorized") {
                return .failure(CloudFailure(message: "\(targetApp.rawValue) 자동화 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 SpikDoum의 \(targetApp.rawValue) 제어를 허용해주세요."))
            }
            return .failure(CloudFailure(message: "\(targetApp.rawValue) 제어 실패: \(errMsg)"))
        }
    }

    // MARK: - Live Presenter Notes Extraction (PowerPoint / Keynote + Local PPTX Hybrid)

    nonisolated static func buildNotesExportScript(for app: PPTProviderApp = .powerPoint) -> String {
        switch app {
        case .powerPoint:
            return """
            tell application "Microsoft PowerPoint"
                if (count of presentations) = 0 then error "NO_DECK"
                set p to active presentation
                set totalCnt to count of slides of p
                set outText to ""
                repeat with i from 1 to totalCnt
                    set sl to slide i of p
                    set titleText to ""
                    try
                        set titleText to content of text range of text frame of place holder 1 of sl as string
                    end try
                    set noteText to ""
                    try
                        set noteText to content of text range of text frame of place holder 2 of notes page of sl as string
                    on error
                        try
                            set np to notes page of sl
                            repeat with nsh in shapes of np
                                try
                                    if has text frame of nsh then
                                        set ntf to text frame of nsh
                                        if has text of ntf then
                                            set nt to content of text range of ntf as string
                                            if nt is not (i as string) then
                                                if noteText is "" then
                                                    set noteText to nt
                                                else
                                                    set noteText to noteText & linefeed & nt
                                                end if
                                            end if
                                        end if
                                    end if
                                end try
                            end repeat
                        end try
                    end try
                    set outText to outText & "<<<SPIK_SLIDE>>>" & (i as string) & "<<<SPIK_FIELD>>>" & titleText & "<<<SPIK_FIELD>>>" & noteText
                end repeat
                return outText
            end tell
            """
        case .keynote:
            return """
            tell application "Keynote"
                if (count of documents) = 0 then error "NO_DECK"
                set doc to front document
                set totalCnt to count of slides of doc
                set outText to ""
                repeat with i from 1 to totalCnt
                    set sl to slide i of doc
                    set titleText to ""
                    try
                        set titleText to object text of default title item of sl as string
                    end try
                    set noteText to ""
                    try
                        set noteText to presenter notes of sl as string
                    end try
                    set outText to outText & "<<<SPIK_SLIDE>>>" & (i as string) & "<<<SPIK_FIELD>>>" & titleText & "<<<SPIK_FIELD>>>" & noteText
                end repeat
                return outText
            end tell
            """
        }
    }

    nonisolated static func parseLiveSlides(_ raw: String) -> [ImportedPPTSlide] {
        let records = raw.components(separatedBy: "<<<SPIK_SLIDE>>>")
        var slides: [ImportedPPTSlide] = []
        for record in records {
            let trimmedRecord = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRecord.isEmpty else { continue }
            let fields = record.components(separatedBy: "<<<SPIK_FIELD>>>")
            guard fields.count >= 3,
                  let number = Int(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  number >= 1 else { continue }

            let rawTitle = fields[1]
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""

            let noteRaw = fields[2...].joined(separator: "<<<SPIK_FIELD>>>")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let noteLines = noteRaw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != String(number) }

            let resolvedTitle = rawTitle.isEmpty ? "슬라이드 \(number)" : String(rawTitle.prefix(80))
            slides.append(ImportedPPTSlide(
                number: number,
                title: resolvedTitle,
                bullets: [],
                speakerNotes: noteLines
            ))
        }
        return slides.sorted { $0.number < $1.number }
    }

    /// Merges live presenter notes (including unsaved edits in PowerPoint) onto `.pptx` disk slides
    /// so we retain accurate custom-textbox slide titles & screen bullets alongside up-to-the-second notes.
    nonisolated static func mergeLiveNotes(baseSlides: [ImportedPPTSlide], liveSlides: [ImportedPPTSlide]) -> [ImportedPPTSlide] {
        guard !liveSlides.isEmpty else { return baseSlides }
        guard !baseSlides.isEmpty else { return liveSlides }
        let baseByNumber = Dictionary(uniqueKeysWithValues: baseSlides.map { ($0.number, $0) })
        return liveSlides.map { live in
            guard let base = baseByNumber[live.number] else { return live }
            let genericLiveTitle = live.title == "슬라이드 \(live.number)"
            let chosenTitle = genericLiveTitle ? base.title : live.title
            let chosenNotes = live.speakerNotes.isEmpty ? base.speakerNotes : live.speakerNotes
            return ImportedPPTSlide(
                number: live.number,
                title: chosenTitle,
                bullets: base.bullets,
                speakerNotes: chosenNotes
            )
        }
    }

    struct LinkedDeckFetchResult: Sendable {
        var snapshot: PPTSlideSnapshot
        var slides: [ImportedPPTSlide]
        var usedLiveMemoryNotes: Bool
    }

    /// Fetches all slides and up-to-date presenter notes from the active PowerPoint or Keynote presentation.
    /// Uses a fast hybrid path: parses the local `.pptx` (for accurate slide titles & screen bullets) AND overlays
    /// live PowerPoint/Keynote presenter notes (so even unsaved note edits, OneDrive decks, and Keynote work seamlessly).
    nonisolated static func fetchActivePresentationSlides(
        preferredSnapshot: PPTSlideSnapshot? = nil
    ) async -> Result<LinkedDeckFetchResult, CloudFailure> {
        let snapshot: PPTSlideSnapshot
        if let preferredSnapshot {
            snapshot = preferredSnapshot
        } else if let queried = await queryActiveSnapshot() {
            snapshot = queried
        } else {
            return .failure(CloudFailure(message: "열려 있는 Microsoft PowerPoint(또는 Keynote) 발표 자료를 찾지 못했습니다."))
        }

        let app: PPTProviderApp = snapshot.appName.lowercased().contains("keynote") ? .keynote : .powerPoint

        // 1. Fast local `.pptx` parse for exact slide titles & screen bullets (if path is a readable local `.pptx`).
        var diskSlides: [ImportedPPTSlide] = []
        let candidatePath = snapshot.presentationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidatePath.isEmpty,
           !candidatePath.hasPrefix("http://"),
           !candidatePath.hasPrefix("https://"),
           candidatePath.lowercased().hasSuffix(".pptx"),
           FileManager.default.isReadableFile(atPath: candidatePath) {
            let url = URL(fileURLWithPath: candidatePath)
            if let parsed = try? PPTXSlideImporter.importPPTX(from: url) {
                diskSlides = parsed
            }
        }

        // 2. Live presenter notes extraction from PowerPoint/Keynote memory (captures unsaved edits & OneDrive/Keynote).
        let liveOutcome = await AppleScriptExecutor.shared.run(buildNotesExportScript(for: app), timeoutSeconds: 12.0)
        var liveSlides: [ImportedPPTSlide] = []
        if case .success(let raw) = liveOutcome {
            liveSlides = parseLiveSlides(raw)
        }

        if !liveSlides.isEmpty {
            let merged = mergeLiveNotes(baseSlides: diskSlides, liveSlides: liveSlides)
            return .success(LinkedDeckFetchResult(snapshot: snapshot, slides: merged, usedLiveMemoryNotes: true))
        }
        if !diskSlides.isEmpty {
            return .success(LinkedDeckFetchResult(snapshot: snapshot, slides: diskSlides, usedLiveMemoryNotes: false))
        }
        if case .failure(let failure) = liveOutcome {
            let errMsg = failure.message
            if errMsg.contains("-1743") || errMsg.lowercased().contains("not authorized") {
                return .failure(CloudFailure(message: "\(app.rawValue) 자동화 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 SpikDoum의 \(app.rawValue) 제어를 허용해주세요."))
            }
            return .failure(CloudFailure(message: "\(app.rawValue) 메모를 가져오지 못했습니다: \(errMsg)"))
        }
        return .failure(CloudFailure(message: "열려 있는 \(app.rawValue) 발표 자료에서 슬라이드를 찾지 못했습니다."))
    }
}
