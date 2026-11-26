import SwiftUI
import AppKit

struct PresentationWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pptSync: PPTSlideSyncMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var editingNotes = false
    @State private var rightTab: RightCompanionTab = .checklist
    @State private var selectedCategory: SignpostingCategory = .opening
    @State private var newChecklistText = ""
    @State private var newPhraseText = ""
    @State private var newPhraseMeaning = ""
    @State private var showingAddPhrase = false
    @State private var phraseSearch = ""
    @State private var copiedPhraseID: UUID? = nil
    @AppStorage("presentationHeaderCollapsedV1") private var headerCollapsed = false

    init(model: AppModel) {
        self.model = model
        self.pptSync = model.pptSlideSync
    }

    enum RightCompanionTab: String, CaseIterable {
        case checklist = "필수 체크리스트"
        case phrases = "전환구 치트시트"
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

    var body: some View {
        VStack(alignment: .leading, spacing: headerCollapsed ? 6 : 10) {
            presenterControlHeader
            if let error = model.presentationError ?? pptSync.lastControlError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if error.contains("자동화 권한") {
                        Link("자동화 권한 열기", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                            .font(.caption.bold())
                    }
                    Button {
                        model.presentationError = nil
                        pptSync.lastControlError = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            if let pendingDeck = model.linkedPPTNotesPendingUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.indigo)
                    Text("연결된 PowerPoint ‘\(pendingDeck)’의 발표자 메모를 가져올까요? (현재 직접 편집한 메모가 있어 자동으로 덮어쓰지 않았습니다.)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("PPT 메모 가져오기") {
                        Task { await model.syncLinkedPPTNotes(force: true) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(pptSync.isImportingNotes)
                    Button {
                        model.linkedPPTNotesPendingUpdate = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            HSplitView {
                cueCardColumn
                    .frame(minWidth: 460, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 8)

                companionColumn
                    .frame(minWidth: 330, idealWidth: 410, maxHeight: .infinity)
                    .padding(.leading, 8)
            }
        }
        .onAppear {
            model.ensurePresentationSession()
            if pptSync.autoImportNotes && !pptSync.isEnabled {
                pptSync.setEnabled(true)
            } else {
                pptSync.refreshNow()
            }
        }
    }

    // MARK: - Top Control Header + Traffic-Light Pace Bar

    private var presenterControlHeader: some View {
        let targetSecs = session.targetSeconds
        let elapsed = session.elapsedSeconds
        let remaining = targetSecs - elapsed
        let isOvertime = remaining < 0
        let remainingRatio = targetSecs > 0 ? max(0, remaining / targetSecs) : 0
        let progress = targetSecs > 0 ? min(1.0, elapsed / targetSecs) : 0

        let paceColor: Color = {
            if isOvertime || remaining <= 60 { return .red }
            if remainingRatio <= 0.20 || remaining <= 180 { return .orange }
            return .green
        }()

        let paceMetrics = SpeakingPaceCalculator.calculate(
            spans: model.current?.transcriptSpans ?? [],
            referenceDate: Date()
        )

        return VStack(alignment: .leading, spacing: headerCollapsed ? 5 : 8) {
            if headerCollapsed {
                HStack(spacing: 8) {
                    // Compact Countdown Clock
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.presentationTimerRunning ? paceColor : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(formatClock(remaining))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(isOvertime ? .red : (model.presentationTimerRunning ? paceColor : .primary))
                        Text("/ \(session.targetMinutes)분")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((isOvertime ? Color.red : paceColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

                    if model.presentationTimerRunning && model.listening {
                        Button {
                            model.stopPresentation()
                        } label: {
                            Label("정지", systemImage: "stop.fill").font(.caption2.weight(.semibold))
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button {
                            model.startPresentation()
                        } label: {
                            Label("발표 시작", systemImage: "play.circle.fill").font(.caption2.weight(.semibold))
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(model.starting || model.current?.archivedAt != nil)
                    }

                    Divider().frame(height: 16)

                    // Mini PowerPoint Remote Strip
                    HStack(spacing: 4) {
                        Button {
                            pptSync.perform(.previousSlide)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(pptSync.isSendingCommand)
                        .help("PowerPoint 이전 슬라이드")

                        Button {
                            pptSync.perform(.bringToFront)
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(pptSync.isSlideShowRunning ? Color.green : (pptSync.connectedApp != nil ? Color.orange : Color.secondary.opacity(0.45)))
                                    .frame(width: 6, height: 6)
                                if let cur = pptSync.currentSlideNumber {
                                    Text("PPT #\(cur)\(pptSync.totalSlides.map { "/\($0)" } ?? "")")
                                        .font(.caption2.bold().monospacedDigit())
                                } else {
                                    Text("PPT 대기")
                                        .font(.caption2.weight(.medium))
                                }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.orange.opacity(pptSync.connectedApp != nil ? 0.12 : 0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("PowerPoint 창 앞으로 가져오기")

                        Button {
                            pptSync.perform(.nextSlide)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(pptSync.isSendingCommand)
                        .help("PowerPoint 다음 슬라이드")

                        if pptSync.isSlideShowRunning {
                            Button {
                                pptSync.perform(.endShow)
                            } label: {
                                Image(systemName: "stop.fill")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(pptSync.isSendingCommand)
                            .help("슬라이드 쇼 종료")
                        } else {
                            Button {
                                pptSync.perform(.startShowFromCurrent(pptSync.slideShowMode))
                            } label: {
                                Image(systemName: "play.rectangle.fill")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(pptSync.isSendingCommand)
                            .help("현재 슬라이드부터 쇼 시작 (\(pptSync.slideShowMode.label))")
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        model.togglePresentationQAMode()
                    } label: {
                        Label(session.inQAMode ? "발표 복귀" : "Q&A", systemImage: session.inQAMode ? "arrow.uturn.backward" : "bubble.left.and.exclamationmark.bubble.right.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(session.inQAMode ? .teal : .indigo)

                    Button {
                        openWindow(id: "presenter-hud")
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("플로팅 HUD 열기")

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { headerCollapsed = false }
                    } label: {
                        Label("발표 상단 펼치기", systemImage: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .help("발표 타이머 · Meet · PowerPoint 상단 컨트롤 모두 펼치기")
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(paceColor.gradient)
                            .frame(width: max(4, geo.size.width * progress))
                            .animation(.easeInOut(duration: 0.35), value: progress)
                    }
                }
                .frame(height: 4)
            } else {
            HStack(spacing: 10) {
                // Big Countdown / Overtime Display
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.presentationTimerRunning ? paceColor : Color.secondary.opacity(0.4))
                        .frame(width: 9, height: 9)
                    Text(formatClock(remaining))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOvertime ? .red : (model.presentationTimerRunning ? paceColor : .primary))
                    Text("/ \(session.targetMinutes)분")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background((isOvertime ? Color.red : paceColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                // Target Duration Picker
                Menu {
                    Section("발표 목표 시간") {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { mins in
                            Button {
                                model.updatePresentation { $0.targetMinutes = mins }
                            } label: {
                                if session.targetMinutes == mins {
                                    Label("\(mins)분", systemImage: "checkmark")
                                } else {
                                    Text("\(mins)분")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("+1분 늘리기") {
                        model.updatePresentation { $0.targetMinutes = min(180, $0.targetMinutes + 1) }
                    }
                    Button("-1분 줄이기") {
                        model.updatePresentation { $0.targetMinutes = max(1, $0.targetMinutes - 1) }
                    }
                } label: {
                    Label("목표", systemImage: "timer")
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("발표 목표 시간 설정")

                // Independent Timer Controls
                HStack(spacing: 4) {
                    Button {
                        model.togglePresentationTimer()
                    } label: {
                        Image(systemName: model.presentationTimerRunning ? "pause.fill" : "play.fill")
                    }
                    .controlSize(.small)
                    .help(model.presentationTimerRunning ? "타이머 일시정지" : "타이머만 시작")

                    Button {
                        model.resetPresentationTimer()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .disabled(session.elapsedSeconds == 0 && !model.presentationTimerRunning)
                    .help("타이머 초기화")
                }

                Divider().frame(height: 18)

                // Live WPM / CPM Gauge
                paceGaugePill(metrics: paceMetrics)

                Spacer(minLength: 6)

                // Screen-Share Privacy Toggle
                Button {
                    model.hideFromScreenShare.toggle()
                } label: {
                    Label(
                        model.hideFromScreenShare ? "공유 숨김 ON" : "화면 공유 숨기기",
                        systemImage: model.hideFromScreenShare ? "eye.slash.fill" : "eye.slash"
                    )
                    .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(model.hideFromScreenShare ? .purple : .secondary)
                .help("켜면 Zoom·Teams·Meet 화면 공유 시 청중에게 SpikDoum 창이 보이지 않습니다 (NSWindow.sharingType = .none)")

                // Duplicate Presentation Deck
                Button {
                    model.duplicatePresentationToNewConversation()
                } label: {
                    Label("세트 복제", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .help("현재 발표 타이머·큐카드·체크리스트를 새 리허설/실전 대화로 복제")

                // Q&A Mode Toggle
                Button {
                    model.togglePresentationQAMode()
                } label: {
                    Label(
                        session.inQAMode ? "발표로 복귀" : "Q&A 전환",
                        systemImage: session.inQAMode ? "arrow.uturn.backward" : "bubble.left.and.exclamationmark.bubble.right.fill"
                    )
                    .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(session.inQAMode ? .teal : .indigo)
                .help("청중 질문(Mac 재생음) + 내 마이크 동시 청취 및 AI 답변 코치로 즉시 전환")

                // One-Click Presentation Start (Timer + Listening)
                if model.presentationTimerRunning && model.listening {
                    Button {
                        model.stopPresentation()
                    } label: {
                        Label("발표 정지", systemImage: "stop.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        model.startPresentation()
                    } label: {
                        Label("발표 시작", systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(model.starting || model.current?.archivedAt != nil)
                    .help("타이머와 실시간 STT 듣기를 동시에 시작합니다")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { headerCollapsed = true }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("발표 상단 컨트롤 접기 · 큐카드와 체크리스트 넓게 보기")
            }

            // Google Meet + PPT Sharing Quick Workflow Bar
            HStack(spacing: 8) {
                Button {
                    model.prepareGoogleMeetPresentation(browser: model.meetingTarget)
                    openWindow(id: "presenter-hud")
                } label: {
                    Label("Google Meet PPT 준비", systemImage: "video.badge.checkmark")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .help("Chrome(Meet) 청중 소리 + 내 마이크 · 화면 공유 숨김 ON · PPT 슬라이드 자동 연동 · 카메라 아래 플로팅 HUD를 한 번에 실행합니다")

                Button {
                    model.importPPTXPresentation()
                    editingNotes = false
                } label: {
                    Label("PPTX 불러오기", systemImage: "doc.richtext")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .disabled(model.current?.archivedAt != nil)
                .help("PowerPoint(.pptx) 파일에서 슬라이드 제목·본문·발표자 노트를 큐카드로 자동 불러옵니다")

                Button {
                    pptSync.setEnabled(!pptSync.isEnabled)
                } label: {
                    Label(
                        pptSync.isEnabled ? pptSync.statusLabel : "PPT 자동 연동",
                        systemImage: pptSync.isEnabled ? "link.circle.fill" : "link.circle"
                    )
                    .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(pptSync.connectedApp != nil ? .green : (pptSync.isEnabled ? .indigo : .secondary))
                .help("Microsoft PowerPoint 또는 Keynote에서 슬라이드를 넘기면 SpikDoum 큐카드도 자동으로 따라 넘어갑니다")

                Button {
                    openWindow(id: "presenter-hud")
                } label: {
                    Label("플로팅 HUD", systemImage: "macwindow.on.rectangle")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .help("웹캠 바로 아래에 항상 위로 뜨고 Google Meet 화면 공유에는 보이지 않는 미니 프레젠터 HUD를 엽니다")

                Spacer(minLength: 4)

                Text("팁: Google Meet에서는 ‘창 공유’로 PowerPoint 창만 공유하고, 플로팅 HUD를 카메라 아래 두면 시선이 자연스럽습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // PowerPoint / Keynote Direct Presentation Remote Bar
            powerPointRemoteBar

            // Traffic-Light Pace Progress Bar + Active Section Timing
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(paceColor.gradient)
                            .frame(width: max(4, geo.size.width * progress))
                            .animation(.easeInOut(duration: 0.35), value: progress)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 12) {
                    Text(isOvertime ? "목표 시간 초과 (+\(formatDuration(abs(remaining))))" : "경과 \(formatDuration(elapsed)) · 남은 시간 \(formatDuration(remaining))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOvertime ? .red : .secondary)

                    if let card = activeCard {
                        let cardSpent = session.sectionElapsed[card.id] ?? 0
                        if let planned = card.targetSeconds {
                            let cardRemaining = planned - cardSpent
                            Text("현재 섹션 ‘\(card.title)’: \(formatDuration(cardSpent)) / \(formatDuration(planned)) (\(cardRemaining >= 0 ? "여유 \(formatDuration(cardRemaining))" : "초과 +\(formatDuration(abs(cardRemaining)))"))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(cardRemaining < 0 ? .orange : .secondary)
                                .lineLimit(1)
                        } else {
                            Text("현재 섹션 ‘\(card.title)’: \(formatDuration(cardSpent))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    let checkedCount = session.checklist.filter(\.isChecked).count
                    if !session.checklist.isEmpty {
                        Text("필수 포인트 \(checkedCount)/\(session.checklist.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(checkedCount == session.checklist.count ? .green : .purple)
                    }
                }
            }
            }
        }
        .padding(headerCollapsed ? 8 : 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: headerCollapsed ? 9 : 12))
    }

    private var powerPointRemoteBar: some View {
        let isConnected = pptSync.connectedApp != nil
        let slideBadge: String = {
            if let app = pptSync.connectedApp, let cur = pptSync.currentSlideNumber {
                let totalPart = pptSync.totalSlides.map { "/\($0)" } ?? ""
                return "\(app) #\(cur)\(totalPart)"
            }
            return "PowerPoint 감지 대기"
        }()

        return HStack(spacing: 8) {
            // Connection & Deck Badge
            HStack(spacing: 5) {
                Circle()
                    .fill(pptSync.isSlideShowRunning ? Color.green : (isConnected ? Color.orange : Color.secondary.opacity(0.45)))
                    .frame(width: 7, height: 7)
                Text(slideBadge)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(isConnected ? .primary : .secondary)
                if let deck = pptSync.presentationName, !deck.isEmpty {
                    Text("· \(deck)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                if pptSync.isSendingCommand {
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                } else {
                    Button {
                        pptSync.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("열려 있는 PowerPoint / Keynote 상태 새로고침")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(isConnected ? 0.12 : 0.06), in: Capsule())

            Divider().frame(height: 16)

            // Slide Show Start / Stop Controls
            if pptSync.isSlideShowRunning {
                Button {
                    pptSync.perform(.endShow)
                } label: {
                    Label("쇼 종료", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(pptSync.isSendingCommand)
                .help("PowerPoint 슬라이드 쇼 종료 (Esc)")
            } else {
                Picker("쇼 방식", selection: $pptSync.slideShowMode) {
                    Text("창 모드").tag(PPTSlideShowMode.windowed)
                    Text("전체 화면").tag(PPTSlideShowMode.fullScreen)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 132)
                .help("창 모드: Google Meet 창 공유와 SpikDoum 동시 표시에 최적 · 전체 화면: 프로젝터/듀얼 모니터용")

                Button {
                    pptSync.perform(.startShowFromBeginning(pptSync.slideShowMode))
                } label: {
                    Label("처음부터 쇼", systemImage: "play.rectangle.fill")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(pptSync.isSendingCommand)
                .help("PowerPoint 1번 슬라이드부터 \(pptSync.slideShowMode.label) 슬라이드 쇼 시작")

                Button {
                    pptSync.perform(.startShowFromCurrent(pptSync.slideShowMode))
                } label: {
                    Label("현재부터 쇼", systemImage: "play.fill")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(pptSync.isSendingCommand)
                .help("현재 슬라이드부터 \(pptSync.slideShowMode.label) 슬라이드 쇼 시작")
            }

            Divider().frame(height: 16)

            // Slide Navigation Remote
            HStack(spacing: 4) {
                Button {
                    pptSync.perform(.firstSlide)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .controlSize(.small)
                .disabled(pptSync.isSendingCommand)
                .help("첫 슬라이드로 이동")

                Button {
                    pptSync.perform(.previousSlide)
                } label: {
                    Label("이전", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(pptSync.isSendingCommand)
                .help("PowerPoint 이전 슬라이드")

                Button {
                    pptSync.perform(.nextSlide)
                } label: {
                    Label("다음", systemImage: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(pptSync.isSendingCommand)
                .help("PowerPoint 다음 슬라이드")

                Button {
                    pptSync.perform(.lastSlide)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .controlSize(.small)
                .disabled(pptSync.isSendingCommand)
                .help("마지막 슬라이드로 이동")
            }

            // Screen Blackout / Whiteout (Active during Slide Show)
            if pptSync.isSlideShowRunning {
                Divider().frame(height: 16)
                Button {
                    pptSync.perform(.toggleBlackScreen)
                } label: {
                    Label("블랙", systemImage: pptSync.screenMode == .black ? "rectangle.fill" : "rectangle")
                        .font(.caption2.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(pptSync.screenMode == .black ? .primary : .secondary)
                .disabled(pptSync.isSendingCommand)
                .help("청중 시선 집중을 위해 슬라이드 쇼 화면을 검정으로 가리기/해제")

                Button {
                    pptSync.perform(.toggleWhiteScreen)
                } label: {
                    Label("화이트", systemImage: pptSync.screenMode == .white ? "sun.max.fill" : "sun.max")
                        .font(.caption2.weight(.medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(pptSync.screenMode == .white ? .orange : .secondary)
                .disabled(pptSync.isSendingCommand)
                .help("슬라이드 쇼 화면을 흰색으로 가리기/해제")
            }

            Spacer(minLength: 4)

            Button {
                Task { await model.syncLinkedPPTNotes(force: true) }
            } label: {
                if pptSync.isImportingNotes {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).scaleEffect(0.75)
                        Text("메모 가져오는 중…").font(.caption2.weight(.medium))
                    }
                } else {
                    Label("PPT 메모 동기화", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                        .font(.caption2.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(.indigo)
            .disabled(pptSync.isImportingNotes || model.current?.archivedAt != nil)
            .help("열려 있는 PowerPoint / Keynote의 최신 발표자 메모(저장 전 수정본 포함)를 즉시 가져옵니다")

            Toggle("자동 메모", isOn: $pptSync.autoImportNotes)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .help("PowerPoint 발표 모드 진입 또는 슬라이드 쇼 시작 시 연결된 PPT의 발표자 메모를 자동으로 가져옵니다")

            Toggle("카드↔PPT", isOn: $pptSync.autoSyncCueCardsToPPT)
                .toggleStyle(.checkbox)
                .font(.caption2)
                .help("큐카드를 클릭하거나 넘길 때 PowerPoint 슬라이드도 함께 이동합니다")

            Button {
                pptSync.perform(.bringToFront)
            } label: {
                Image(systemName: "macwindow")
            }
            .controlSize(.small)
            .disabled(pptSync.isSendingCommand)
            .help("PowerPoint 창 앞으로 가져오기")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.18), lineWidth: 1))
    }

    private func paceGaugePill(metrics: SpeakingPaceMetrics) -> some View {
        let color: Color = {
            switch metrics.zone {
            case .idle: return .secondary
            case .slow: return .blue
            case .ideal: return .green
            case .fast: return .orange
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: "speedometer")
                .font(.caption2)
                .foregroundStyle(color)
            if metrics.rate > 0 {
                Text("\(metrics.rate) \(metrics.unitLabel)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(color)
                Text(metrics.guidance)
                    .font(.caption2)
                    .foregroundStyle(color)
            } else {
                Text(model.listening ? metrics.guidance : "속도 대기")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
        .help("최근 30초 내 발화 기준 말하기 속도 (영어 권장 110~155 WPM · 한국어 권장 210~360 자/분)")
    }

    // MARK: - Left Main Column: Cue Cards & Notes Editor

    private var cueCardColumn: some View {
        let fontBinding = Binding<Double>(
            get: { session.cueCardFontSize },
            set: { newVal in model.updatePresentation { $0.cueCardFontSize = newVal } }
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("메모 보기", selection: $editingNotes) {
                    Text("발표 큐카드 (\(cards.count))").tag(false)
                    Text("메모 편집").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .controlSize(.small)

                if let linkedName = session.linkedDeckName, !linkedName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                        Text(linkedName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                        if pptSync.isImportingNotes {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        } else {
                            Button {
                                Task { await model.syncLinkedPPTNotes(force: true) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.indigo)
                            .help("연결된 PPT 메모 다시 동기화")
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.08), in: Capsule())
                }

                Spacer()

                if !editingNotes {
                    PanelFontButton(title: "큐카드 글자 크기", value: fontBinding, range: 14...34, defaultValue: 20)
                }

                if model.compressingCueCards {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.compressNotesToCueCards() }
                } label: {
                    Label("AI 큐카드 압축", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(model.compressingCueCards || session.notesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.current?.archivedAt != nil)
                .help("긴 대본·메모를 발표 언어 핵심 불릿 + 모국어 전달 팁 큐카드로 자동 정리")

                if editingNotes {
                    Button("샘플 템플릿") {
                        model.updatePresentation {
                            $0.notesMarkdown = PresentationSession.starterTemplate
                            $0.activeCardIndex = 0
                        }
                    }
                    .controlSize(.small)
                }
            }

            if editingNotes {
                notesEditorView
            } else {
                cueCardPresentationView
            }
        }
    }

    private var notesEditorView: some View {
        let notesBinding = Binding<String>(
            get: { session.notesMarkdown },
            set: { text in model.updatePresentation { $0.notesMarkdown = text } }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("작성 팁:", systemImage: "info.circle")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                Text("`# 섹션 제목 [2분]` 으로 카드 분할 · `- 핵심 문장` · `> 한국어 의도/무대 팁`")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("카드 \(cards.count)장 미리보기")
                    .font(.caption2.bold()).foregroundStyle(.purple)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            TextEditor(text: notesBinding)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        }
    }

    private var cueCardPresentationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cards) { card in
                        let isSelected = card.index == activeIndex
                        let spent = session.sectionElapsed[card.id] ?? 0
                        let isSectionOver = card.targetSeconds.map { spent > $0 } ?? false
                        Button {
                            selectCard(at: card.index)
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(card.index + 1). \(card.title)")
                                    .font(.caption.weight(isSelected ? .bold : .medium))
                                    .lineLimit(1)
                                if let mins = card.targetMinutes {
                                    Text(mins == floor(mins) ? "\(Int(mins))분" : String(format: "%.1f분", mins))
                                        .font(.caption2.monospacedDigit())
                                        .opacity(0.8)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                isSelected
                                    ? (isSectionOver ? Color.orange : Color.purple)
                                    : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.white : (isSectionOver ? Color.orange : Color.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Main Cue Card Surface
            if let card = activeCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("CARD \(card.index + 1) / \(cards.count)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                                .foregroundStyle(.purple)
                            Text(card.title)
                                .font(.system(size: max(18, session.cueCardFontSize + 2), weight: .bold))
                            Spacer()
                            if let planned = card.targetSeconds {
                                let spent = session.sectionElapsed[card.id] ?? 0
                                let over = spent > planned
                                Label("\(formatDuration(spent)) / \(formatDuration(planned))", systemImage: "clock")
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(over ? .orange : .secondary)
                            }
                        }

                        Divider()

                        if card.lines.isEmpty && card.nativeNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("이 큐카드에 아직 내용이 없습니다.")
                                    .foregroundStyle(.secondary)
                                Button("메모 편집하기") { editingNotes = true }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 20)
                        } else {
                            if !card.lines.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                                        HStack(alignment: .top, spacing: 10) {
                                            Circle()
                                                .fill(Color.purple)
                                                .frame(width: 7, height: 7)
                                                .padding(.top, session.cueCardFontSize * 0.42)
                                            Text(line)
                                                .font(.system(size: session.cueCardFontSize, weight: .medium))
                                                .lineSpacing(6)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }

                            if !card.nativeNotes.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("전달 의도 · 무대 메모", systemImage: "text.quote")
                                        .font(.caption.bold())
                                        .foregroundStyle(.teal)
                                    ForEach(Array(card.nativeNotes.enumerated()), id: \.offset) { _, note in
                                        Text(note)
                                            .font(.system(size: max(13, session.cueCardFontSize - 4)))
                                            .foregroundStyle(.secondary)
                                            .lineSpacing(4)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(12)
                                .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.22), lineWidth: 1))
            }

            // Card Navigation Footer
            HStack {
                Button {
                    moveCard(by: -1)
                } label: {
                    Label("이전 카드", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(activeIndex <= 0)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(cards) { card in
                        Circle()
                            .fill(card.index == activeIndex ? Color.purple : Color.secondary.opacity(0.28))
                            .frame(width: card.index == activeIndex ? 9 : 6, height: card.index == activeIndex ? 9 : 6)
                            .onTapGesture {
                                selectCard(at: card.index)
                            }
                    }
                }

                Spacer()

                Button {
                    moveCard(by: 1)
                } label: {
                    Label("다음 카드", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(activeIndex >= cards.count - 1)
            }
            .controlSize(.regular)
        }
    }

    private func selectCard(at index: Int) {
        let clamped = min(max(0, index), max(0, cards.count - 1))
        model.updatePresentation { $0.activeCardIndex = clamped }
        if pptSync.autoSyncCueCardsToPPT && pptSync.connectedApp != nil {
            pptSync.perform(.goToSlide(clamped + 1))
        }
    }

    private func moveCard(by delta: Int) {
        let next = min(max(0, activeIndex + delta), max(0, cards.count - 1))
        guard next != activeIndex else { return }
        selectCard(at: next)
    }

    // MARK: - Right Companion Column (Presentation Companion OR Live Q&A Mode)

    @ViewBuilder
    private var companionColumn: some View {
        if session.inQAMode {
            qaCompanionView
        } else {
            VStack(alignment: .leading, spacing: 10) {
                liveSelfCaptionCard
                Divider()
                HStack {
                    Picker("발표 보조 도구", selection: $rightTab) {
                        ForEach(RightCompanionTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                if rightTab == .checklist {
                    checklistSection
                } else {
                    signpostingSection
                }
            }
        }
    }

    private var liveSelfCaptionCard: some View {
        let blocks = model.displayConversation.map { ConversationBlocks.make($0) } ?? []
        let latestBlocks = Array(blocks.suffix(3).reversed())

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("실시간 내 발화 자막 · 역번역", systemImage: "waveform")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                Spacer()
                if model.listening {
                    Text(model.micMuted ? "음소거됨" : "수신 중")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((model.micMuted ? Color.red : Color.green).opacity(0.15), in: Capsule())
                        .foregroundStyle(model.micMuted ? .red : .green)
                }
            }

            LiveSTTCaptionRow(
                liveSTT: model.liveSTT,
                appearance: model.sttAppearance,
                followLive: model.followLive,
                compact: true
            )

            if latestBlocks.isEmpty && model.liveSTT.text.isEmpty {
                Text("발표를 시작하면 내가 말하는 외국어가 STT로 어떻게 인식되는지와 역번역이 실시간 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(latestBlocks.enumerated()), id: \.element.id) { idx, block in
                            let cleanText = block.text
                                .replacingOccurrences(of: "[마이크]", with: "")
                                .replacingOccurrences(of: "[Mac 재생음]", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cleanText)
                                    .font(.system(size: idx == 0 ? 14 : 12, weight: idx == 0 ? .semibold : .regular))
                                    .foregroundStyle(idx == 0 ? .primary : .secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let translated = block.translation?.translated, !translated.isEmpty {
                                    Text("→ \(translated)")
                                        .font(.caption)
                                        .foregroundStyle(.teal)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                            .background(idx == 0 ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(minHeight: 110, maxHeight: 175)
            }
        }
    }

    private var checklistSection: some View {
        let items = session.checklist
        let doneCount = items.filter(\.isChecked).count

        let profile = PresentationDurationProfile.profile(for: session.targetMinutes)
        let elapsedMinutes = Int(session.elapsedSeconds / 60)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("필수 언급 포인트")
                    .font(.subheadline.bold())
                if !items.isEmpty {
                    Text("\(doneCount)/\(items.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((doneCount == items.count ? Color.green : Color.purple).opacity(0.15), in: Capsule())
                        .foregroundStyle(doneCount == items.count ? .green : .purple)
                }
                Spacer()
                if model.recommendingPresentation {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    Task { await model.recommendPresentationAids() }
                } label: {
                    Label("맞춤 추천", systemImage: "sparkles")
                }
                .controlSize(.mini)
                .disabled(model.recommendingPresentation || model.current?.archivedAt != nil)
                .help("발표 시간(\(session.targetMinutes)분)과 메모 내용을 분석해 필수 체크리스트와 전환구를 자동 추천합니다")
                if !items.isEmpty {
                    Button("초기화") { model.resetChecklist() }
                        .controlSize(.mini)
                }
            }

            // Duration pacing guidance banner (TED / Stanford GSB)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                    Text("\(profile.label) · 권장 \(profile.recommendedChecklistRange.lowerBound)~\(profile.recommendedChecklistRange.upperBound)개")
                        .font(.caption2.bold())
                        .foregroundStyle(.indigo)
                }
                Text(profile.pacingTip)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            // Recommended checklist tray (AI or Instant)
            if let rec = model.presentationRecommendation, !rec.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(rec.isAIGenerated ? "AI 추천 포인트" : "시간·내용 즉시 추천", systemImage: "sparkles")
                            .font(.caption2.bold())
                            .foregroundStyle(.purple)
                        Spacer()
                        Button("모두 추가") { model.acceptAllPresentationRecommendations() }
                            .controlSize(.mini)
                        Button { model.dismissPresentationRecommendations() } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(rec.rationale)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    ForEach(rec.checklist) { item in
                        HStack(spacing: 6) {
                            if let tag = item.stageTag, !tag.isEmpty {
                                Text(tag)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.purple)
                            }
                            if let minMark = item.targetMinute {
                                Text("\(minMark)분")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                model.acceptRecommendedChecklistItem(item)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                            .help("체크리스트에 추가")
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                TextField("예: 35% 절감 / 35% / thirty-five percent", text: $newChecklistText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(submitChecklistItem)
                Button("추가", action: submitChecklistItem)
                    .controlSize(.small)
                    .disabled(newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("‘/’ 또는 ‘,’로 영어·한국어 별칭을 함께 적으면 발표 중 말할 때 STT가 자동 체크합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView {
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("등록된 필수 포인트가 없습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button("\(session.targetMinutes)분 표준 체크리스트 채우기") {
                                model.applyDurationStarterChecklist()
                            }
                            .controlSize(.small)
                            Button {
                                Task { await model.recommendPresentationAids() }
                            } label: {
                                Label("메모 기반 자동 추천", systemImage: "sparkles")
                            }
                            .controlSize(.small)
                            .disabled(model.recommendingPresentation)
                        }
                    }
                    .padding(.top, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            let overdue = !item.isChecked && item.targetMinute.map { elapsedMinutes > $0 && session.elapsedSeconds > 10 } ?? false
                            HStack(spacing: 8) {
                                Button {
                                    model.toggleChecklistItem(item.id)
                                } label: {
                                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : (overdue ? "exclamationmark.circle.fill" : "circle"))
                                        .foregroundStyle(item.isChecked ? .green : (overdue ? .orange : .secondary))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        if let tag = item.stageTag, !tag.isEmpty {
                                            Text(tag)
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background((item.isChecked ? Color.green : Color.purple).opacity(0.14), in: Capsule())
                                                .foregroundStyle(item.isChecked ? .green : .purple)
                                        }
                                        if let minMark = item.targetMinute {
                                            Text("\(minMark)분")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(overdue ? .orange : .secondary)
                                        }
                                        if overdue {
                                            Text("아직 미언급")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(item.title)
                                        .font(.system(size: 13, weight: item.isChecked ? .medium : .regular))
                                        .strikethrough(item.isChecked)
                                        .foregroundStyle(item.isChecked ? .secondary : .primary)
                                    if item.autoMatched, let matchedAt = item.matchedAt {
                                        Text("STT 자동 감지 · \(matchedAt.formatted(.dateTime.hour().minute().second()))")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Button {
                                    model.removeChecklistItem(item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background((item.isChecked ? Color.green : (overdue ? Color.orange : Color.secondary)).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func submitChecklistItem() {
        model.addChecklistItem(newChecklistText)
        newChecklistText = ""
    }

    private var signpostingSection: some View {
        let langCode = model.presentationLanguageCode
        let trimmedQuery = phraseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtInAll = SignpostingCatalog.builtInPhrases(forLanguageCode: langCode)
        let filteredBuiltIn: [PresentationPhrase]
        let filteredCustom: [PresentationPhrase]
        if trimmedQuery.isEmpty {
            filteredBuiltIn = builtInAll.filter { $0.category == selectedCategory }
            filteredCustom = session.customPhrases.filter { $0.category == selectedCategory }
        } else {
            filteredBuiltIn = builtInAll.filter {
                $0.text.localizedCaseInsensitiveContains(trimmedQuery) || $0.meaning.localizedCaseInsensitiveContains(trimmedQuery)
            }
            filteredCustom = session.customPhrases.filter {
                $0.text.localizedCaseInsensitiveContains(trimmedQuery) || $0.meaning.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        let combined = filteredCustom + filteredBuiltIn
        let liveSuggestion = PresentationAdvisor.contextualLiveRecommendation(
            session: session,
            cards: cards,
            activeCardIndex: activeIndex,
            languageCode: langCode
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("전환구 치트시트 (\(LanguageCatalog.displayName(for: langCode, in: model.uiLanguage)))")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                if model.recommendingPresentation {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    Task { await model.recommendPresentationAids() }
                } label: {
                    Label("맞춤 추천", systemImage: "sparkles")
                }
                .controlSize(.mini)
                .disabled(model.recommendingPresentation || model.current?.archivedAt != nil)
                .help("현재 발표 시간과 메모 내용에 꼭 맞는 전환구 표현을 추천합니다")
                Button {
                    showingAddPhrase.toggle()
                } label: {
                    Label("내 표현", systemImage: showingAddPhrase ? "minus.circle" : "plus.circle")
                }
                .controlSize(.mini)
            }

            // Live context-aware "Right Now" signposting card
            if !liveSuggestion.phrases.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Label(liveSuggestion.badge, systemImage: liveSuggestion.category.icon)
                            .font(.caption2.bold())
                            .foregroundStyle(.teal)
                        Spacer()
                        Button(liveSuggestion.category.title + " 더보기") {
                            selectedCategory = liveSuggestion.category
                            phraseSearch = ""
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.teal)
                    }
                    Text(liveSuggestion.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(liveSuggestion.phrases) { item in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.text)
                                    .font(.caption.weight(.semibold))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.meaning)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                                copiedPhraseID = item.id
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if copiedPhraseID == item.id { copiedPhraseID = nil }
                                }
                            } label: {
                                Image(systemName: copiedPhraseID == item.id ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(copiedPhraseID == item.id ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(8)
                .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }

            // Recommended topic-specific phrases tray
            if let rec = model.presentationRecommendation, !rec.phrases.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Label(rec.isAIGenerated ? "AI 맞춤 추천 전환구" : "내용 기반 추천 전환구", systemImage: "sparkles")
                            .font(.caption2.bold())
                            .foregroundStyle(.purple)
                        Spacer()
                        Button("모두 저장") { model.acceptAllPresentationRecommendations() }
                            .controlSize(.mini)
                        Button { model.dismissPresentationRecommendations() } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(rec.phrases) { phrase in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(phrase.category.title)] \(phrase.text)")
                                    .font(.caption.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(phrase.meaning)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                model.acceptRecommendedPhrase(phrase)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                            .help("내 전환구에 저장")
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if showingAddPhrase {
                VStack(spacing: 6) {
                    TextField("발표 표현 (예: Let me double-check that after the session.)", text: $newPhraseText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    HStack(spacing: 6) {
                        TextField("뜻 / 메모 (선택)", text: $newPhraseMeaning)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("저장") {
                            model.addCustomPhrase(category: selectedCategory, text: newPhraseText, meaning: newPhraseMeaning)
                            newPhraseText = ""
                            newPhraseMeaning = ""
                            showingAddPhrase = false
                        }
                        .controlSize(.small)
                        .disabled(newPhraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("전환구 검색 (예: chart, demo, Q&A, 시간…)", text: $phraseSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if trimmedQuery.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(SignpostingCategory.allCases) { cat in
                            let selected = selectedCategory == cat
                            Button {
                                selectedCategory = cat
                            } label: {
                                Text(cat.title)
                                    .font(.caption2.weight(selected ? .bold : .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selected ? Color.purple : Color.secondary.opacity(0.10), in: Capsule())
                                    .foregroundStyle(selected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if combined.isEmpty {
                        Text("일치하는 전환구가 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(combined) { phrase in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(phrase.text)
                                    .font(.system(size: 13, weight: .semibold))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 6) {
                                    if !trimmedQuery.isEmpty {
                                        Text(phrase.category.title)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.purple)
                                    }
                                    Text(phrase.meaning)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if phrase.isCustom {
                                        Text("내 표현")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.purple)
                                    }
                                }
                            }
                            VStack(spacing: 4) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(phrase.text, forType: .string)
                                    copiedPhraseID = phrase.id
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.2))
                                        if copiedPhraseID == phrase.id { copiedPhraseID = nil }
                                    }
                                } label: {
                                    Image(systemName: copiedPhraseID == phrase.id ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(copiedPhraseID == phrase.id ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("표현 복사")

                                if phrase.isCustom {
                                    Button {
                                        model.removeCustomPhrase(phrase.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(9)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Live Q&A Mode Right Column

    private var qaCompanionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Q&A 실시간 대응 중", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.teal)
                Spacer()
                Button {
                    Task { await model.advise() }
                } label: {
                    Label("답변 추천", systemImage: "sparkles")
                }
                .controlSize(.mini)
                .disabled(model.generating)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VSplitView {
                TranslationView(model: model)
                    .frame(minHeight: 160, idealHeight: 230)
                    .padding(.bottom, 6)

                CoachView(model: model)
                    .frame(minHeight: 180, idealHeight: 260)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Formatting Helpers

    private func formatClock(_ remaining: TimeInterval) -> String {
        let sign = remaining < 0 ? "+" : ""
        return sign + formatDuration(abs(remaining))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
