import SwiftUI
import AppKit

/// Positions the floating Presenter HUD at top-center (just below the webcam/menu bar),
/// keeps it always-on-top across Spaces/fullscreen slides, and ALWAYS hides it from Google Meet screen sharing.
struct PresenterHUDWindowController: NSViewRepresentable {
    let translucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window, reposition: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window, reposition: false)
        }
    }

    private func configure(window: NSWindow?, reposition: Bool) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        // Always invisible to Google Meet / Zoom / Teams screen sharing!
        window.sharingType = .none
        window.isOpaque = false
        window.alphaValue = translucent ? 0.90 : 1.0

        if reposition, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let w = min(max(620, window.frame.width), visible.width - 40)
            let h = min(max(220, window.frame.height), 340)
            let x = visible.midX - w / 2
            let y = visible.maxY - h - 8
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
    }
}

/// Camera-bar floating Presenter HUD designed for sharing PPT on Google Meet:
/// stays visible only to you right below your webcam while PowerPoint/Chrome is in the foreground.
struct PresenterHUDView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pptSync: PPTSlideSyncMonitor
    @State private var translucent = true
    @State private var copiedPhrase = false

    init(model: AppModel) {
        self.model = model
        self.pptSync = model.pptSlideSync
    }

    private var session: PresentationSession { model.activePresentation }
    private var cards: [PresentationCueCard] { PresentationNotesParser.parse(session.notesMarkdown) }
    private var activeIndex: Int {
        guard !cards.isEmpty else { return 0 }
        return min(max(0, session.activeCardIndex), cards.count - 1)
    }
    private var activeCard: PresentationCueCard? {
        cards.indices.contains(activeIndex) ? cards[activeIndex] : nil
    }

    /// Detects recent Google Meet audience speech (`[Mac 재생음]`) so interruptions appear right under the webcam.
    private var recentMeetAudienceTurn: (original: String, translated: String?)? {
        guard let convo = model.displayConversation else { return nil }
        let cutoff = Date().addingTimeInterval(-35)
        let recentSysSpans = (convo.transcriptSpans ?? []).filter {
            $0.date >= cutoff && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Mac 재생음]")
        }
        guard let latestSpan = recentSysSpans.last else { return nil }
        let original = TranslationPolicy.displayText(strippingSourceTag: latestSpan.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let latestTranslation = (convo.translations ?? []).last {
            TranslationPolicy.sourceTag(of: $0.source) == "Mac 재생음"
        }?.translated
        return (original, latestTranslation)
    }

    var body: some View {
        let targetSecs = session.targetSeconds
        let remaining = targetSecs - session.elapsedSeconds
        let isOvertime = remaining < 0
        let progress = targetSecs > 0 ? min(1.0, session.elapsedSeconds / targetSecs) : 0
        let paceColor: Color = (isOvertime || remaining <= 60) ? .red : ((remaining / max(1, targetSecs) <= 0.2 || remaining <= 180) ? .orange : .green)
        let paceMetrics = SpeakingPaceCalculator.calculate(spans: model.current?.transcriptSpans ?? [], referenceDate: Date())
        let liveSignpost = PresentationAdvisor.contextualLiveRecommendation(
            session: session,
            cards: cards,
            activeCardIndex: activeIndex,
            languageCode: model.presentationLanguageCode
        )
        let nextUnchecked = session.checklist.filter { !$0.isChecked }.prefix(2)

        VStack(alignment: .leading, spacing: 8) {
            // Top Telemetry Strip
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.presentationTimerRunning ? paceColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(formatClock(remaining))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOvertime ? .red : (model.presentationTimerRunning ? paceColor : .primary))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(paceColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                Button {
                    if model.presentationTimerRunning && model.listening {
                        model.stopPresentation()
                    } else {
                        model.startPresentation()
                    }
                } label: {
                    Image(systemName: (model.presentationTimerRunning && model.listening) ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .help("발표 시작 / 일시정지")

                if paceMetrics.zone != .idle {
                    Text("\(paceMetrics.rate) \(paceMetrics.unitLabel)")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((paceMetrics.zone == .fast ? Color.orange : Color.green).opacity(0.14), in: Capsule())
                        .foregroundStyle(paceMetrics.zone == .fast ? .orange : .green)
                }

                // Compact PowerPoint / Keynote Remote directly in the invisible camera-bar HUD
                HStack(spacing: 3) {
                    Button {
                        pptSync.perform(.previousSlide)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption2.bold())
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .disabled(pptSync.isSendingCommand)
                    .help("PowerPoint 이전 슬라이드")

                    Button {
                        pptSync.refreshNow()
                    } label: {
                        let slideText: String = {
                            if let cur = pptSync.currentSlideNumber {
                                let totalPart = pptSync.totalSlides.map { "/\($0)" } ?? ""
                                return "PPT #\(cur)\(totalPart)"
                            }
                            return "PPT"
                        }()
                        Text(slideText)
                            .font(.caption2.bold().monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((pptSync.isSlideShowRunning ? Color.green : Color.indigo).opacity(0.16), in: Capsule())
                            .foregroundStyle(pptSync.isSlideShowRunning ? .green : .indigo)
                    }
                    .buttonStyle(.plain)
                    .help("PowerPoint 슬라이드 상태 새로고침")

                    Button {
                        pptSync.perform(.nextSlide)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(pptSync.isSendingCommand)
                    .help("PowerPoint 다음 슬라이드")

                    Button {
                        pptSync.perform(pptSync.isSlideShowRunning ? .endShow : .startShowFromCurrent(pptSync.slideShowMode))
                    } label: {
                        Image(systemName: pptSync.isSlideShowRunning ? "stop.fill" : "play.rectangle.fill")
                            .font(.caption2)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .tint(pptSync.isSlideShowRunning ? .red : .orange)
                    .disabled(pptSync.isSendingCommand)
                    .help(pptSync.isSlideShowRunning ? "PowerPoint 슬라이드 쇼 종료" : "현재 슬라이드부터 \(pptSync.slideShowMode.label) 쇼 시작")

                    if pptSync.isSlideShowRunning {
                        Button {
                            pptSync.perform(.toggleBlackScreen)
                        } label: {
                            Image(systemName: pptSync.screenMode == .black ? "rectangle.fill" : "rectangle")
                                .font(.caption2)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .disabled(pptSync.isSendingCommand)
                        .help("블랙 화면 전환")
                    }
                }

                Label("Meet 숨김", systemImage: "eye.slash.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.14), in: Capsule())
                    .foregroundStyle(.purple)
                    .help("이 창은 Google Meet 화면 공유에서 자동으로 숨겨집니다")

                Spacer(minLength: 4)

                // Quick Mic Mute
                Button {
                    model.micMuted.toggle()
                } label: {
                    Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(model.micMuted ? .red : .secondary)
                .help("내 마이크 음소거 (⇧⌘M)")

                // Quick Question Record Pin
                Button {
                    if model.recordingQuestionNote {
                        model.stopAndSaveQuestionNoteRecording()
                    } else {
                        model.captureRecentQuestionAsPostIt()
                    }
                } label: {
                    Image(systemName: model.recordingQuestionNote ? "stop.circle.fill" : "pin.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(model.recordingQuestionNote ? .red : .orange)
                .help(model.recordingQuestionNote ? "녹음 중인 질문기록 저장" : "방금 질문 음성과 내용을 질문기록에 저장 (⌥⌘Q)")

                // Quick Q&A Toggle
                Button {
                    model.togglePresentationQAMode()
                } label: {
                    Text(session.inQAMode ? "발표 복귀" : "Q&A")
                        .font(.caption2.bold())
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(session.inQAMode ? .teal : .secondary)

                Button {
                    translucent.toggle()
                } label: {
                    Image(systemName: translucent ? "circle.lefthalf.filled" : "circle.fill")
                }
                .controlSize(.small)
                .help(translucent ? "불투명하게" : "반투명하게")
            }

            // Thin traffic-light progress line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(paceColor).frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 4)

            // Main Cue Card Glance Area
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    if let card = activeCard {
                        HStack(spacing: 6) {
                            Text("\(card.index + 1)/\(cards.count)")
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.purple.opacity(0.16), in: Capsule())
                                .foregroundStyle(.purple)
                            Text(card.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Spacer()
                            Button {
                                let prev = max(0, activeIndex - 1)
                                model.updatePresentation { $0.activeCardIndex = prev }
                                if pptSync.autoSyncCueCardsToPPT && pptSync.connectedApp != nil {
                                    pptSync.perform(.goToSlide(prev + 1))
                                }
                            } label: { Image(systemName: "chevron.left") }
                                .controlSize(.mini).disabled(activeIndex <= 0)
                            Button {
                                let next = min(cards.count - 1, activeIndex + 1)
                                model.updatePresentation { $0.activeCardIndex = next }
                                if pptSync.autoSyncCueCardsToPPT && pptSync.connectedApp != nil {
                                    pptSync.perform(.goToSlide(next + 1))
                                }
                            } label: { Image(systemName: "chevron.right") }
                                .controlSize(.mini).disabled(activeIndex >= cards.count - 1)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(card.lines.prefix(4).enumerated()), id: \.offset) { _, line in
                                    let cleaned = line.hasPrefix("- ") || line.hasPrefix("• ") ? String(line.dropFirst(2)) : line
                                    Text("• \(cleaned)")
                                        .font(.system(size: max(14, min(20, session.cueCardFontSize - 3)), weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if let firstNote = card.nativeNotes.first {
                                    Text("💡 \(firstNote)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        Text("메인 창에서 PPTX를 불러오거나 큐카드를 작성하면 여기에 카메라 아래 텔레프롬프터로 표시됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Compact Right Strip: Must-say + Live Signpost
                VStack(alignment: .leading, spacing: 6) {
                    if !nextUnchecked.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("미언급 필수 포인트")
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                            ForEach(Array(nextUnchecked)) { item in
                                Button {
                                    model.toggleChecklistItem(item.id)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "circle").font(.caption2).foregroundStyle(.secondary)
                                        Text(item.displayLabel).font(.caption2).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let phrase = liveSignpost.phrases.first {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(liveSignpost.badge)
                                    .font(.caption2.bold())
                                    .foregroundStyle(.teal)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(phrase.text, forType: .string)
                                    copiedPhrase = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.2))
                                        copiedPhrase = false
                                    }
                                } label: {
                                    Image(systemName: copiedPhrase ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(copiedPhrase ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(phrase.text)
                                .font(.caption2.weight(.medium))
                                .lineLimit(3)
                        }
                        .padding(6)
                        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .frame(width: 215, alignment: .topLeading)
            }

            // Live Google Meet Audience Interruption Banner (when [Mac 재생음] arrives!)
            if let audience = recentMeetAudienceTurn {
                HStack(spacing: 8) {
                    Label("Meet 청중 발언", systemImage: "person.wave.2.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.teal)
                    Text(audience.translated ?? audience.original)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("질문기록 저장") {
                        model.captureRecentQuestionAsPostIt()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    if !session.inQAMode {
                        Button("Q&A 대응") { model.togglePresentationQAMode() }
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(PresenterHUDWindowController(translucent: translucent).allowsHitTesting(false))
    }

    private func formatClock(_ remaining: TimeInterval) -> String {
        let sign = remaining < 0 ? "+" : ""
        let total = max(0, Int(abs(remaining).rounded(.down)))
        return String(format: "%@%02d:%02d", sign, total / 60, total % 60)
    }
}
