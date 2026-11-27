import SwiftUI
import AppKit

/// Memory-cached thumbnail loader for captured lecture screenshots so live STT updates
/// never synchronously decode PNG/JPEG images from disk on the main thread inside `body`.
final class LearningCaptureImageCache: @unchecked Sendable {
    static let shared = LearningCaptureImageCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 48
        return c
    }()

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url.path as NSString)
    }

    func loadAsync(from url: URL) async -> NSImage? {
        if let hit = cachedImage(for: url) { return hit }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let img = NSImage(contentsOf: url) else { return nil }
            LearningCaptureImageCache.shared.store(img, for: url)
            return img
        }.value
    }
}

private struct LearningCaptureThumbnailView: View {
    let imageURL: URL?
    @State private var loadedImage: NSImage? = nil
    @State private var loadedPath: String? = nil

    var body: some View {
        let currentImage: NSImage? = {
            if let imageURL, let cached = LearningCaptureImageCache.shared.cachedImage(for: imageURL) {
                return cached
            }
            if let imageURL, loadedPath == imageURL.path {
                return loadedImage
            }
            return nil
        }()

        Group {
            if let currentImage {
                Image(nsImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text(imageURL == nil ? "이미지 파일을 불러올 수 없습니다" : "이미지 불러오는 중…")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .task(id: imageURL?.path) {
            guard let url = imageURL else {
                loadedImage = nil
                loadedPath = nil
                return
            }
            if let cached = LearningCaptureImageCache.shared.cachedImage(for: url) {
                loadedImage = cached
                loadedPath = url.path
                return
            }
            let decoded = await LearningCaptureImageCache.shared.loadAsync(from: url)
            loadedImage = decoded
            loadedPath = url.path
        }
    }
}

/// Compact silent window-capture control strip shown in Online Learning (`온라인 교육`) mode.
struct LearningCaptureToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capturer: LearningWindowCapturer
    @Binding var showCapturesPanel: Bool
    @State private var justCaptured = false

    init(model: AppModel, showCapturesPanel: Binding<Bool>) {
        self.model = model
        self.capturer = model.learningCapturer
        self._showCapturesPanel = showCapturesPanel
    }

    private var captureCount: Int {
        model.current?.screenCaptures?.count ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            Label("조용한 화면 기록", systemImage: "camera.viewfinder")
                .font(.caption.bold())
                .foregroundStyle(.indigo)

            // Target Lecture Window Picker
            Menu {
                if capturer.availableWindows.isEmpty {
                    Text("캡처 가능한 창을 찾지 못했습니다")
                } else {
                    Section("캡처할 온라인 교육 창 선택") {
                        ForEach(capturer.availableWindows) { win in
                            Button {
                                capturer.selectedWindowID = win.id
                            } label: {
                                if capturer.selectedWindow?.id == win.id {
                                    Label(win.displayLabel, systemImage: "checkmark")
                                } else {
                                    Text(win.displayLabel)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    Task { await model.refreshLearningWindows() }
                } label: {
                    Label("열린 창 목록 새로고침", systemImage: "arrow.clockwise")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.caption2)
                    Text(capturer.selectedWindow?.displayLabel ?? "교육 창 선택…")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.indigo.opacity(0.10), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("소리나 깜박임 없이 조용히 캡처할 온라인 강의 창을 선택합니다")

            // One-click silent capture button
            Button {
                Task {
                    let saved = await model.captureLearningScreenNow(automatic: false)
                    if saved {
                        justCaptured = true
                        showCapturesPanel = true
                        try? await Task.sleep(for: .seconds(1.2))
                        justCaptured = false
                    }
                }
            } label: {
                if capturer.isCapturing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).scaleEffect(0.75)
                        Text("캡처 중…").font(.caption.weight(.semibold))
                    }
                } else {
                    Label(justCaptured ? "기록됨" : "지금 캡처", systemImage: justCaptured ? "checkmark.circle.fill" : "camera.fill")
                        .font(.caption.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(justCaptured ? .green : .indigo)
            .disabled(capturer.isCapturing || model.current == nil || model.current?.archivedAt != nil)
            .help("선택한 교육 창의 현재 화면을 소리·깜박임 없이 조용히 캡처하고 지금 설명 중인 내용과 함께 저장합니다 (⌥⌘S)")

            // Auto capture toggle + cadence menu
            Button {
                model.setLearningAutoCapture(!capturer.autoCaptureEnabled)
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(capturer.autoCaptureEnabled ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(capturer.autoCaptureEnabled ? "자동 캡처 ON (\(capturer.intervalSeconds)초)" : "자동 캡처 OFF")
                        .font(.caption.weight(.medium))
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(capturer.autoCaptureEnabled ? .green : .secondary)
            .disabled(model.current == nil || model.current?.archivedAt != nil)
            .help(capturer.changeDetectionOnly
                  ? "켜면 \(capturer.intervalSeconds)초마다 선택한 교육 창을 확인해 슬라이드·화면이 바뀔 때만 조용히 자동 기록합니다"
                  : "켜면 \(capturer.intervalSeconds)초마다 선택한 교육 창을 조용히 자동 기록합니다")

            Menu {
                Toggle("화면이 바뀔 때만 자동 저장 (중복 방지)", isOn: $capturer.changeDetectionOnly)
                Divider()
                Section("자동 확인 주기") {
                    ForEach([5, 10, 15, 30], id: \.self) { sec in
                        Button {
                            capturer.intervalSeconds = sec
                            if capturer.autoCaptureEnabled {
                                model.startLearningAutoCaptureLoop()
                            }
                        } label: {
                            if capturer.intervalSeconds == sec {
                                Label("\(sec)초마다 확인", systemImage: "checkmark")
                            } else {
                                Text("\(sec)초마다 확인")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    Task { await model.refreshLearningWindows() }
                } label: {
                    Label("열린 창 목록 새로고침", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("자동 화면 캡처 주기 및 중복 방지 설정")

            Spacer(minLength: 4)

            if let err = capturer.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCapturesPanel.toggle()
                }
            } label: {
                Label(captureCount > 0 ? "화면 기록 (\(captureCount))" : "화면 기록", systemImage: showCapturesPanel ? "photo.on.rectangle.angled" : "photo.on.rectangle")
                    .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(showCapturesPanel ? .indigo : .secondary)
            .help("강의 화면 기록 패널 표시 / 숨기기")
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(height: 32)
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.indigo.opacity(0.18), lineWidth: 1))
        .onAppear {
            Task { await model.refreshLearningWindows() }
        }
    }
}

/// Visual study timeline panel displaying silently captured online-education screens
/// paired with the exact STT explanation, translation, and editable study memos.
struct LearningScreenCapturesPanel: View {
    @ObservedObject var model: AppModel
    var onClose: (() -> Void)? = nil
    @State private var selectedCaptureForPreview: LearningScreenCapture? = nil
    @State private var copiedMarkdown = false

    private var captures: [LearningScreenCapture] {
        (model.displayConversation?.screenCaptures ?? []).sorted { $0.capturedAt > $1.capturedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("강의 화면 기록", systemImage: "photo.stack")
                    .font(.subheadline.bold())
                    .foregroundStyle(.indigo)
                if !captures.isEmpty {
                    Text("\(captures.count)장")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.14), in: Capsule())
                        .foregroundStyle(.indigo)
                }
                Spacer()
                if !captures.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.exportLearningCapturesMarkdown(), forType: .string)
                        copiedMarkdown = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedMarkdown = false
                        }
                    } label: {
                        Image(systemName: copiedMarkdown ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedMarkdown ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("화면 기록 + 설명 노트 마크다운으로 복사")

                    if let convoID = model.displayConversation?.id {
                        Button {
                            let folder = RecordingStorage.conversationFolder(for: convoID, root: model.recordingsRoot)
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Finder에서 저장된 화면 캡처 폴더 열기")
                    }
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("화면 기록 패널 숨기기")
                }
            }

            if captures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("아직 기록된 강의 화면이 없습니다", systemImage: "camera.viewfinder")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("상단에서 온라인 교육 창을 선택한 뒤 ‘지금 캡처 (⌥⌘S)’ 또는 ‘자동 캡처 ON’을 켜세요. 소리나 깜박임 없이 슬라이드가 바뀔 때마다 설명 당시 원문·번역과 함께 기록됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.indigo.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(captures.enumerated()), id: \.element.id) { idx, capture in
                            captureCard(capture, ordinal: captures.count - idx)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .sheet(item: $selectedCaptureForPreview) { item in
            LearningCaptureLightboxSheet(model: model, captureID: item.id)
        }
    }

    private func captureCard(_ capture: LearningScreenCapture, ordinal: Int) -> some View {
        let convoID = model.displayConversation?.id ?? model.selectedID
        let imageURL = convoID.map { RecordingStorage.clipURL(conversationID: $0, filename: capture.filename, root: model.recordingsRoot) }
        let noteBinding = Binding<String>(
            get: { capture.userNote },
            set: { newValue in
                model.updateLearningCapture(capture.id) { $0.userNote = newValue }
            }
        )

        return VStack(alignment: .leading, spacing: 7) {
            // Card meta bar
            HStack(spacing: 5) {
                Text("#\(ordinal)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.indigo.opacity(0.14), in: Capsule())
                    .foregroundStyle(.indigo)
                Text(capture.capturedAt.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if capture.autoCaptured {
                    Text("화면 변경 감지")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 4)
                if let spanID = capture.sourceSpanID {
                    Button {
                        model.pauseReading()
                        model.selectedConversationBlockID = nil
                        model.selectedLiveBlockID = spanID
                    } label: {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                    }
                    .buttonStyle(.plain)
                    .help("이 화면이 설명되던 당시의 대화 위치로 이동")
                }
                if let imageURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Finder에서 캡처 이미지 보기")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.deleteLearningCapture(capture.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("이 화면 기록 삭제")
            }

            // Clickable Thumbnail (memory-cached, off-main-thread decoded — zero flicker during live STT)
            Button {
                selectedCaptureForPreview = capture
            } label: {
                LearningCaptureThumbnailView(imageURL: imageURL)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("클릭하여 크게 보기 · \(capture.appName) · \(capture.windowTitle)")

            // Explanation excerpt at the time of capture
            if !capture.transcriptExcerpt.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(capture.transcriptExcerpt)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let trans = capture.translationExcerpt, !trans.isEmpty {
                        Text("→ \(trans)")
                            .font(.caption)
                            .foregroundStyle(.teal)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.7))
            }

            // Inline Study Memo
            TextField("이 화면 핵심 학습 메모…", text: noteBinding, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.6))
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 0.8))
    }
}

/// Full-resolution preview modal for inspecting a captured lecture screen alongside its full explanation & memo.
private struct LearningCaptureLightboxSheet: View {
    @ObservedObject var model: AppModel
    let captureID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var copiedImage = false

    private var capture: LearningScreenCapture? {
        (model.displayConversation?.screenCaptures ?? []).first { $0.id == captureID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let capture, let convoID = model.displayConversation?.id ?? model.selectedID {
                let imageURL = RecordingStorage.clipURL(conversationID: convoID, filename: capture.filename, root: model.recordingsRoot)
                let nsImage = NSImage(contentsOf: imageURL)
                let noteBinding = Binding<String>(
                    get: { capture.userNote },
                    set: { val in model.updateLearningCapture(capture.id) { $0.userNote = val } }
                )

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(capture.appName) · \(capture.windowTitle)")
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(capture.capturedAt.formatted(.dateTime.year().month().day().hour().minute().second())) · \(capture.pixelWidth)×\(capture.pixelHeight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let nsImage {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([nsImage])
                            copiedImage = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copiedImage = false
                            }
                        } label: {
                            Label(copiedImage ? "이미지 복사됨" : "이미지 복사", systemImage: copiedImage ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                    } label: {
                        Label("Finder에서 보기", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Button("닫기") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }

                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    if !capture.transcriptExcerpt.isEmpty {
                        Text("설명 당시 원문: \(capture.transcriptExcerpt)")
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if let trans = capture.translationExcerpt, !trans.isEmpty {
                        Text("번역: \(trans)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.teal)
                            .textSelection(.enabled)
                    }
                    TextField("학습 메모를 입력하세요…", text: noteBinding, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text("화면 기록을 찾지 못했습니다.")
                Button("닫기") { dismiss() }
            }
        }
        .padding(18)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 620, idealHeight: 720)
    }
}
