import SwiftUI
import AppKit

/// Question Records (질문기록) board for Presentation Mode.
/// Each card displays:
/// - Standalone recorded audio clip (`.m4a`) with inline playback & audio-to-text transcription
/// - STT original question text (editable)
/// - Translated text (auto-translated + 1-click re-translate)
/// - Per-question AI Recommended Answer (grounded in slide notes + presentation context)
/// - Presenter memo / follow-up notes
struct PresentationQuestionNotesView: View {
    @ObservedObject var model: AppModel
    @StateObject private var player = QuestionAudioPlayer()
    @State private var filter: NoteFilter = .all
    @State private var showingQuickAdd = false
    @State private var quickQuestionText = ""
    @State private var quickColor: PostItColor = .yellow
    @State private var copiedAll = false
    @State private var copiedAnswerID: UUID? = nil
    @State private var editingQuestionID: UUID? = nil

    enum NoteFilter: String, CaseIterable {
        case all = "전체"
        case open = "미답변"
        case resolved = "완료"
        case audioOnly = "음성"
    }

    private var notes: [PresentationQuestionNote] {
        model.activePresentation.resolvedQuestionNotes
    }

    private var filteredNotes: [PresentationQuestionNote] {
        let base: [PresentationQuestionNote]
        switch filter {
        case .all: base = notes
        case .open: base = notes.filter { !$0.isResolved }
        case .resolved: base = notes.filter(\.isResolved)
        case .audioOnly: base = notes.filter { $0.audioClip != nil }
        }
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Primary Capture Controls
            HStack(spacing: 6) {
                if model.recordingQuestionNote {
                    Button {
                        model.stopAndSaveQuestionNoteRecording()
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                            Text("질문 저장 (\(formatClipTime(Double(model.recordingQuestionSeconds))))")
                                .font(.caption.weight(.bold).monospacedDigit())
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("현재 녹음 중인 질문 음성과 STT·번역 내용을 질문기록으로 저장합니다")

                    Button {
                        model.cancelQuestionNoteRecording()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .controlSize(.small)
                    .help("질문 녹음 취소")
                } else {
                    Button {
                        model.startQuestionNoteRecording()
                    } label: {
                        Label("질문 녹음", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.current?.archivedAt != nil)
                    .help("지금부터 질문 음성을 독립 파일로 녹음하고 STT·번역과 함께 질문기록에 저장합니다 (직전 2초 자동 포함)")

                    Button {
                        model.captureRecentQuestionAsPostIt()
                    } label: {
                        Label("방금 질문", systemImage: "pin.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(.indigo)
                    .disabled(model.current?.archivedAt != nil)
                    .help("방금 들린 질문의 음성·STT·번역을 즉시 질문기록으로 저장합니다 (⌥⌘Q)")
                }

                Spacer(minLength: 4)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showingQuickAdd.toggle() }
                } label: {
                    Image(systemName: showingQuickAdd ? "minus.circle" : "square.and.pencil")
                }
                .controlSize(.small)
                .help("질문기록 직접 추가")

                if !notes.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.exportQuestionNotesMarkdown(), forType: .string)
                        copiedAll = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedAll = false
                        }
                    } label: {
                        Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copiedAll ? .green : .secondary)
                    }
                    .controlSize(.small)
                    .help("모든 질문기록 마크다운으로 복사")
                }
            }

            // Auto-capture toggle + Filter strip
            HStack(spacing: 6) {
                ForEach(NoteFilter.allCases, id: \.self) { item in
                    let selected = filter == item
                    let count: Int = {
                        switch item {
                        case .all: return notes.count
                        case .open: return notes.filter { !$0.isResolved }.count
                        case .resolved: return notes.filter(\.isResolved).count
                        case .audioOnly: return notes.filter { $0.audioClip != nil }.count
                        }
                    }()
                    Button {
                        filter = item
                    } label: {
                        Text(count > 0 ? "\(item.rawValue) \(count)" : item.rawValue)
                            .font(.caption2.weight(selected ? .bold : .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(selected ? Color.orange : Color.secondary.opacity(0.10), in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                Toggle("자동 질문기록", isOn: $model.autoCaptureQuestions)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("발표 중 Google Meet 청중 발언이나 Q&A 질문을 감지하면 음성·STT·번역과 함께 자동으로 질문기록에 저장합니다")
            }

            if let err = player.playbackError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            // Manual Question Record Creator
            if showingQuickAdd {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("질문 내용을 직접 입력하세요…", text: $quickQuestionText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    HStack(spacing: 6) {
                        ForEach(PostItColor.allCases) { swatch in
                            Button {
                                quickColor = swatch
                            } label: {
                                Circle()
                                    .fill(swatch.swatchColor)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(quickColor == swatch ? 0.75 : 0.2), lineWidth: quickColor == swatch ? 1.8 : 0.8))
                            }
                            .buttonStyle(.plain)
                            .help(swatch.label)
                        }
                        Spacer()
                        Button("질문기록 추가") {
                            model.addManualQuestionNote(quickQuestionText, color: quickColor)
                            quickQuestionText = ""
                            showingQuickAdd = false
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(quickQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
                .background(quickColor.cardBackground, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(quickColor.borderColor, lineWidth: 1))
            }

            // Question Records List
            ScrollView {
                if filteredNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("저장된 질문기록이 없습니다", systemImage: "note.text")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("발표 중 질문이 나오면 상단의 ‘방금 질문 (⌥⌘Q)’ 또는 ‘질문 녹음’을 누르세요. 녹음된 음성, STT 원문, 번역, 그리고 슬라이드 맥락 기반 AI 답변 추천까지 한 카드에 기록됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PostItColor.yellow.cardBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PostItColor.yellow.borderColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(.top, 4)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredNotes) { note in
                            questionRecordCard(note)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            model.ensureQuestionNotesProcessed()
        }
        .onDisappear {
            player.stop()
        }
    }

    private func questionRecordCard(_ note: PresentationQuestionNote) -> some View {
        let isEditingQuestion = editingQuestionID == note.id
        let isThisPlaying = player.activeNoteID == note.id && player.isPlaying
        let isThisActive = player.activeNoteID == note.id
        let isTranscribing = model.transcribingQuestionIDs.contains(note.id)
        let isTranslating = model.translatingQuestionIDs.contains(note.id)
        let isRecommending = model.recommendingQuestionIDs.contains(note.id)

        let memoBinding = Binding<String>(
            get: { note.answerMemo },
            set: { newValue in
                model.updateQuestionNote(note.id) { $0.answerMemo = newValue }
            }
        )
        let questionBinding = Binding<String>(
            get: { note.questionText },
            set: { newValue in
                model.updateQuestionNote(note.id) { $0.questionText = newValue }
            }
        )

        return VStack(alignment: .leading, spacing: 0) {
            // Card top color tape bar
            HStack(spacing: 5) {
                if let slideNum = note.slideNumber {
                    Text("#\(slideNum)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.black.opacity(0.10), in: Capsule())
                }
                Text(note.createdAt.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("· \(note.sourceLabel)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if note.autoCaptured {
                    Text("자동")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.indigo.opacity(0.15), in: Capsule())
                        .foregroundStyle(.indigo)
                }

                Spacer(minLength: 4)

                // Color picker
                Menu {
                    ForEach(PostItColor.allCases) { swatch in
                        Button {
                            model.updateQuestionNote(note.id) { $0.color = swatch }
                        } label: {
                            if note.color == swatch {
                                Label(swatch.label, systemImage: "checkmark")
                            } else {
                                Text(swatch.label)
                            }
                        }
                    }
                } label: {
                    Circle()
                        .fill(note.color.swatchColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("질문기록 카드 색상 변경")

                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        model.updateQuestionNote(note.id) { $0.isPinned.toggle() }
                    }
                } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(note.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(note.isPinned ? "상단 고정 해제" : "상단에 고정")

                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        model.updateQuestionNote(note.id) { $0.isResolved.toggle() }
                    }
                } label: {
                    Image(systemName: note.isResolved ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(note.isResolved ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(note.isResolved ? "답변 완료 해제" : "답변 완료로 표시")

                Button {
                    if player.activeNoteID == note.id { player.stop() }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.deleteQuestionNote(note.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("질문기록 및 저장된 질문 음성 삭제")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(note.color.headerBackground)

            // Card Content Body
            VStack(alignment: .leading, spacing: 8) {
                if let slideTitle = note.slideTitle, !slideTitle.isEmpty {
                    Text(slideTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 1. Embedded Recorded Audio Player
                if let clip = note.audioClip, let conversationID = model.selectedID {
                    let clipURL = RecordingStorage.clipURL(
                        conversationID: conversationID,
                        filename: clip.filename,
                        root: model.recordingsRoot
                    )
                    let totalDur = isThisActive && player.duration > 0 ? player.duration : clip.duration
                    let elapsed = isThisActive ? player.currentTime : 0
                    let ratio = totalDur > 0 ? min(1.0, max(0, elapsed / totalDur)) : 0

                    HStack(spacing: 7) {
                        Button {
                            player.togglePlay(noteID: note.id, url: clipURL)
                        } label: {
                            Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                                .font(.caption2.bold())
                                .frame(width: 22, height: 22)
                                .background(note.color.swatchColor.opacity(0.9), in: Circle())
                                .foregroundStyle(Color.black.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .help(isThisPlaying ? "녹음된 질문 음성 일시정지" : "녹음된 질문 음성 재생")

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule()
                                    .fill(Color.orange)
                                    .frame(width: max(isThisActive ? 4 : 0, geo.size.width * ratio))
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let frac = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                        if !isThisActive {
                                            player.togglePlay(noteID: note.id, url: clipURL)
                                        }
                                        player.seek(noteID: note.id, to: totalDur * frac)
                                    }
                            )
                        }
                        .frame(height: 6)

                        Text(isThisActive ? "\(formatClipTime(elapsed)) / \(formatClipTime(totalDur))" : formatClipTime(totalDur))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()

                        if isTranscribing {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                        } else {
                            Button {
                                Task { await model.transcribeQuestionNote(note.id, thenTranslate: true) }
                            } label: {
                                Text("STT")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("녹음된 질문 음성을 다시 STT 텍스트로 변환하고 번역합니다")
                        }

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([clipURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Finder에서 이 질문 음성 파일(.m4a) 열기")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.70), in: RoundedRectangle(cornerRadius: 7))
                }

                // 2. STT Original Text Block
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("STT 원문")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.14), in: Capsule())
                            .foregroundStyle(.blue)
                        if isTranscribing {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                            Text("음성 인식 중…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if isEditingQuestion {
                                editingQuestionID = nil
                                Task { await model.translateQuestionNote(note.id, force: true) }
                            } else {
                                editingQuestionID = note.id
                            }
                        } label: {
                            Image(systemName: isEditingQuestion ? "checkmark" : "pencil")
                                .font(.caption2)
                                .foregroundStyle(isEditingQuestion ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isEditingQuestion ? "편집 완료 및 자동 번역" : "STT 원문 편집")
                    }

                    if isEditingQuestion {
                        TextField("질문 원문", text: questionBinding, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text(note.questionText.isEmpty
                             ? (isTranscribing ? "녹음된 질문 음성을 텍스트로 변환하고 있습니다…" : "(음성만 저장됨 · 상단 STT 버튼으로 텍스트 변환 또는 연필로 입력)")
                             : note.questionText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(note.questionText.isEmpty || note.isResolved ? .secondary : .primary)
                            .strikethrough(note.isResolved)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // 3. Translated Text Block
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("번역")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.teal.opacity(0.15), in: Capsule())
                            .foregroundStyle(.teal)
                        if isTranslating {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                            Text("번역 중…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !note.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating {
                            Button {
                                Task { await model.translateQuestionNote(note.id, force: true) }
                            } label: {
                                Label((note.translatedText?.isEmpty ?? true) ? "번역하기" : "다시 번역", systemImage: "globe")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.teal)
                            }
                            .buttonStyle(.plain)
                            .help("질문 원문을 \(model.targetLanguageName)(으)로 번역")
                        }
                    }

                    if let translated = note.translatedText, !translated.isEmpty {
                        Text(translated)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.teal)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else if !isTranslating {
                        Text("원문 언어가 \(model.targetLanguageName)와 다르면 자동 번역됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 4. Per-Question AI Recommended Answer Block
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Label("AI 답변 추천", systemImage: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.purple)
                        Spacer()
                        if let rec = note.recommendedAnswer, !rec.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(rec, forType: .string)
                                copiedAnswerID = note.id
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if copiedAnswerID == note.id { copiedAnswerID = nil }
                                }
                            } label: {
                                Image(systemName: copiedAnswerID == note.id ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(copiedAnswerID == note.id ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("추천 답변 복사")

                            Button {
                                model.updateQuestionNote(note.id) { item in
                                    let joined = [item.recommendedAnswer, item.recommendedAnswerLocal]
                                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty }
                                        .joined(separator: "\n")
                                    item.answerMemo = joined
                                }
                            } label: {
                                Text("메모로 채우기")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                            .help("추천 답변을 아래 내 메모 칸에 채웁니다")
                        }

                        Button {
                            Task { await model.recommendAnswerForQuestionNote(note.id) }
                        } label: {
                            if isRecommending {
                                HStack(spacing: 3) {
                                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                                    Text("생성 중…").font(.system(size: 10, weight: .semibold))
                                }
                            } else {
                                Label((note.recommendedAnswer?.isEmpty ?? true) ? "답변 추천" : "다시 추천", systemImage: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isRecommending || (note.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.audioClip == nil))
                        .help("현재 슬라이드 발표 메모와 질문 내용을 바탕으로 AI가 바로 말할 수 있는 추천 답변을 생성합니다")
                    }

                    if let rec = note.recommendedAnswer, !rec.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rec)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let local = note.recommendedAnswerLocal, !local.isEmpty {
                                Divider().opacity(0.5)
                                Text(local)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(Color.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.purple.opacity(0.22), lineWidth: 0.8))
                    }
                }

                // 5. Inline Presenter Answer / Follow-up Memo
                TextField("내 답변 요점 · 후속 조치 메모…", text: memoBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)
        }
        .background(note.color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(note.isPinned ? Color.orange.opacity(0.75) : note.color.borderColor, lineWidth: note.isPinned ? 1.4 : 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1.5)
    }

    private func formatClipTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension PostItColor {
    var swatchColor: Color {
        switch self {
        case .yellow: return Color(red: 1.00, green: 0.84, blue: 0.30)
        case .mint: return Color(red: 0.45, green: 0.85, blue: 0.65)
        case .pink: return Color(red: 1.00, green: 0.58, blue: 0.70)
        case .sky: return Color(red: 0.48, green: 0.78, blue: 1.00)
        case .lavender: return Color(red: 0.74, green: 0.60, blue: 1.00)
        }
    }

    var cardBackground: Color {
        swatchColor.opacity(0.18)
    }

    var headerBackground: Color {
        swatchColor.opacity(0.32)
    }

    var borderColor: Color {
        swatchColor.opacity(0.55)
    }
}
