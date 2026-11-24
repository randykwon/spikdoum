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
                Button(model.t("action.getAdviceNow")) { Task { await model.advise() } }.keyboardShortcut(.return, modifiers: [.command])
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
        }.defaultSize(width: 400, height: 300)
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
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 16) {
                Text("SpikDoum").font(.title2.bold())
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
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
                        .labelStyle(.iconOnly).help(model.t("settings.title")).disabled(model.listening || model.starting)
                    Button { showSummaryScriptPanel.toggle() } label: {
                        Label(model.t("panel.summaryScriptToggle"), systemImage: showSummaryScriptPanel ? "sidebar.right" : "sidebar.squares.right")
                    }.labelStyle(.iconOnly).help(model.t("panel.summaryScriptToggle"))
                    Menu {
                        Toggle(model.t("panel.summaryScriptToggle"), isOn: $showSummaryScriptPanel)
                        Button(columnVisibility == .detailOnly ? model.t("panel.toggleSidebarShow") : model.t("panel.toggleSidebarHide")) { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                        Button(model.t("panel.coachWindow")) { openWindow(id: "coach") }
                    } label: { Label("보기", systemImage: "rectangle.3.group") }.labelStyle(.iconOnly)
                    Button {
                        if model.listening { model.pauseListening() } else { Task { await model.start() } }
                    } label: { Label(model.finishingCapture ? model.t("action.finishingAudio") : model.starting ? (model.settings.stt == .managed || model.settings.translation == .managed ? model.t("action.preparingModel") : model.t("action.checkingPermissions")) : model.listening ? model.t("action.stopListening") : model.t("action.startListening"), systemImage: model.listening ? "stop.fill" : "mic.fill") }
                        .buttonStyle(.borderedProminent).disabled(model.finishingCapture || model.starting || model.current == nil || model.current?.archivedAt != nil)
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
                if model.settings.llm == .apple, let status = model.modelStatus {
                    DisclosureGroup("Apple Intelligence 안내") {
                        Text(status).foregroundStyle(.orange)
                    }.font(.caption)
                }
                HStack(spacing: 12) {
                    Label(model.t("live.header"), systemImage: "waveform.circle.fill").font(.headline).foregroundStyle(.blue)
                    Picker("범위", selection: $model.recentSeconds) {
                        Text(model.t("range.all")).tag(0)
                        Text(model.t("range.2min")).tag(120)
                        Text(model.t("range.1min")).tag(60)
                    }
                        .labelsHidden().frame(width: 120)
                    Picker("보기", selection: $linkedConversationView) { Text(model.t("view.linked")).tag(true); Text(model.t("view.3panel")).tag(false) }
                        .labelsHidden().frame(width: 110)
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
                        }
                    } label: {
                        Label("STT: \(model.sttLanguageBadge)", systemImage: model.isAutoDetectLanguage ? "sparkles" : "mic")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.starting)
                    .help(model.t("settings.sourceLanguage"))
                    Menu {
                        Section(model.t("settings.targetLanguage")) {
                            ForEach(LanguageCatalog.all) { lang in
                                Button {
                                    model.targetLanguage = lang.code
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
                    Spacer()
                    if !model.followLive {
                        Text(model.hasUnreadLiveChanges ? model.t("reading.pausedReceiving") : model.t("reading.paused")).font(.caption.bold()).foregroundStyle(.orange)
                    }
                    Button {
                        if model.followLive { model.pauseReading() } else { model.resumeReading() }
                    } label: { Label(model.followLive ? model.t("reading.pause") : model.t("reading.resume"), systemImage: model.followLive ? "pause.circle" : "arrow.down.to.line") }
                }.controlSize(.small)
                if linkedConversationView {
                    HSplitView {
                        LinkedConversationView(model: model).frame(minWidth: 540, minHeight: 300)
                        if showSummaryScriptPanel {
                            SummaryScriptPanel(model: model).frame(minWidth: 300, idealWidth: 380).padding(.leading, 12)
                        }
                    }.frame(minHeight: 300)
                } else {
                    HSplitView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Label(model.listening ? model.t("panel.sttLive") : model.t("panel.stt"), systemImage: "mic.fill").font(.title3.bold()).foregroundStyle(.blue)
                                Spacer(minLength: 4)
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
                        }.frame(minWidth: 220).padding(.trailing, 10)
                        TranslationView(model: model).frame(minWidth: 220).padding(.horizontal, 10)
                        CoachView(model: model).frame(minWidth: 220).padding(.horizontal, 10)
                        if showSummaryScriptPanel {
                            SummaryScriptPanel(model: model).frame(minWidth: 280, idealWidth: 360).padding(.leading, 10)
                        }
                    }.frame(minHeight: 260)
                }
            }.padding(14)
                .background(ReadingSpaceShortcut(enabled: !showingModels && !showingSettings && !showingCaptureSettings && !showingPanelFonts && pendingDeletion.isEmpty && model.replayTarget == nil) {
                    if model.followLive { model.pauseReading() } else { model.resumeReading() }
                }.allowsHitTesting(false))
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
struct CoachView: View {
    @ObservedObject var model: AppModel
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(model.t("panel.coach"), systemImage: "sparkles").font(.headline); Spacer(); if !model.followLive { Button(model.t("reading.resume")) { model.resumeReading() }.font(.caption) }; if model.generating { ProgressView().controlSize(.small) } }
            Toggle("자동 답변 · 조언", isOn: $model.autoAdvice).font(.caption)
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
                            Text(advice.text).font(.system(size: model.panelTypography.advice + (advice.id == adviceItems.last?.id ? 1 : 0), weight: advice.id == adviceItems.last?.id ? .medium : .regular)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(model.targetLanguageName) \(model.t("panel.translation"))", systemImage: "character.bubble").font(.headline)
                Spacer()
                if model.translating { ProgressView().controlSize(.small) }
            }
            if model.showTranslationKeywords { TranslationKeywordsView(model: model) }
            Text(model.translationEngineDescription).font(.caption).foregroundStyle(.secondary)
            Text("2~3문장씩 묶어 번역 · 잠시 멈추면 잔여 문장 처리").font(.caption2).foregroundStyle(.secondary)
            Text(model.translationStatus).font(.caption2).foregroundStyle(.secondary)
            if let error = model.translationError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Toggle("전체 번역 기록", isOn: $showHistory).font(.caption)
            let showAll = showHistory || model.recentSeconds == 0
            TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
            let cutoff = activityReference(model, now: timeline.date).addingTimeInterval(-Double(model.recentSeconds))
            let entries = (model.displayConversation?.translations ?? []).filter { item in showAll || (RecentActivity.sourceDate(for: item, spans: model.displayConversation?.transcriptSpans ?? []) ?? .distantPast) >= cutoff || model.displayConversation.map { ConversationLinks.spans(for: item, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if let date = RecentActivity.sourceDate(for: entry, spans: model.displayConversation?.transcriptSpans ?? []) { Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary) }
                                if let conversation = model.displayConversation { LinkBadge(model: model, spans: ConversationLinks.spans(for: entry, in: conversation)) }
                                translationPair(source: entry.source, translated: entry.translated, latest: entry.id == entries.last?.id)
                            }
                            .id(entry.id)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: model.displayConversation.map { ConversationLinks.spans(for: entry, in: $0).contains { $0.id == model.selectedLiveBlockID } } == true ? 3 : 0))
                        }
                        if model.followLive, let preview = model.translationPreview {
                            translationPair(source: preview.source, translated: preview.translated)
                        }
                        if model.followLive && !model.translationSource.isEmpty {
                            translationPair(source: model.translationSource, translated: model.liveTranslation.isEmpty ? "번역 중…" : model.liveTranslation)
                        }
                        if entries.isEmpty && !model.translating && model.translationPreview == nil {
                            Text("대화의 한국어 번역이 여기에 표시됩니다.").foregroundStyle(.secondary).padding(.top, 20)
                        }
                        Color.clear.frame(height: 1).id("translation-end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .readingScrollControl(model)
                .onChange(of: model.selectedLiveBlockID) { _, selected in
                    if let selected, let conversation = model.displayConversation,
                       let entry = entries.first(where: { ConversationLinks.spans(for: $0, in: conversation).contains { $0.id == selected } }) { proxy.scrollTo(entry.id, anchor: .center) }
                }
                .onChange(of: model.liveTranslation) { _, _ in if model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                .onChange(of: model.displayConversation?.translations?.count) { _, _ in if model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                .onChange(of: model.translationSource) { _, _ in if model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
                .onChange(of: model.followLive) { _, follow in if follow { proxy.scrollTo("translation-end", anchor: .bottom) } }
                .onAppear { if model.followLive { proxy.scrollTo("translation-end", anchor: .bottom) } }
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
        VStack(alignment: .leading, spacing: 8) {
            if latest { Text("최신 번역").font(.caption.bold()) }
            Text(source).font(.caption).foregroundStyle(latest ? Color.white.opacity(0.85) : Color.secondary).textSelection(.enabled)
            Text(translated).font(.system(size: model.panelTypography.translation, weight: .medium)).lineSpacing(5).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .modifier(RecentCardStyle(color: LiveColors.translation, latest: latest))
    }
}

struct SummaryPanel: View {
    @ObservedObject var model: AppModel
    @State private var scope = "all"
    @State private var showingHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(model.t("panel.summary"), systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                if model.summarizing { ProgressView().controlSize(.small) }
                Button(model.t("summary.history")) { showingHistory = true }.controlSize(.small)
                Button(model.t("summary.refresh")) { Task { await model.refreshSummaries() } }.controlSize(.small).disabled(model.summarizing)
            }
            HStack(spacing: 8) {
                Picker("요약 범위", selection: $scope) {
                    Text(model.t("summary.all")).tag("all")
                    Text(model.t("summary.speakers")).tag("speakers")
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
                Text("12초 간격 갱신").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = model.summaryError { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                if scope == "all" {
                    if let summary = model.displayConversation?.summaries?["all"] {
                        summaryCard(label: "전체 대화", summary: summary, color: .accentColor)
                    } else {
                        Text("대화가 쌓이면 핵심 내용·결정 사항·할 일·미해결 질문을 정리합니다.").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                    }
                } else {
                    let speakers = Array(Set((model.displayConversation?.turns ?? []).compactMap(\.speaker))).sorted()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(speakers, id: \.self) { speaker in
                            if let summary = model.displayConversation?.summaries?["speaker-\(speaker)"] {
                                summaryCard(label: "화자 \(speaker) · 추정", summary: summary, color: speakerColor(speaker))
                            } else { Text("화자 \(speaker) · 요약 대기 중").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        if speakers.isEmpty { Text("화자가 구분되면 화자별로 발언을 정리합니다.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
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
    private func summaryCard(label: String, summary: SummaryState, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(color)
                Spacer()
                Text(summary.updatedAt, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
            }
            Text(summary.text).font(.system(size: model.panelTypography.summary)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct STTPanel: View {
    @ObservedObject var model: AppModel
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if showSpeakers, showAll, let turns = model.displayConversation?.turns, !turns.isEmpty {
                                ForEach(turns) { turn in
                                    Text("\(turn.label)\n\(turn.text)").font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if !spans.isEmpty {
                                if showAll, let first = model.displayConversation?.transcriptSpans?.first, first.start > 0 {
                                    Text("기존 기록 · 발언 시각 정보 없음").font(.caption).foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                    Text(String((model.displayConversation?.transcript ?? "").prefix(first.start))).font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled)
                                }
                                ForEach(spans) { span in
                                    let latest = span.id == spans.last?.id
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
                            } else if showAll || !(model.displayConversation?.transcriptSpans?.isEmpty == false) {
                                Text(model.displayConversation?.transcript.isEmpty == false ? model.displayConversation!.transcript : "대화를 시작하면 최근 발언이 여기에 표시됩니다.")
                                    .font(.system(size: model.sttAppearance.fontSize)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if model.displayConversation?.transcript.isEmpty == false { Text("기존 기록 · 발언 시각 정보 없음").font(.caption).foregroundStyle(model.sttAppearance.text.color.opacity(0.75)) }
                            } else { Text("최근 \(model.recentSeconds / 60)분 동안 새 발언이 없습니다.").foregroundStyle(model.sttAppearance.text.color.opacity(0.75)) }
                            Color.clear.frame(height: 1).id("stt-bottom")
                        }.padding(4)
                    }
                    .readingScrollControl(model)
                    .onChange(of: model.selectedLiveBlockID) { _, selected in if let selected { proxy.scrollTo(selected, anchor: .center) } }
                    .onChange(of: model.displayConversation?.transcript) { _, _ in if model.followLive { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                    .onChange(of: model.followLive) { _, follow in if follow { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
                    .onChange(of: model.selectedID) { _, _ in proxy.scrollTo("stt-bottom", anchor: .bottom) }
                    .onAppear { if model.followLive { proxy.scrollTo("stt-bottom", anchor: .bottom) } }
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

