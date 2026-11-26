import SwiftUI
import AppKit
import Translation

final class SpikDoumAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep SpikDoum running in the right-side menu bar tray when the main window is closed.
        false
    }
}

@main
struct SpikDoumApp: App {
    @NSApplicationDelegateAdaptor(SpikDoumAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    init() {
        AppStorageMigration.migrateDefaultsIfNeeded()
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("SpikDoum", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1060, minHeight: 760)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop(); model.saveSynchronously(); model.managedModels.shutdown() }
        }
        .commands {
            CommandMenu(model.t("menu.conversation")) {
                Button(model.t("action.newConversation")) { model.newConversation(autoStart: true) }.keyboardShortcut("n")
                Toggle("내 마이크 음소거", isOn: $model.micMuted).keyboardShortcut("m", modifiers: [.command, .shift]).disabled(model.systemAudioOnly)
                Toggle("심플 패스트 모드 (STT · 번역 전용)", isOn: $model.simpleFastMode).keyboardShortcut("f", modifiers: [.command, .shift])
                Toggle("상단 패널 접기", isOn: $model.topHeaderCollapsed).keyboardShortcut("t", modifiers: [.command, .shift])
                Toggle("화면 공유에서 창 숨기기", isOn: $model.hideFromScreenShare).keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Menu("퍼스펙티브 전환") {
                    Button("기본") { model.switchPerspective(.standard) }.keyboardShortcut("1", modifiers: [.command])
                    Button("프레젠테이션") { model.switchPerspective(.presentation) }.keyboardShortcut("2", modifiers: [.command])
                    Button("미팅") { model.switchPerspective(.meeting) }.keyboardShortcut("3", modifiers: [.command])
                    Button("온라인 교육") { model.switchPerspective(.learning) }.keyboardShortcut("4", modifiers: [.command])
                }
                Menu("STT · 번역 5단계 속도/정확도") {
                    Button("⚡ 초고속 하이브리드 (STT 초신속 · Apple 번역 · 로컬 LLM)") { Task { await model.applyHybridFastPreset() } }.keyboardShortcut("0", modifiers: [.command, .option])
                    Divider()
                    Button("1단계 · 초신속") { Task { await model.applySpeedQualityTier(.ultraFast) } }.keyboardShortcut("1", modifiers: [.command, .option])
                    Button("2단계 · 신속") { Task { await model.applySpeedQualityTier(.fast) } }.keyboardShortcut("2", modifiers: [.command, .option])
                    Button("3단계 · 비교적 정확") { Task { await model.applySpeedQualityTier(.balanced) } }.keyboardShortcut("3", modifiers: [.command, .option])
                    Button("4단계 · 정확 (추천)") { Task { await model.applySpeedQualityTier(.accurate) } }.keyboardShortcut("4", modifiers: [.command, .option])
                    Button("5단계 · 최고 정확") { Task { await model.applySpeedQualityTier(.maxAccuracy) } }.keyboardShortcut("5", modifiers: [.command, .option])
                }
                Button(model.t("action.getAdviceNow")) { Task { await model.advise() } }.keyboardShortcut(.return, modifiers: [.command]).disabled(model.simpleFastMode)
                Button(model.t("action.stopListening")) { model.pauseListening() }.keyboardShortcut(".")
                Divider()
                Button(model.t("action.replayMenu")) {
                    if let id = model.selectedID { model.openReplay(id) }
                }.keyboardShortcut("r").disabled(model.current == nil || model.starting)
                Button(model.t("action.exportMarkdown")) {
                    if let current = model.current, let error = ConversationExport.saveWithPanel(current) { model.message = error }
                }.keyboardShortcut("e").disabled(model.current == nil)
            }
        }
        Window("실시간 조언", id: "coach") {
            CoachView(model: model).padding(20).frame(minWidth: 340, minHeight: 240)
                .background(WindowLevel())
                .background(WindowPrivacyController(hideFromScreenShare: model.hideFromScreenShare).allowsHitTesting(false))
        }.defaultSize(width: 400, height: 300)
        Window("프레젠터 HUD (Google Meet 숨김)", id: "presenter-hud") {
            PresenterHUDView(model: model)
                .frame(minWidth: 560, minHeight: 190)
        }.defaultSize(width: 740, height: 240)
        MenuBarExtra {
            MenuBarTrayView(model: model)
        } label: {
            DragonflyTrayIcon(listening: model.listening, starting: model.starting)
        }
        .menuBarExtraStyle(.window)
    }
}
struct WindowLevel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = .floating; view.window?.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces] }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showSummaryScriptPanel") private var showSummaryScriptPanel = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var focusLayout: (summaryScript: Bool, columns: NavigationSplitViewVisibility)?
    private var isFocused: Bool { focusLayout != nil }
    private func toggleFocus() {
        if let previous = focusLayout {
            showSummaryScriptPanel = previous.summaryScript
            columnVisibility = previous.columns; focusLayout = nil
        } else {
            focusLayout = (showSummaryScriptPanel, columnVisibility)
            showSummaryScriptPanel = false; columnVisibility = .detailOnly
        }
    }
    @AppStorage("linkedConversationView") private var linkedConversationView = true
    @State private var startedRequestedCapture = false
    @State private var showingModels = false
    @State private var showingSettings = false
    @State private var showingCaptureSettings = false
    @State private var showingPanelFonts = false
    @State private var showingArchive = false
    @State private var searchQuery = ""
    @State private var pendingDeletion: Set<UUID> = []
    @State private var selectingConversations = false
    @State private var selectedConversations: Set<UUID> = []
    @State private var dropTargetPanel: String?
    private var visibleSelection: Set<UUID> { selectedConversations.intersection(visibleConversations.map(\.id)) }
    private var deletionDescription: String {
        let titles = model.conversations.filter { pendingDeletion.contains($0.id) }.prefix(3).map(\.title).joined(separator: "\n")
        return "선택한 \(pendingDeletion.count)개 대화의 원문, 번역, 조언, 요약 이력과 앱 관리 백업의 사본을 삭제합니다. 복원할 수 없습니다.\n\n" + titles + (pendingDeletion.count > 3 ? "\n외 \(pendingDeletion.count - 3)개" : "")
    }
    private var visibleConversations: [Conversation] { ConversationSearch.filter(model.conversations, query: searchQuery, archived: showingArchive) }
    private func requestRemoval(_ id: UUID) {
        if model.deletionMode == .archive { model.archiveConversation(id) }
        else { pendingDeletion = [id] }
    }
    @ViewBuilder
    private func splitPanelContent(for panel: WorkspacePanelKind) -> some View {
        switch panel {
        case .stt:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label(model.listening ? model.t("panel.sttLive") : model.t("panel.stt"), systemImage: "mic.fill").font(.title3.bold()).foregroundStyle(.blue)
                    Spacer(minLength: 4)
                    PanelFontButton(title: "STT 원문", value: $model.sttAppearance.fontSize, range: STTAppearance.minFontSize...STTAppearance.maxFontSize, defaultValue: 20)
                    Menu {
                        Button {
                            model.selectSTTLanguage(LanguageCatalog.autoCode)
                        } label: {
                            if model.isAutoDetectLanguage {
                                Label(model.t("stt.mode.auto"), systemImage: "checkmark")
                            } else {
                                Label(model.t("stt.mode.auto"), systemImage: "sparkles")
                            }
                        }
                        Divider()
                        ForEach(LanguageCatalog.all) { lang in
                            Button {
                                model.selectSTTLanguage(lang.code)
                            } label: {
                                if !model.isAutoDetectLanguage && model.language == lang.code {
                                    Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                } else {
                                    Text(lang.displayName(in: model.uiLanguage))
                                }
                            }
                        }
                    } label: {
                        Label(model.sttLanguageBadge, systemImage: model.isAutoDetectLanguage ? "sparkles" : "character.bubble")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.starting)
                    .help(model.t("settings.sourceLanguage"))
                }
                Text(model.systemAudioOnly ? "Mac 재생음을 인식합니다." : "마이크를 사용합니다. 듣기 전 상대에게 알려주세요.").font(.caption).foregroundStyle(.secondary)
                Text(model.speakerStatus).font(.caption).foregroundStyle(.secondary)
                STTPanel(model: model)
                Text("음성 인식은 기기 지원 여부에 따라 Apple 서버를 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .translation:
            TranslationView(model: model)
        case .coach:
            CoachView(model: model)
        case .summaryScript:
            SummaryScriptPanel(model: model)
        }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("SpikDoum").font(.title2.bold())
                    Spacer()
                    PanelFontButton(title: "대화 목록", value: $model.panelTypography.sidebar, defaultValue: 14)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { columnVisibility = .detailOnly }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("대화 목록 사이드바 숨기기")
                }
                Text(model.t("app.tagline")).foregroundStyle(.secondary)
                Button(action: { showingArchive = false; model.newConversation(autoStart: true) }) { Label(model.t("action.newConversation"), systemImage: "plus") }.disabled(model.starting)
                Toggle(model.t("action.autoListenOnNew"), isOn: $model.autoStartListeningOnNewConversation)
                    .font(.caption)
                    .help("새 대화 버튼 또는 ⌘N 실행 시 현재 듣기 설정으로 즉시 듣기를 시작합니다.")
                Picker(model.t("tab.conversations"), selection: $showingArchive) {
                    Text(model.t("tab.conversations")).tag(false)
                    Text(model.t("tab.archive")).tag(true)
                }.pickerStyle(.segmented)
                .onChange(of: showingArchive) { _, _ in
                    selectedConversations = []
                    if visibleConversations.contains(where: { $0.id == model.selectedID }) { return }
                    if let first = visibleConversations.first { model.select(first.id) }
                    else { model.stop(); model.selectedID = nil }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.t("search.placeholder"), text: $searchQuery).textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }.font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(selectingConversations ? model.t("select.done") : model.t("select.multi")) {
                        selectingConversations.toggle(); selectedConversations = []
                    }.disabled(model.starting)
                    if selectingConversations {
                        Spacer()
                        Button(visibleSelection.count == visibleConversations.count && !visibleConversations.isEmpty ? model.t("select.none") : model.t("select.all")) {
                            selectedConversations = visibleSelection.count == visibleConversations.count ? [] : Set(visibleConversations.map(\.id))
                        }.disabled(visibleConversations.isEmpty || model.starting)
                    }
                }.font(.caption)
                List(visibleConversations) { item in
                    Button {
                        if selectingConversations {
                            if selectedConversations.contains(item.id) { selectedConversations.remove(item.id) }
                            else { selectedConversations.insert(item.id) }
                        } else { model.select(item.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            if selectingConversations {
                                Image(systemName: selectedConversations.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedConversations.contains(item.id) ? Color.accentColor : .secondary).padding(.top, 7)
                            }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: model.panelTypography.sidebar)).lineLimit(2).foregroundStyle(model.selectedID == item.id ? Color.accentColor : .primary)
                            if let preview = item.preview, !preview.isEmpty {
                                Text(preview).font(.system(size: max(12, model.panelTypography.sidebar - 2))).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack(spacing: 4) {
                                Text(item.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                if let clips = item.audioClips, !clips.isEmpty {
                                    Image(systemName: "waveform").font(.caption2).foregroundStyle(.blue).help("음성 녹음 \(clips.count)개 포함")
                                }
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(selectingConversations ? "\(selectedConversations.contains(item.id) ? "선택됨" : "선택 안 됨") · \(item.title)" : item.title).disabled(model.starting)
                        .contextMenu {
                            Button("대화 다시 재생…") { model.openReplay(item.id) }
                            Button("Markdown 내보내기…") {
                                if let error = ConversationExport.saveWithPanel(item) { model.message = error }
                            }
                            Divider()
                            if item.archivedAt != nil {
                                Button("대화 복원") { model.restoreConversation(item.id); model.select(item.id); showingArchive = false }
                                Button("완전 삭제…", role: .destructive) { pendingDeletion = [item.id] }
                            } else {
                                Button(model.deletionMode == .archive ? "아카이빙" : "완전 삭제…", role: model.deletionMode == .permanent ? .destructive : nil) { requestRemoval(item.id) }
                            }
                        }
                }.listStyle(.plain)
                if selectingConversations {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(visibleSelection.count)개 선택됨").font(.caption.bold())
                        Button {
                            if showingArchive { model.restoreConversations(visibleSelection) }
                            else { model.archiveConversations(visibleSelection) }
                            selectedConversations = []
                        } label: { Label(showingArchive ? "선택 대화 복원" : "선택 대화 아카이브", systemImage: showingArchive ? "arrow.uturn.backward" : "archivebox") }
                        .disabled(visibleSelection.isEmpty || model.starting)
                        Button(role: .destructive) { pendingDeletion = visibleSelection } label: { Label("선택 대화 완전 삭제…", systemImage: "trash") }
                            .disabled(visibleSelection.isEmpty || model.starting)
                    }
                }
                Text(model.t("app.localStorageNotice")).font(.caption).foregroundStyle(.secondary)
            }.padding().navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(alignment: .leading, spacing: model.topHeaderCollapsed ? 5 : 8) {
                if model.topHeaderCollapsed {
                    collapsedTopHeaderBar
                } else {
                HStack(spacing: 10) {
                    Button {
                        showingArchive = false
                        model.newConversation(autoStart: true)
                    } label: {
                        Label(model.t("action.newConversation"), systemImage: "plus")
                    }
                    .fixedSize()
                    .help(model.t("action.newConversation") + " (⌘N)")
                    .disabled(model.starting)
                    VStack(alignment: .leading) {
                        Text(model.current?.title ?? model.t("action.newConversation")).font(.headline).lineLimit(1)
                        Label(model.sttStatus, systemImage: model.listening ? "waveform" : "mic")
                            .font(.caption).foregroundStyle(model.listening ? .green : .secondary)
                    }
                    Spacer()
                    if let item = model.current {
                        Button { model.openReplay(item.id) } label: { Label(model.t("action.replay"), systemImage: "play.circle") }
                            .help(model.t("action.replayMenu") + " (⌘R)")
                            .disabled(model.starting || (item.transcript.isEmpty && (item.audioClips ?? []).isEmpty))
                        Button {
                            if let error = ConversationExport.saveWithPanel(item) { model.message = error }
                        } label: { Image(systemName: "square.and.arrow.up") }
                            .help(model.t("action.exportMarkdown") + " (⌘E)")
                        if item.archivedAt != nil {
                            Button(model.t("action.restore")) { model.restoreConversation(item.id); showingArchive = false }
                        } else {
                            Button { requestRemoval(item.id) } label: { Image(systemName: model.deletionMode == .archive ? "archivebox" : "trash") }
                                .help(model.deletionMode == .archive ? "대화 아카이빙" : "대화 완전 삭제")
                                .disabled(model.starting)
                        }
                    }
                    if !model.systemAudioOnly {
                        if model.micMuted {
                            Button {
                                model.micMuted = false
                            } label: {
                                Label("마이크 음소거 해제", systemImage: "mic.slash.fill")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .help("내 마이크 음소거됨 · 클릭 또는 ⇧⌘M으로 해제 (Mac 재생음은 계속 인식)")
                        } else {
                            Button {
                                model.micMuted = true
                            } label: {
                                Label("내 마이크 음소거", systemImage: "mic.fill")
                            }
                            .labelStyle(.iconOnly)
                            .help("내 마이크 음소거 (⇧⌘M · Mac 재생음은 계속 인식)")
                        }
                    }
                    if model.simpleFastMode {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { model.simpleFastMode = false }
                        } label: {
                            Label("심플 모드", systemImage: "bolt.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .help("심플 모드 켜짐 · STT·번역 성능 집중 (클릭 또는 ⇧⌘F로 전체 모드 복귀)")
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { model.simpleFastMode = true }
                        } label: {
                            Label("심플 모드", systemImage: "bolt")
                        }
                        .labelStyle(.iconOnly)
                        .help("심플 모드 켜기 · STT·번역 성능 집중 (코치·키워드·요약·스크립트 중지, ⇧⌘F)")
                    }
                    Button { toggleFocus() } label: {
                        Label(isFocused ? model.t("panel.restoreLayout") : model.t("panel.focus"), systemImage: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.labelStyle(.iconOnly).help(isFocused ? model.t("panel.restoreLayout") : model.t("panel.focus"))
                    Button { showingCaptureSettings = true } label: { Label(model.t("settings.captureTitle"), systemImage: "slider.horizontal.3") }
                        .labelStyle(.iconOnly).help(model.t("settings.captureTitle") + " · " + model.captureSummary)
                    Button { showingPanelFonts = true } label: { Label("글자 크기", systemImage: "textformat.size") }
                        .labelStyle(.iconOnly).help("글자 크기")
                        .popover(isPresented: $showingPanelFonts) { PanelFontControls(model: model).padding(20).frame(width: 460) }
                    Button { showingModels = true } label: { Label("모델 · 서버 관리", systemImage: "server.rack") }
                        .labelStyle(.iconOnly).help("자체 STT · 번역 모델 다운로드 및 서버 모니터")
                    Button { showingSettings = true } label: { Label(model.t("settings.title"), systemImage: "gearshape") }
                        .labelStyle(.iconOnly).help(model.t("settings.title")).disabled(model.starting)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if !showSummaryScriptPanel || !model.panelLayout.hasAnySummaryScriptVisible {
                                showSummaryScriptPanel = true
                                if !model.panelLayout.hasAnySummaryScriptVisible {
                                    model.panelLayout.setVisible(.summary, true)
                                    model.panelLayout.setVisible(.script, true)
                                }
                            } else {
                                showSummaryScriptPanel = false
                            }
                        }
                    } label: {
                        Label(model.t("panel.summaryScriptToggle"), systemImage: (showSummaryScriptPanel && model.panelLayout.hasAnySummaryScriptVisible) ? "sidebar.right" : "sidebar.squares.right")
                    }.labelStyle(.iconOnly).help(model.t("panel.summaryScriptToggle"))
                    let anyPanelHidden = columnVisibility == .detailOnly
                        || model.panelLayout.hasHiddenPanels
                        || !showSummaryScriptPanel
                        || !model.showTranslationKeywords
                    Menu {
                        Section("패널 표시 / 숨기기") {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                                }
                            } label: {
                                Label("대화 목록 (사이드바)", systemImage: columnVisibility == .detailOnly ? "circle" : "checkmark")
                            }
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.panelLayout.toggle(.stt, includeCoach: !model.simpleFastMode)
                                }
                            } label: {
                                Label("STT 원문", systemImage: model.panelLayout.isVisible(.stt) ? "checkmark" : "circle")
                            }
                            .disabled(model.panelLayout.isVisible(.stt) && !model.panelLayout.canHide(.stt, includeCoach: !model.simpleFastMode))
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.panelLayout.toggle(.translation, includeCoach: !model.simpleFastMode)
                                }
                            } label: {
                                Label("번역", systemImage: model.panelLayout.isVisible(.translation) ? "checkmark" : "circle")
                            }
                            .disabled(model.panelLayout.isVisible(.translation) && !model.panelLayout.canHide(.translation, includeCoach: !model.simpleFastMode))
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.showTranslationKeywords.toggle()
                                    if model.showTranslationKeywords {
                                        showSummaryScriptPanel = true
                                    }
                                }
                            } label: {
                                Label("핵심 키워드", systemImage: (!model.simpleFastMode && model.showTranslationKeywords) ? "checkmark" : "circle")
                            }
                            .disabled(model.simpleFastMode)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.panelLayout.toggle(.coach, includeCoach: true)
                                }
                            } label: {
                                Label("대화 코치 (답변 · 조언)", systemImage: (!model.simpleFastMode && model.panelLayout.isVisible(.coach)) ? "checkmark" : "circle")
                            }
                            .disabled(model.simpleFastMode || (model.panelLayout.isVisible(.coach) && !model.panelLayout.canHide(.coach, includeCoach: true)))
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    let currentlyVisible = showSummaryScriptPanel && model.panelLayout.isVisible(.summary)
                                    if currentlyVisible {
                                        model.panelLayout.setVisible(.summary, false)
                                    } else {
                                        showSummaryScriptPanel = true
                                        model.panelLayout.setVisible(.summary, true)
                                    }
                                }
                            } label: {
                                Label("대화 요약", systemImage: (!model.simpleFastMode && showSummaryScriptPanel && model.panelLayout.isVisible(.summary)) ? "checkmark" : "circle")
                            }
                            .disabled(model.simpleFastMode)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    let currentlyVisible = showSummaryScriptPanel && model.panelLayout.isVisible(.script)
                                    if currentlyVisible {
                                        model.panelLayout.setVisible(.script, false)
                                    } else {
                                        showSummaryScriptPanel = true
                                        model.panelLayout.setVisible(.script, true)
                                    }
                                }
                            } label: {
                                Label("전체 스크립트", systemImage: (!model.simpleFastMode && showSummaryScriptPanel && model.panelLayout.isVisible(.script)) ? "checkmark" : "circle")
                            }
                            .disabled(model.simpleFastMode)
                        }
                        if anyPanelHidden {
                            Divider()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    columnVisibility = .all
                                    showSummaryScriptPanel = true
                                    model.showTranslationKeywords = true
                                    model.panelLayout.showAllPanels()
                                }
                            } label: {
                                Label("숨긴 패널 모두 다시 표시", systemImage: "eye")
                            }
                        }
                        Divider()
                        Toggle("상단 패널 접기 (⇧⌘T)", isOn: $model.topHeaderCollapsed)
                        Toggle("심플 모드 (STT · 번역 성능 집중)", isOn: $model.simpleFastMode)
                        Button(model.t("panel.coachWindow")) { openWindow(id: "coach") }
                        Divider()
                        Button(model.t("panel.swapVertical")) {
                            withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.toggleSummaryScriptOrder() }
                        }
                        Button(model.t("panel.resetOrder")) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSummaryScriptPanel = true
                                model.showTranslationKeywords = true
                                columnVisibility = .all
                                model.panelLayout.reset()
                            }
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Label("패널 표시", systemImage: "rectangle.3.group").labelStyle(.iconOnly)
                            if anyPanelHidden {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    .help(anyPanelHidden ? "패널 표시 / 숨기기 (일부 패널 숨겨짐 · 클릭하여 복원)" : "패널 표시 / 숨기기 및 배치 관리")
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { model.topHeaderCollapsed = true }
                    } label: {
                        Label("상단 접기", systemImage: "chevron.up")
                    }
                    .labelStyle(.iconOnly)
                    .help("상단 패널 접기 · 아래 내용 넓게 보기 (⇧⌘T)")
                    Button {
                        if model.listening { model.pauseListening() } else { Task { await model.start() } }
                    } label: { Label(model.finishingCapture ? model.t("action.finishingAudio") : model.starting ? ((model.settings.stt == .managed || model.settings.stt == .parakeet || model.settings.translation == .managed) ? model.t("action.preparingModel") : model.t("action.checkingPermissions")) : model.listening ? model.t("action.stopListening") : model.t("action.startListening"), systemImage: model.listening ? "stop.fill" : "mic.fill") }
                        .buttonStyle(.borderedProminent).disabled(model.finishingCapture || model.starting || model.current == nil || model.current?.archivedAt != nil)
                }
                HStack(spacing: 6) {
                    ForEach(AppPerspective.allCases) { item in
                        let selected = model.perspective == item
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                model.switchPerspective(item)
                            }
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .font(.caption.weight(selected ? .bold : .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selected ? item.accentColor : Color.secondary.opacity(0.10), in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help("\(item.title) · \(item.subtitle)")
                    }
                    if model.hideFromScreenShare {
                        Button {
                            model.hideFromScreenShare = false
                        } label: {
                            Label("화면 공유 숨김 중", systemImage: "eye.slash.fill")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.purple.opacity(0.16), in: Capsule())
                                .foregroundStyle(.purple)
                        }
                        .buttonStyle(.plain)
                        .help("화면 공유에서 SpikDoum 창이 숨겨져 있습니다 · 클릭하여 해제")
                    }
                    Spacer()
                    if model.perspective != .standard {
                        Text(model.perspective.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                }
                if (model.includeSystemAudio || model.systemAudioOnly) && !model.systemAudioPermissionGranted {
                    HStack {
                        Label("시스템 오디오 권한이 필요합니다", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Link("권한 설정 열기", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.font(.caption)
                }
                if let error = model.message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = model.deviceError {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                        Text(error).foregroundStyle(.orange)
                        Spacer(minLength: 4)
                        Button("기본 마이크 사용") { model.useDefaultInputDevice() }.controlSize(.mini)
                        Button(model.t("settings.captureTitle")) { showingCaptureSettings = true }.controlSize(.mini)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if !model.topHeaderCollapsed {
                if let notice = model.presetNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text(notice).foregroundStyle(.blue)
                        Spacer(minLength: 4)
                        Button { model.presetNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.settings.usesAppleLLMForAnyTask, let status = model.modelStatus {
                    DisclosureGroup("Apple Intelligence 안내") {
                        Text(status).foregroundStyle(.orange)
                    }.font(.caption)
                }
                HStack(spacing: 10) {
                    Label(model.t("live.header"), systemImage: "waveform.circle.fill").font(.headline).foregroundStyle(.blue)
                    Picker("범위", selection: $model.recentSeconds) {
                        Text(model.t("range.all")).tag(0)
                        Text(model.t("range.2min")).tag(120)
                        Text(model.t("range.1min")).tag(60)
                    }
                        .labelsHidden().frame(width: 104)
                    Picker("보기", selection: $linkedConversationView) { Text(model.t("view.linked")).tag(true); Text(model.simpleFastMode ? "2패널 보기" : model.t("view.3panel")).tag(false) }
                        .labelsHidden().frame(width: 98)
                    QuickAudioSourceMenu(model: model)
                    QuickSpeedQualityMenu(model: model)
                    Menu {
                        Section(model.t("settings.sourceLanguage")) {
                            Button {
                                model.selectSTTLanguage(LanguageCatalog.autoCode)
                            } label: {
                                if model.isAutoDetectLanguage {
                                    Label(model.t("stt.mode.auto"), systemImage: "checkmark")
                                } else {
                                    Label(model.t("stt.mode.auto"), systemImage: "sparkles")
                                }
                            }
                            if !model.recentDetectedLanguages.isEmpty {
                                let names = model.recentDetectedLanguages.prefix(3).map { $0.displayName(in: model.uiLanguage) }.joined(separator: " · ")
                                let confText = model.detectedLanguageConfidence.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
                                Text("감지됨: \(names)\(confText)")
                            }
                        }
                        Menu("다국어 자동 인식 설정 · \(model.autoLanguagePrefs.shortSummary)") {
                            Section("자동 전환 방식") {
                                ForEach(AutoLanguageMode.allCases) { mode in
                                    Button {
                                        model.autoLanguagePrefs.mode = mode
                                    } label: {
                                        if model.autoLanguagePrefs.mode == mode {
                                            Label(mode.title, systemImage: "checkmark")
                                        } else {
                                            Text(mode.title)
                                        }
                                    }
                                }
                            }
                            Divider()
                            Section("빠른 다국어 후보 프리셋") {
                                Button("전체 언어 자유 감지 (제한 없음)") {
                                    model.applyAutoLanguagePreset([], notice: "모든 지원 언어를 자유롭게 자동 감지합니다.")
                                }
                                Button("한국어 · 영어 (KO · EN)") {
                                    model.applyAutoLanguagePreset(["ko-KR", "en-US"], notice: "다국어 자동 감지 후보를 한국어·영어로 설정했습니다.")
                                }
                                Button("한국어 · 일본어 (KO · JA)") {
                                    model.applyAutoLanguagePreset(["ko-KR", "ja-JP"], notice: "다국어 자동 감지 후보를 한국어·일본어로 설정했습니다.")
                                }
                                Button("한국어 · 영어 · 일본어 (KO · EN · JA)") {
                                    model.applyAutoLanguagePreset(["ko-KR", "en-US", "ja-JP"], notice: "다국어 자동 감지 후보를 한·영·일로 설정했습니다.")
                                }
                                Button("한 · 영 · 일 · 중 (4개 국어)") {
                                    model.applyAutoLanguagePreset(["ko-KR", "en-US", "ja-JP", "zh-CN"], notice: "다국어 자동 감지 후보를 한·영·일·중으로 설정했습니다.")
                                }
                            }
                            Divider()
                            Section("예상 언어 후보 직접 선택 (복수)") {
                                ForEach(LanguageCatalog.all) { lang in
                                    let chosen = model.autoLanguagePrefs.preferredCodes.contains(lang.code)
                                    Button {
                                        model.autoLanguagePrefs.toggleCandidate(lang.code)
                                    } label: {
                                        if chosen {
                                            Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                        } else {
                                            Text(lang.displayName(in: model.uiLanguage))
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Section("고정 언어 선택") {
                            ForEach(LanguageCatalog.all) { lang in
                                Button {
                                    model.selectSTTLanguage(lang.code)
                                } label: {
                                    if !model.isAutoDetectLanguage && model.language == lang.code {
                                        Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                    } else {
                                        Text(lang.displayName(in: model.uiLanguage))
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("STT: \(model.sttLanguageBadge)", systemImage: model.isAutoDetectLanguage ? "sparkles" : "mic")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.starting)
                    .help(model.t("settings.sourceLanguage"))
                    QuickSTTModelMenu(model: model) { showingModels = true }
                    Menu {
                        Section(model.t("settings.targetLanguage")) {
                            ForEach(LanguageCatalog.all) { lang in
                                Button {
                                    model.selectTargetLanguage(lang.code)
                                } label: {
                                    if model.targetLanguage == lang.code {
                                        Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                    } else {
                                        Text(lang.displayName(in: model.uiLanguage))
                                    }
                                }
                            }
                        }
                        Divider()
                        Section(model.t("settings.uiLanguage")) {
                            ForEach(AppInterfaceLanguage.allCases) { option in
                                Button {
                                    model.interfaceLanguage = option
                                } label: {
                                    if model.interfaceLanguage == option {
                                        Label(option.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                    } else {
                                        Text(option.displayName(in: model.uiLanguage))
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("→ \(model.targetLanguageName)", systemImage: "globe")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("\(model.t("settings.targetLanguage")) · \(model.t("settings.uiLanguage"))")
                    QuickTranslationModelMenu(model: model) { showingModels = true }
                    if !model.simpleFastMode {
                        QuickLLMModelMenu(model: model, onOpenSettings: { showingSettings = true }, onOpenManager: { showingModels = true })
                    }
                    Spacer()
                    if !model.followLive {
                        Text(model.hasUnreadLiveChanges ? model.t("reading.pausedReceiving") : model.t("reading.paused")).font(.caption.bold()).foregroundStyle(.orange)
                    }
                    Button {
                        if model.followLive { model.pauseReading() } else { model.resumeReading() }
                    } label: { Label(model.followLive ? model.t("reading.pause") : model.t("reading.resume"), systemImage: model.followLive ? "pause.circle" : "arrow.down.to.line") }
                }.controlSize(.small)
                }
                let effectiveShowSummary = !model.simpleFastMode && showSummaryScriptPanel && (model.panelLayout.hasAnySummaryScriptVisible || model.showTranslationKeywords)
                if model.perspective == .presentation {
                    PresentationWorkspaceView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if linkedConversationView {
                    let linkedSides: [String] = effectiveShowSummary
                        ? (model.panelLayout.linkedSummaryOnLeft ? ["linked-summary", "linked-main"] : ["linked-main", "linked-summary"])
                        : ["linked-main"]
                    HSplitView {
                        ForEach(Array(linkedSides.enumerated()), id: \.element) { index, side in
                            let isFirst = index == 0
                            let isLast = index == linkedSides.count - 1
                            if side == "linked-summary" {
                                VStack(alignment: .leading, spacing: model.topHeaderCollapsed ? 4 : 6) {
                                    if !model.topHeaderCollapsed {
                                        PanelReorderBar(
                                            title: model.t("panel.summaryScriptToggle"),
                                            icon: "doc.text",
                                            dragPayload: side,
                                            canMoveLeft: !isFirst,
                                            canMoveRight: !isLast,
                                            moveLeftHelp: model.t("panel.moveLeft"),
                                            moveRightHelp: model.t("panel.moveRight"),
                                            dragHelp: model.t("panel.dragHint"),
                                            onMoveLeft: { withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() } },
                                            onMoveRight: { withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() } },
                                            extraActionIcon: (model.panelLayout.isVisible(.summary) && model.panelLayout.isVisible(.script)) ? "arrow.up.arrow.down" : nil,
                                            extraActionHelp: model.t("panel.swapVertical"),
                                            onExtraAction: { withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.toggleSummaryScriptOrder() } },
                                            hideHelp: "요약 · 스크립트 패널 숨기기",
                                            onHide: { withAnimation(.easeInOut(duration: 0.18)) { showSummaryScriptPanel = false } }
                                        )
                                    }
                                    SummaryScriptPanel(model: model)
                                }
                                .frame(minWidth: 300, idealWidth: 380)
                                .padding(.leading, isFirst ? 0 : 10)
                                .padding(.trailing, isLast ? 0 : 10)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: dropTargetPanel == side ? 2 : 0))
                                .dropDestination(for: String.self) { items, _ in
                                    dropTargetPanel = nil
                                    guard let dragged = items.first, dragged != side, dragged.hasPrefix("linked-") else { return false }
                                    withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() }
                                    return true
                                } isTargeted: { targeted in
                                    dropTargetPanel = targeted ? side : (dropTargetPanel == side ? nil : dropTargetPanel)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: model.topHeaderCollapsed ? 4 : 6) {
                                    if effectiveShowSummary && !model.topHeaderCollapsed {
                                        PanelReorderBar(
                                            title: model.t("view.linked"),
                                            icon: "rectangle.split.2x1",
                                            dragPayload: side,
                                            canMoveLeft: !isFirst,
                                            canMoveRight: !isLast,
                                            moveLeftHelp: model.t("panel.moveLeft"),
                                            moveRightHelp: model.t("panel.moveRight"),
                                            dragHelp: model.t("panel.dragHint"),
                                            onMoveLeft: { withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() } },
                                            onMoveRight: { withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() } }
                                        )
                                    }
                                    LinkedConversationView(model: model)
                                }
                                .frame(minWidth: 540, minHeight: 300)
                                .padding(.leading, isFirst ? 0 : 10)
                                .padding(.trailing, isLast ? 0 : 10)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: dropTargetPanel == side ? 2 : 0))
                                .dropDestination(for: String.self) { items, _ in
                                    dropTargetPanel = nil
                                    guard let dragged = items.first, dragged != side, dragged.hasPrefix("linked-") else { return false }
                                    withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.swapLinkedSide() }
                                    return true
                                } isTargeted: { targeted in
                                    dropTargetPanel = targeted ? side : (dropTargetPanel == side ? nil : dropTargetPanel)
                                }
                            }
                        }
                    }.frame(minHeight: 300)
                } else {
                    let allVisible = model.panelLayout.visibleSplitPanels(includeSummaryScript: effectiveShowSummary)
                    let visiblePanels = model.simpleFastMode
                        ? allVisible.filter { $0 == .stt || $0 == .translation }
                        : allVisible
                    HSplitView {
                        ForEach(Array(visiblePanels.enumerated()), id: \.element) { index, panel in
                            let isFirst = index == 0
                            let isLast = index == visiblePanels.count - 1
                            let canHideThisPanel: Bool = {
                                switch panel {
                                case .stt: return model.panelLayout.canHide(.stt, includeCoach: !model.simpleFastMode)
                                case .translation: return model.panelLayout.canHide(.translation, includeCoach: !model.simpleFastMode)
                                case .coach: return model.panelLayout.canHide(.coach, includeCoach: true)
                                case .summaryScript: return true
                                }
                            }()
                            VStack(alignment: .leading, spacing: model.topHeaderCollapsed ? 4 : 6) {
                                if !model.topHeaderCollapsed {
                                    PanelReorderBar(
                                        title: panel.title(in: model.uiLanguage),
                                        icon: panel.icon,
                                        dragPayload: panel.rawValue,
                                        canMoveLeft: !isFirst,
                                        canMoveRight: !isLast,
                                        moveLeftHelp: model.t("panel.moveLeft"),
                                        moveRightHelp: model.t("panel.moveRight"),
                                        dragHelp: model.t("panel.dragHint"),
                                        onMoveLeft: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                model.panelLayout.move(panel, by: -1, includeSummaryScript: effectiveShowSummary)
                                            }
                                        },
                                        onMoveRight: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                model.panelLayout.move(panel, by: 1, includeSummaryScript: effectiveShowSummary)
                                            }
                                        },
                                        extraActionIcon: (panel == .summaryScript && model.panelLayout.isVisible(.summary) && model.panelLayout.isVisible(.script)) ? "arrow.up.arrow.down" : nil,
                                        extraActionHelp: panel == .summaryScript ? model.t("panel.swapVertical") : nil,
                                        onExtraAction: panel == .summaryScript ? {
                                            withAnimation(.easeInOut(duration: 0.2)) { model.panelLayout.toggleSummaryScriptOrder() }
                                        } : nil,
                                        hideHelp: "\(panel.title(in: model.uiLanguage)) 패널 숨기기",
                                        onHide: canHideThisPanel ? {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                switch panel {
                                                case .stt: model.panelLayout.setVisible(.stt, false, includeCoach: !model.simpleFastMode)
                                                case .translation: model.panelLayout.setVisible(.translation, false, includeCoach: !model.simpleFastMode)
                                                case .coach: model.panelLayout.setVisible(.coach, false, includeCoach: true)
                                                case .summaryScript: showSummaryScriptPanel = false
                                                }
                                            }
                                        } : nil
                                    )
                                }
                                splitPanelContent(for: panel)
                            }
                            .frame(minWidth: panel == .summaryScript ? 280 : 220, idealWidth: panel == .summaryScript ? 360 : nil)
                            .padding(.leading, isFirst ? 0 : 10)
                            .padding(.trailing, isLast ? 0 : 10)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: dropTargetPanel == panel.rawValue ? 2 : 0))
                            .dropDestination(for: String.self) { items, _ in
                                dropTargetPanel = nil
                                guard let payload = items.first,
                                      let source = WorkspacePanelKind(rawValue: payload),
                                      source != panel else { return false }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    model.panelLayout.move(source, to: panel)
                                }
                                return true
                            } isTargeted: { targeted in
                                dropTargetPanel = targeted ? panel.rawValue : (dropTargetPanel == panel.rawValue ? nil : dropTargetPanel)
                            }
                        }
                    }.frame(minHeight: 260)
                }
            }.padding(model.topHeaderCollapsed ? 8 : 14)
                .background(WindowPrivacyController(hideFromScreenShare: model.hideFromScreenShare).allowsHitTesting(false))
                .background(ReadingSpaceShortcut(enabled: !showingModels && !showingSettings && !showingCaptureSettings && !showingPanelFonts && pendingDeletion.isEmpty && model.replayTarget == nil && model.perspective != .presentation) {
                    if model.followLive { model.pauseReading() } else { model.resumeReading() }
                }.allowsHitTesting(false))
                .onChange(of: model.perspective) { _, next in
                    switch next {
                    case .meeting:
                        showSummaryScriptPanel = true
                    case .learning:
                        linkedConversationView = true
                        showSummaryScriptPanel = true
                    case .standard, .presentation:
                        break
                    }
                }
                .sheet(item: $model.replayTarget) { item in ConversationReplayView(model: model, conversation: item) }
                .sheet(isPresented: $showingModels) { ManagedModelsView(model: model, manager: model.managedModels) }
                .sheet(isPresented: $showingCaptureSettings) { CaptureSettingsView(model: model) }
                .alert("대화 \(pendingDeletion.count)개를 완전히 삭제할까요?", isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })) {
                    Button("취소", role: .cancel) { pendingDeletion = [] }
                    Button("완전 삭제", role: .destructive) {
                        if model.permanentlyDeleteConversations(pendingDeletion) {
                            selectedConversations.subtract(pendingDeletion)
                            if model.current?.archivedAt == nil { showingArchive = false }
                        }
                        pendingDeletion = []
                    }
                } message: { Text(deletionDescription) }
                .sheet(isPresented: $showingSettings) { EngineSettingsView(model: model) }
                .translationTask(model.translationConfiguration) { session in
                    await model.prepareTranslation(using: session)
                }
                .task {
                    if !UserDefaults.standard.bool(forKey: "compactReadingLayoutV1") {
                        linkedConversationView = true
                        UserDefaults.standard.set(true, forKey: "compactReadingLayoutV1")
                    }
                    if !UserDefaults.standard.bool(forKey: "alignedSentenceBlocksV1") {
                        linkedConversationView = true
                        UserDefaults.standard.set(true, forKey: "alignedSentenceBlocksV1")
                    }
                    if !startedRequestedCapture && ProcessInfo.processInfo.arguments.contains("--listen-youtube") {
                        startedRequestedCapture = true
                        await model.startYouTube()
                    }
                    while !Task.isCancelled {
                        model.refreshInputDevices()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
        }
    }

    private var collapsedTopHeaderBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { model.topHeaderCollapsed = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                    Text("상단 펼치기")
                    if model.presetNotice != nil {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("상단 패널 펼치기 (⇧⌘T)")

            Menu {
                ForEach(AppPerspective.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { model.switchPerspective(item) }
                    } label: {
                        if model.perspective == item {
                            Label(item.title, systemImage: "checkmark")
                        } else {
                            Label(item.title, systemImage: item.icon)
                        }
                    }
                }
            } label: {
                Label(model.perspective.title, systemImage: model.perspective.icon)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(model.perspective.accentColor, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("퍼스펙티브 전환 (⌘1~4)")

            HStack(spacing: 5) {
                Circle()
                    .fill(model.listening ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(model.current?.title ?? model.t("action.newConversation"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text("· \(model.audioInputMode.shortLabel) · \(model.sttLanguageBadge) → \(model.targetLanguageName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if model.hideFromScreenShare {
                Label("공유 숨김", systemImage: "eye.slash.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.16), in: Capsule())
                    .foregroundStyle(.purple)
            }

            Spacer(minLength: 4)

            if !model.followLive {
                Button {
                    model.resumeReading()
                } label: {
                    Label(model.hasUnreadLiveChanges ? "새 발언 보기" : model.t("reading.resume"), systemImage: "arrow.down.to.line")
                        .font(.caption2.weight(.semibold))
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            if !model.systemAudioOnly {
                Button {
                    model.micMuted.toggle()
                } label: {
                    Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(model.micMuted ? .red : .secondary)
                .help(model.micMuted ? "내 마이크 음소거 해제 (⇧⌘M)" : "내 마이크 음소거 (⇧⌘M)")
            }

            Button {
                if model.listening { model.pauseListening() } else { Task { await model.start() } }
            } label: {
                Label(
                    model.finishingCapture ? model.t("action.finishingAudio") : model.starting ? model.t("action.preparingModel") : model.listening ? model.t("action.stopListening") : model.t("action.startListening"),
                    systemImage: model.listening ? "stop.fill" : "mic.fill"
                )
                .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(model.finishingCapture || model.starting || model.current == nil || model.current?.archivedAt != nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
    }
}
private func speakerColor(_ speaker: Int?) -> Color {
    guard let speaker else { return .gray }
    let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]
    return palette[max(0, speaker - 1) % palette.count]
}
private enum LiveColors {
    static let speech = Color(red: 0.08, green: 0.25, blue: 0.60)
    static let translation = Color(red: 0.02, green: 0.34, blue: 0.31)
    static let coach = Color(red: 0.36, green: 0.15, blue: 0.55)
}
private struct RecentCardStyle: ViewModifier {
    var color: Color
    var latest: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(latest ? Color.white : Color.primary)
            .background(color.opacity(latest ? 1 : 0.14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(latest ? 1 : 0.30), lineWidth: latest ? 2 : 1))
    }
}
struct AdviceCardBody: View {
    let advice: Advice
    let fontSize: Double
    var emphasized: Bool = false
    var inverted: Bool = false

    var body: some View {
        if let src = advice.sourceLanguageText, let dst = advice.targetLanguageText, !src.isEmpty, !dst.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(advice.sourceLanguageName ?? "STT", systemImage: "mic.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(inverted ? Color.white.opacity(0.18) : Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(inverted ? Color.white : Color.blue)
                    Text(src)
                        .font(.system(size: fontSize, weight: emphasized ? .medium : .regular))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                    .overlay(inverted ? Color.white.opacity(0.25) : Color.secondary.opacity(0.25))
                VStack(alignment: .leading, spacing: 4) {
                    Label(advice.targetLanguageName ?? "번역", systemImage: "character.bubble")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(inverted ? Color.white.opacity(0.18) : Color.purple.opacity(0.14), in: Capsule())
                        .foregroundStyle(inverted ? Color.white : Color.purple)
                    Text(dst)
                        .font(.system(size: fontSize, weight: emphasized ? .medium : .regular))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(advice.text)
                .font(.system(size: fontSize, weight: emphasized ? .medium : .regular))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CoachView: View {
    @ObservedObject var model: AppModel
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label(model.t("panel.coach"), systemImage: "sparkles").font(.headline)
                Text(model.coachLanguageSummary)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .lineLimit(1)
                Spacer(minLength: 4)
                PanelFontButton(title: "대화 코치", value: $model.panelTypography.advice, defaultValue: 18)
                if !model.followLive { Button(model.t("reading.resume")) { model.resumeReading() }.font(.caption) }
                if model.generating { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                Toggle("자동 답변 · 조언", isOn: $model.autoAdvice).font(.caption)
                Toggle("STT + 번역 동시 코칭", isOn: $model.bilingualCoach)
                    .font(.caption)
                    .help("STT 인식 언어와 번역 언어 두 가지로 답변과 조언을 함께 생성합니다.")
            }
            Toggle("전체 조언 기록", isOn: $showHistory).font(.caption)
            let showAll = showHistory || model.recentSeconds == 0
            TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
            let cutoff = activityReference(model, now: timeline.date).addingTimeInterval(-Double(model.recentSeconds))
            let adviceItems = (model.displayConversation?.advice ?? []).filter { item in showAll || item.date >= cutoff || model.displayConversation.map { ConversationLinks.spans(for: item, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 1).id("coach-top")
                    if model.followLive && !model.liveResponse.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("지금 생성 중").font(.caption).foregroundStyle(.secondary)
                            Text(model.liveResponse).font(.system(size: model.panelTypography.advice)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(14).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if adviceItems.isEmpty && (!model.followLive || model.liveResponse.isEmpty) {
                        ContentUnavailableView("다음 한마디를 함께", systemImage: "bubble.left.and.bubble.right", description: Text("대화를 시작하면 맥락에 맞는 질문과 표현을 제안합니다."))
                    }
                    ForEach(adviceItems.reversed()) { advice in
                        let latest = advice.id == adviceItems.last?.id
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(advice.date, format: .dateTime.hour().minute().second()).font(.caption2)
                                if latest { Spacer(); Text("최신 조언").font(.caption.bold()) }
                            }.foregroundStyle(latest ? Color.white.opacity(0.85) : Color.secondary)
                            if let conversation = model.displayConversation {
                                LinkBadge(model: model, spans: ConversationLinks.spans(for: advice, in: conversation), context: true)
                            }
                            AdviceCardBody(
                                advice: advice,
                                fontSize: model.panelTypography.advice + (advice.id == adviceItems.last?.id ? 1 : 0),
                                emphasized: advice.id == adviceItems.last?.id,
                                inverted: latest
                            )
                        }.padding(14).modifier(RecentCardStyle(color: LiveColors.coach, latest: latest))
                        .id(advice.id)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: model.displayConversation.map { ConversationLinks.spans(for: advice, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true ? 3 : 0))
                    }
                }
            }
            .readingScrollControl(model)
            .onChange(of: model.selectedLiveBlockID) { _, selected in
                if let selected, let conversation = model.displayConversation,
                   let advice = adviceItems.last(where: { ConversationLinks.spans(for: $0, in: conversation).contains { $0.id == selected } }) { proxy.scrollTo(advice.id, anchor: .center) }
            }
            .onChange(of: model.displayConversation?.advice.count) { _, _ in if model.followLive { proxy.scrollTo("coach-top", anchor: .top) } }
            .onChange(of: model.followLive) { _, follow in if follow { proxy.scrollTo("coach-top", anchor: .top) } }
            .onAppear { if model.followLive { proxy.scrollTo("coach-top", anchor: .top) } }
            }
            }
            Button { Task { await model.advise() } } label: { Label("지금 조언 받기  ⌘↵", systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(model.generating || (model.displayConversation?.transcript.isEmpty ?? true))
        }
    }
}

struct TranslationView: View {
    @ObservedObject var model: AppModel
    @AppStorage("pinLatestSpotlight") private var pinLatestSpotlight = true
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("\(model.targetLanguageName) \(model.t("panel.translation"))", systemImage: "character.bubble").font(.headline)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Button {
                        model.selectTargetLanguage("ko-KR")
                    } label: {
                        Text("한국어")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(model.targetLanguage == "ko-KR" ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.selectTargetLanguage("en-US")
                    } label: {
                        Text("EN")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(model.targetLanguage == "en-US" ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        ForEach(LanguageCatalog.all) { lang in
                            Button {
                                model.selectTargetLanguage(lang.code)
                            } label: {
                                if model.targetLanguage == lang.code {
                                    Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                } else {
                                    Text(lang.displayName(in: model.uiLanguage))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(model.t("settings.targetLanguage"))
                }
                PanelFontButton(title: "번역", value: $model.panelTypography.translation, defaultValue: 19)
                if model.translating { ProgressView().controlSize(.small) }
            }
            Text(model.translationEngineDescription).font(.caption).foregroundStyle(.secondary)
            Text(model.simpleFastMode ? "심플 패스트 · 한 문장씩 모아서 즉시 번역" : "한 문장씩 모아서 번역 · 잠시 멈추면 잔여 발화 처리").font(.caption2).foregroundStyle(.secondary)
            Text(model.translationStatus).font(.caption2).foregroundStyle(.secondary)
            if let error = model.translationError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { pinLatestSpotlight.toggle() }
                } label: {
                    Label("최근 고정", systemImage: pinLatestSpotlight ? "pin.fill" : "pin")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(pinLatestSpotlight ? Color.purple.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
                        .foregroundStyle(pinLatestSpotlight ? Color.purple : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("최신 번역을 상단에 고정해 스크롤 없이 편안하게 봅니다")
                Toggle("전체 번역 기록", isOn: $showHistory).font(.caption)
            }
            let showAll = showHistory || model.recentSeconds == 0
            TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
            let cutoff = activityReference(model, now: timeline.date).addingTimeInterval(-Double(model.recentSeconds))
            let entries = (model.displayConversation?.translations ?? []).filter { item in showAll || (RecentActivity.sourceDate(for: item, spans: model.displayConversation?.transcriptSpans ?? []) ?? .distantPast) >= cutoff || model.displayConversation.map { ConversationLinks.spans(for: item, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true }
            let pinnedEntry: TranslationEntry? = pinLatestSpotlight ? entries.last : nil
            let historyEntries: [TranslationEntry] = pinLatestSpotlight ? Array(entries.dropLast().reversed()) : entries
            VStack(alignment: .leading, spacing: 8) {
                if pinLatestSpotlight {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Label("최신 번역 고정", systemImage: "pin.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(.purple)
                            Spacer()
                            if !historyEntries.isEmpty {
                                Text("이전 \(historyEntries.count)건")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.followLive && !model.translationSource.isEmpty {
                            translationPair(source: model.translationSource, translated: model.liveTranslation.isEmpty ? "번역 중…" : model.liveTranslation, latest: true)
                        } else if model.followLive, let preview = model.translationPreview {
                            translationPair(source: preview.source, translated: preview.translated, latest: true)
                        } else if let pinnedEntry {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if let conversation = model.displayConversation { LinkBadge(model: model, spans: ConversationLinks.spans(for: pinnedEntry, in: conversation)) }
                                    if let date = RecentActivity.sourceDate(for: pinnedEntry, spans: model.displayConversation?.transcriptSpans ?? []) {
                                        Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                translationPair(source: pinnedEntry.source, translated: pinnedEntry.translated, latest: true)
                            }
                        } else {
                            Text("대화를 시작하면 최신 \(model.targetLanguageName) 번역이 스크롤 없이 이 자리에 고정 표시됩니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                .padding(10)
                                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    if !historyEntries.isEmpty {
                        HStack(spacing: 6) {
                            Text("이전 번역 기록")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
                        }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(historyEntries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let date = RecentActivity.sourceDate(for: entry, spans: model.displayConversation?.transcriptSpans ?? []) { Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary) }
                                    if let conversation = model.displayConversation { LinkBadge(model: model, spans: ConversationLinks.spans(for: entry, in: conversation)) }
                                    translationPair(source: entry.source, translated: entry.translated, latest: !pinLatestSpotlight && entry.id == entries.last?.id)
                                }
                                .id(entry.id)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: model.displayConversation.map { ConversationLinks.spans(for: entry, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true ? 3 : 0))
                            }
                            if !pinLatestSpotlight {
                                if model.followLive, let preview = model.translationPreview {
                                    translationPair(source: preview.source, translated: preview.translated)
                                }
                                if model.followLive && !model.translationSource.isEmpty {
                                    translationPair(source: model.translationSource, translated: model.liveTranslation.isEmpty ? "번역 중…" : model.liveTranslation)
                                }
                                if entries.isEmpty && !model.translating && model.translationPreview == nil {
                                    Text("대화의 \(model.targetLanguageName) 번역이 여기에 표시됩니다.").foregroundStyle(.secondary).padding(.top, 20)
                                }
                            }
                            Color.clear.frame(height: 1).id("translation-end")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .readingScrollControl(model)
                    .onChange(of: model.selectedLiveBlockID) { _, selected in
                        if let selected, let conversation = model.displayConversation,
                           let entry = historyEntries.first(where: { ConversationLinks.spans(for: $0, in: conversation).contains { $0.id == selected } }) { proxy.scrollTo(entry.id, anchor: .center) }
                    }
                    .onChange(of: model.liveTranslation) { _, _ in if !pinLatestSpotlight && model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                    .onChange(of: model.displayConversation?.translations?.count) { _, _ in if !pinLatestSpotlight && model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                    .onChange(of: model.translationSource) { _, _ in if !pinLatestSpotlight && model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                    .onChange(of: model.followLive) { _, follow in if !pinLatestSpotlight && follow { proxy.scrollTo("translation-end", anchor: .bottom) } }
                    .onAppear { if !pinLatestSpotlight && model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                }
            }
            }
            HStack {
                Button(model.translationError == nil ? "번역 갱신" : "번역 다시 시도") { model.translateLatest() }.disabled(model.translating)
                if model.settings.translation == .apple { Button(model.preparingTranslation ? "언어 준비 중…" : "번역 언어 준비") { model.prepareTranslationLanguages() }.disabled(model.preparingTranslation || model.sourceLanguageSpec?.translationCode == model.targetLanguageSpec.translationCode) }
            }
            if let ms = model.translationLatency { Text("최근 번역 처리: \(ms)ms").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func translationPair(source: String, translated: String, latest: Bool = true) -> some View {
        let sourceTag = TranslationPolicy.sourceTag(of: source)
        let isMic = sourceTag == "마이크"
        let displaySource = sourceTag == nil ? source : TranslationPolicy.displayText(strippingSourceTag: source)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if sourceTag != nil {
                    Label(isMic ? "내 목소리" : "Mac 소리", systemImage: isMic ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(latest ? Color.white.opacity(0.20) : (isMic ? Color.teal : Color.blue).opacity(0.15), in: Capsule())
                        .foregroundStyle(latest ? Color.white : (isMic ? Color.teal : Color.blue))
                }
                if latest { Text("최신 번역").font(.caption.bold()) }
            }
            Text(displaySource).font(.caption).foregroundStyle(latest ? Color.white.opacity(0.85) : Color.secondary).textSelection(.enabled)
            Text(translated).font(.system(size: model.panelTypography.translation, weight: .medium)).lineSpacing(5).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .modifier(RecentCardStyle(color: isMic ? Color.teal : LiveColors.translation, latest: latest))
    }
}

struct SummaryPanel: View {
    @ObservedObject var model: AppModel
    @State private var scope = "all"
    @State private var selectedWindow: RecentSummaryWindow = .min5
    @State private var showingHistory = false
    @State private var copiedSummaryKey: String? = nil
    var body: some View {
        let activeLanguages = model.resolvedSummaryLanguages(for: model.displayConversation?.transcript)
        let isBusy = model.summarizing || model.summarizingWindow != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(model.t("panel.summary"), systemImage: "list.bullet.rectangle").font(.headline)
                Menu {
                    Section("기본 요약 언어") {
                        Button {
                            model.updateSummaryLanguages { $0.includeTranslationLanguage.toggle() }
                        } label: {
                            Label("번역 언어 (\(model.targetLanguageName))", systemImage: model.summaryLanguages.includeTranslationLanguage ? "checkmark" : "circle")
                        }
                        Button {
                            model.updateSummaryLanguages { $0.includeSTTLanguage.toggle() }
                        } label: {
                            Label("STT 언어 (\(model.sttLanguageBadge))", systemImage: model.summaryLanguages.includeSTTLanguage ? "checkmark" : "circle")
                        }
                    }
                    Divider()
                    Section("추가 요약 언어 (복수 선택)") {
                        ForEach(LanguageCatalog.all) { lang in
                            let selected = model.summaryLanguages.extraLanguageCodes.contains(lang.code)
                            Button {
                                model.updateSummaryLanguages { $0.toggleExtra(lang.code) }
                            } label: {
                                if selected {
                                    Label(lang.displayName(in: model.uiLanguage), systemImage: "checkmark")
                                } else {
                                    Text(lang.displayName(in: model.uiLanguage))
                                }
                            }
                        }
                    }
                    if !model.summaryLanguages.extraLanguageCodes.isEmpty {
                        Divider()
                        Button("추가 언어 모두 해제") {
                            model.updateSummaryLanguages { $0.extraLanguageCodes = [] }
                        }
                    }
                } label: {
                    Label(model.summaryLanguageBadge, systemImage: "globe")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("요약 생성 언어 선택 (STT + 번역 + 추가 복수 언어)")
                Spacer(minLength: 4)
                PanelFontButton(title: "대화 요약", value: $model.panelTypography.summary, defaultValue: 16)
                if isBusy { ProgressView().controlSize(.small) }
                Button(model.t("summary.history")) { showingHistory = true }.controlSize(.small)
                Button(model.t("summary.refresh")) {
                    if scope == "recent" {
                        Task { await model.summarizeRecent(window: selectedWindow, force: true) }
                    } else {
                        Task { await model.refreshSummaries() }
                    }
                }.controlSize(.small).disabled(isBusy)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.panelLayout.setVisible(.summary, false) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("대화 요약 패널 숨기기")
            }
            HStack(spacing: 8) {
                Picker("요약 범위", selection: $scope) {
                    Text(model.t("summary.all")).tag("all")
                    Text("구간별").tag("recent")
                    Text(model.t("summary.speakers")).tag("speakers")
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
                Text(scope == "recent" ? "\(selectedWindow.title) 정리" : "12초 간격 갱신")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Text("최근")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    ForEach(RecentSummaryWindow.allCases) { window in
                        let isSelected = scope == "recent" && selectedWindow == window
                        let isLoading = model.summarizingWindow == window
                        let hasCached = !(model.displayConversation?.summaries?[window.summaryKey]?.text.isEmpty ?? true)
                        Button {
                            selectedWindow = window
                            scope = "recent"
                            Task { await model.summarizeRecent(window: window) }
                        } label: {
                            HStack(spacing: 3) {
                                if isLoading {
                                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                                } else if hasCached && !isSelected {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 5)
                                }
                                Text(window.shortLabel)
                                    .font(.caption2.weight(isSelected ? .bold : .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                isSelected
                                    ? Color.accentColor
                                    : (hasCached ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10)),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.white : (hasCached ? Color.accentColor : Color.primary))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.current?.archivedAt != nil)
                        .help("\(window.title) 대화를 요약 정리합니다")
                    }
                }
                .padding(.vertical, 1)
            }
            if let error = model.summaryError { Text(error).font(.caption).foregroundStyle(.orange) }
            if scope == "recent", let notice = model.recentSummaryNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                if scope == "all" {
                    if let summary = model.displayConversation?.summaries?["all"] {
                        summaryCard(key: "all", label: "전체 대화", summary: summary, languages: activeLanguages, color: .accentColor)
                    } else {
                        Text("대화가 쌓이면 핵심 내용·결정 사항·할 일·미해결 질문을 선택한 언어로 정리합니다.").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                    }
                } else if scope == "recent" {
                    recentSummaryBody(activeLanguages: activeLanguages)
                } else {
                    let speakers = Array(Set((model.displayConversation?.turns ?? []).compactMap(\.speaker))).sorted()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(speakers, id: \.self) { speaker in
                            if let summary = model.displayConversation?.summaries?["speaker-\(speaker)"] {
                                summaryCard(key: "speaker-\(speaker)", label: "화자 \(speaker) · 추정", summary: summary, languages: activeLanguages, color: speakerColor(speaker))
                            } else { Text("화자 \(speaker) · 요약 대기 중").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        if speakers.isEmpty { Text("화자가 구분되면 화자별로 발언을 정리합니다.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !model.simpleFastMode && model.showTranslationKeywords {
                TranslationKeywordsView(model: model, resizeHandleOnTop: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingHistory) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("전체 요약 이력").font(.title2.bold()); Spacer(); Button("닫기") { showingHistory = false } }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if (model.displayConversation?.summaryHistory ?? []).isEmpty {
                            Text("앞으로 요약을 갱신할 때마다 이전 내용을 보관합니다.").foregroundStyle(.secondary)
                        }
                        ForEach((model.displayConversation?.summaryHistory ?? []).reversed()) { snapshot in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(snapshot.date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                                Text(snapshot.title).font(.headline)
                                Text(snapshot.text).font(.system(size: model.panelTypography.summary)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }.padding(24).frame(width: 640, height: 600)
        }
    }
    @ViewBuilder
    private func recentSummaryBody(activeLanguages: [SupportedLanguage]) -> some View {
        let conversation = model.displayConversation
        let slice = conversation.map {
            SummaryPolicy.recentTranscript(for: $0, window: selectedWindow, referenceDate: Date(), isListening: model.listening)
        }
        let summary = conversation?.summaries?[selectedWindow.summaryKey]
        let isStale = slice.map { !$0.text.isEmpty && summary != nil && summary?.coveredSource != $0.text } ?? false

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let slice, !slice.text.isEmpty {
                    let timeRange = "\(slice.cutoff.formatted(.dateTime.hour().minute()))–\(slice.reference.formatted(.dateTime.hour().minute()))"
                    let basis = slice.usedFallbackFullTranscript
                        ? "전체 기록 기준"
                        : (slice.anchoredToLastActivity ? "대화 마지막 \(selectedWindow.shortLabel) · \(timeRange)" : "현재 기준 \(timeRange)")
                    Text("\(basis) · 발언 \(slice.spanCount)건")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(selectedWindow.title) 구간")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isStale {
                    Text("새 발언 있음")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Task { await model.summarizeRecent(window: selectedWindow, force: true) }
                } label: {
                    Label(summary == nil ? "요약 정리" : "다시 정리", systemImage: "sparkles")
                }
                .controlSize(.mini)
                .disabled(model.summarizingWindow != nil || (slice?.text.isEmpty ?? true) || model.current?.archivedAt != nil)
            }

            if let summary, !summary.text.isEmpty {
                summaryCard(
                    key: selectedWindow.summaryKey,
                    label: "\(selectedWindow.title) 요약 정리",
                    summary: summary,
                    languages: activeLanguages,
                    color: .teal
                )
            } else if model.summarizingWindow == selectedWindow {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(selectedWindow.title) 대화를 요약 정리하는 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            } else if let slice, !slice.text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selectedWindow.title) 동안 발언 \(slice.spanCount)건이 있습니다. 위 시간 버튼 또는 ‘요약 정리’를 누르면 핵심 내용을 정리합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(selectedWindow.title) 동안 기록된 발언이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let conversation, !conversation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let wider = RecentSummaryWindow.allCases.filter { $0.minutes > selectedWindow.minutes }
                        if !wider.isEmpty {
                            HStack(spacing: 6) {
                                Text("더 넓은 구간:").font(.caption2).foregroundStyle(.secondary)
                                ForEach(wider) { next in
                                    Button(next.shortLabel) {
                                        selectedWindow = next
                                        Task { await model.summarizeRecent(window: next) }
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
    private func summaryCard(key: String, label: String, summary: SummaryState, languages: [SupportedLanguage], color: Color) -> some View {
        let localizedMap = summary.localizedTexts ?? [:]
        let primaryCode = summary.primaryLanguageCode ?? languages.first?.code ?? model.targetLanguageSpec.code
        let renderedLanguages: [(lang: SupportedLanguage, text: String?)] = languages.map { lang in
            if let text = localizedMap[lang.code], !text.isEmpty {
                return (lang, text)
            }
            if lang.code == primaryCode {
                return (lang, summary.text)
            }
            return (lang, nil)
        }
        let copyText: String = {
            let filled = renderedLanguages.compactMap { pair -> String? in
                guard let text = pair.text, !text.isEmpty else { return nil }
                return renderedLanguages.count > 1 ? "[\(pair.lang.displayName(in: model.uiLanguage))]\n\(text)" : text
            }
            return filled.isEmpty ? summary.text : filled.joined(separator: "\n\n")
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(.caption.bold()).foregroundStyle(color)
                Spacer()
                Text(summary.updatedAt, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                    copiedSummaryKey = key
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if copiedSummaryKey == key { copiedSummaryKey = nil }
                    }
                } label: {
                    Image(systemName: copiedSummaryKey == key ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedSummaryKey == key ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("요약 복사")
            }
            if renderedLanguages.count <= 1 {
                Text(renderedLanguages.first?.text ?? summary.text)
                    .font(.system(size: model.panelTypography.summary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(renderedLanguages.enumerated()), id: \.element.lang.code) { idx, pair in
                    if idx > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.lang.displayName(in: model.uiLanguage))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color.opacity(0.14), in: Capsule())
                            .foregroundStyle(color)
                        if let text = pair.text, !text.isEmpty {
                            Text(text)
                                .font(.system(size: model.panelTypography.summary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text((model.summarizing || model.summarizingWindow != nil) ? "요약 생성 중…" : "‘갱신’을 누르면 이 언어로 요약을 생성합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(12).background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct STTPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage("pinLatestSpotlight") private var pinLatestSpotlight = true
    @State private var showingAppearance = false
    @State private var showHistory = false
    @State private var showSpeakers = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let showAll = showHistory || model.recentSeconds == 0
            HStack(spacing: 6) {
                Button { showingAppearance = true } label: { Label("표시 설정", systemImage: "textformat.size") }
                    .popover(isPresented: $showingAppearance) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text("STT 보기 스타일").font(.headline); Spacer(); Button("완료") { showingAppearance = false } }
                            STTAppearanceControls(model: model)
                        }.padding(20).frame(width: 360).foregroundStyle(Color.primary)
                    }
                Button("A−") {
                    model.sttAppearance.fontSize = max(STTAppearance.minFontSize, model.sttAppearance.fontSize - 1)
                }
                .controlSize(.small)
                .disabled(model.sttAppearance.fontSize <= STTAppearance.minFontSize)
                .help("STT 글자 작게 (최소 \(Int(STTAppearance.minFontSize))pt)")
                Button("A+") {
                    model.sttAppearance.fontSize = min(STTAppearance.maxFontSize, model.sttAppearance.fontSize + 1)
                }
                .controlSize(.small)
                .disabled(model.sttAppearance.fontSize >= STTAppearance.maxFontSize)
                .help("STT 글자 크게")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { pinLatestSpotlight.toggle() }
                } label: {
                    Label("최근 고정", systemImage: pinLatestSpotlight ? "pin.fill" : "pin")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(pinLatestSpotlight ? model.sttAppearance.latestBackground.color.opacity(0.85) : model.sttAppearance.text.color.opacity(0.12), in: Capsule())
                        .foregroundStyle(pinLatestSpotlight ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                }
                .buttonStyle(.plain)
                .help("최신 STT 원문을 상단에 고정해 스크롤 없이 편안하게 봅니다")
                Toggle("화자별", isOn: $showSpeakers).font(.caption).disabled(!showAll)
                Toggle("전체 기록", isOn: $showHistory).font(.caption)
            }
            if !model.followLive && model.listening {
                Button { model.resumeReading() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.circle.fill")
                        Text(model.hasUnreadLiveChanges ? "읽기 고정 중 · 백그라운드에서 새 STT 수신 중 (눌러서 최신 보기)" : "읽기 고정 중 (눌러서 실시간 따라가기)")
                            .lineLimit(1)
                        Spacer()
                        Text("최신으로").bold()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.white)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
                let reference = activityReference(model, now: timeline.date)
                let spans = (model.displayConversation?.transcriptSpans ?? []).filter { showAll || $0.date >= reference.addingTimeInterval(-Double(model.recentSeconds)) || $0.id == model.selectedLiveBlockID }
                let usePinnedSTT = pinLatestSpotlight && !(showSpeakers && showAll)
                let pinnedSpan: TranscriptSpan? = usePinnedSTT ? spans.last : nil
                let historySpans: [TranscriptSpan] = usePinnedSTT ? Array(spans.dropLast().reversed()) : spans

                VStack(alignment: .leading, spacing: 8) {
                    if usePinnedSTT {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Label("최신 원문 고정", systemImage: "pin.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(model.sttAppearance.latestText.color.opacity(0.9))
                                Spacer()
                                if !historySpans.isEmpty {
                                    Text("이전 \(historySpans.count)건")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(model.sttAppearance.text.color.opacity(0.7))
                                }
                            }
                            LiveSTTCaptionRow(
                                liveSTT: model.liveSTT,
                                appearance: model.sttAppearance,
                                followLive: model.followLive,
                                compact: true
                            )
                            if let pinnedSpan {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        LinkBadge(model: model, spans: [pinnedSpan])
                                        Text(pinnedSpan.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(model.sttAppearance.latestText.color.opacity(0.8))
                                        Text("최신 발언").font(.caption.bold()).foregroundStyle(model.sttAppearance.latestText.color)
                                    }
                                    Text(pinnedSpan.text).font(.system(size: model.sttAppearance.latestFontSize, weight: .semibold))
                                        .lineSpacing(model.sttAppearance.fontSize <= 13 ? 3 : 5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .foregroundStyle(model.sttAppearance.latestText.color)
                                .background(model.sttAppearance.latestBackground.color, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.sttAppearance.latestBackground.color, lineWidth: 2))
                            } else if model.displayConversation?.transcript.isEmpty != false {
                                Text("대화를 시작하면 최근 발언이 스크롤 없이 이 자리에 고정 표시됩니다.")
                                    .font(.caption)
                                    .foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                    .padding(10)
                                    .background(model.sttAppearance.text.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if !historySpans.isEmpty {
                            HStack(spacing: 6) {
                                Text("이전 발언 기록")
                                    .font(.caption2.bold())
                                    .foregroundStyle(model.sttAppearance.text.color.opacity(0.7))
                                Rectangle().fill(model.sttAppearance.text.color.opacity(0.18)).frame(height: 1)
                            }
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if showSpeakers, showAll, let turns = model.displayConversation?.turns, !turns.isEmpty {
                                    ForEach(turns) { turn in
                                        Text("\(turn.label)\n\(turn.text)").font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                } else if !historySpans.isEmpty {
                                    if !usePinnedSTT, showAll, let first = model.displayConversation?.transcriptSpans?.first, first.start > 0 {
                                        Text("기존 기록 · 발언 시각 정보 없음").font(.caption).foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                        Text(String((model.displayConversation?.transcript ?? "").prefix(first.start))).font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled)
                                    }
                                    ForEach(historySpans) { span in
                                        let latest = !usePinnedSTT && span.id == spans.last?.id
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                LinkBadge(model: model, spans: [span])
                                                Text(span.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle((latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color).opacity(0.8))
                                                if latest { Text("최신 발언").font(.caption.bold()).foregroundStyle(model.sttAppearance.latestText.color) }
                                            }
                                            Text(span.text).font(.system(size: latest ? model.sttAppearance.latestFontSize : model.sttAppearance.fontSize, weight: latest ? .semibold : .regular))
                                                .lineSpacing(model.sttAppearance.fontSize <= 13 ? 3 : 5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.padding(12)
                                            .id(span.id)
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: model.selectedLiveBlockID == span.id ? 3 : 0))
                                            .foregroundStyle(latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                                            .background(latest ? model.sttAppearance.latestBackground.color : model.sttAppearance.text.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.sttAppearance.latestBackground.color.opacity(latest ? 1 : 0.35), lineWidth: latest ? 2 : 1))
                                    }
                                    if usePinnedSTT, showAll, let first = model.displayConversation?.transcriptSpans?.first, first.start > 0 {
                                        Text("기존 기록 · 발언 시각 정보 없음").font(.caption).foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                        Text(String((model.displayConversation?.transcript ?? "").prefix(first.start))).font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled)
                                    }
                                } else if !usePinnedSTT && (showAll || !(model.displayConversation?.transcriptSpans?.isEmpty == false)) {
                                    Text(model.displayConversation?.transcript.isEmpty == false ? model.displayConversation!.transcript : "대화를 시작하면 최근 발언이 여기에 표시됩니다.")
                                        .font(.system(size: model.sttAppearance.fontSize)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    if model.displayConversation?.transcript.isEmpty == false { Text("기존 기록 · 발언 시각 정보 없음").font(.caption).foregroundStyle(model.sttAppearance.text.color.opacity(0.75)) }
                                } else if !usePinnedSTT {
                                    Text("최근 \(model.recentSeconds / 60)분 동안 새 발언이 없습니다.").foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                }
                                if !usePinnedSTT {
                                    LiveSTTCaptionRow(
                                        liveSTT: model.liveSTT,
                                        appearance: model.sttAppearance,
                                        followLive: model.followLive,
                                        compact: true
                                    ) {
                                        proxy.scrollTo("stt-bottom", anchor: .bottom)
                                    }
                                    .id("stt-live-interim")
                                }
                                Color.clear.frame(height: 1).id("stt-bottom")
                            }.padding(4)
                        }
                        .readingScrollControl(model)
                        .onChange(of: model.selectedLiveBlockID) { _, selected in if let selected { proxy.scrollTo(selected, anchor: .center) } }
                        .onChange(of: model.displayConversation?.transcript) { _, _ in if !usePinnedSTT && model.followLive { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                        .onChange(of: model.followLive) { _, follow in if !usePinnedSTT && follow { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                        .onChange(of: model.selectedID) { _, _ in if !usePinnedSTT { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                        .onAppear { if !usePinnedSTT && model.followLive { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                    }
                }
            }
            if !model.listening && !model.starting && model.displayConversation?.archivedAt == nil {
                DisclosureGroup("대화 텍스트 입력 / 수정") {
                    TextEditor(text: Binding(get: { model.displayConversation?.transcript ?? "" }, set: model.updateText)).font(.system(size: model.sttAppearance.fontSize)).frame(height: 70).disabled(!model.followLive)
                }.font(.caption)
            }
        }
        .padding(12)
        .foregroundStyle(model.sttAppearance.text.color)
        .background(model.sttAppearance.background.color, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct LiveActivitySchedule: TimelineSchedule {
    let active: Bool
    func entries(from startDate: Date, mode: Mode) -> Entries { Entries(start: startDate, active: active) }
    struct Entries: Sequence, IteratorProtocol {
        private var nextDate: Date?
        private let active: Bool
        init(start: Date, active: Bool) { self.nextDate = start; self.active = active }
        mutating func next() -> Date? {
            guard let current = nextDate else { return nil }
            nextDate = active ? current.addingTimeInterval(1) : nil
            return current
        }
    }
}

@MainActor func activityReference(_ model: AppModel, now: Date) -> Date {
    if !model.followLive, let frozen = model.readingState.referenceDate { return frozen }
    if model.listening { return now }
    let dates = (model.displayConversation?.transcriptSpans ?? []).map(\.date) + (model.displayConversation?.advice ?? []).map(\.date) + (model.displayConversation?.translations ?? []).compactMap(\.date)
    return dates.max() ?? now
}

