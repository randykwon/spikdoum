import SwiftUI
import FoundationModels
import Translation
import CoreGraphics

@MainActor
final class AudioLevelMonitor: ObservableObject {
    @Published var level: Double = 0
}

@MainActor
final class AppModel: ObservableObject {
    let managedModels = ManagedModelManager()
    let managedMic = ManagedSpeechCapture()
    let managedSystem = ManagedSpeechCapture()
    @Published var finishingCapture = false
    @Published var deletionMode = DeletionMode(rawValue: UserDefaults.standard.string(forKey: "conversationDeletionMode") ?? "") ?? .archive {
        didSet { UserDefaults.standard.set(deletionMode.rawValue, forKey: "conversationDeletionMode") }
    }
    @Published var panelTypography = PanelTypography.load() { didSet { panelTypography.save() } }
    @Published var panelLayout = PanelLayout.load() { didSet { panelLayout.save() } }
    @Published var sttAppearance = STTAppearance.load() { didSet { sttAppearance.save() } }
    @Published var settings = EngineSettings.load() {
        didSet {
            settings.save()
            guard oldValue != settings else { return }
            if oldValue.stt != settings.stt {
                scheduleLiveCaptureRestart(notice: "STT 엔진이 변경되어 듣기를 자동 재연결합니다.")
            }
            if oldValue.translation != settings.translation
                || oldValue.azureRegion != settings.azureRegion
                || oldValue.localTranslation != settings.localTranslation {
                reloadTranslationEngineAfterSettingsChange()
            }
        }
    }
    @Published var systemAudioPermissionGranted = CGPreflightScreenCaptureAccess()
    @Published var permissionStatus = AudioPermissions.status
    @Published var changingOutputDevice = false
    @Published var outputDevices: [AudioInputDevice] = []
    @Published var selectedOutputUID = ""
    @Published var activeOutputName = "출력 장치 확인 중"
    @Published var outputDeviceError: String?
    @Published var activeInputName = "시스템 기본 입력"
    @Published var sttStatus = "대화 준비"
    @Published var translationPreview: TranslationEntry?
    @Published var translationStatus = "원문을 기다리는 중"
    @Published var translationLatency: Int?
    @Published var adviceLatency: Int?
    @Published var meetingTarget = MeetingAudioTarget(rawValue: UserDefaults.standard.string(forKey: "meetingAudioTarget") ?? "") ?? .all {
        didSet {
            UserDefaults.standard.set(meetingTarget.rawValue, forKey: "meetingAudioTarget")
            if meetingTarget != .all { includeSystemAudio = true; systemAudioOnly = false }
            if oldValue != meetingTarget && listening { scheduleLiveCaptureRestart() }
        }
    }
    @Published var systemAudioOnly = UserDefaults.standard.bool(forKey: "systemAudioOnly") {
        didSet {
            UserDefaults.standard.set(systemAudioOnly, forKey: "systemAudioOnly")
            if systemAudioOnly { deviceError = nil }
            if oldValue != systemAudioOnly && listening { scheduleLiveCaptureRestart() }
        }
    }
    let audioLevelMonitor = AudioLevelMonitor()
    @Published var includeSystemAudio = UserDefaults.standard.bool(forKey: "includeSystemAudio") {
        didSet {
            UserDefaults.standard.set(includeSystemAudio, forKey: "includeSystemAudio")
            if oldValue != includeSystemAudio && listening { scheduleLiveCaptureRestart() }
        }
    }
    let systemAudio = SystemAudioCapture()
    let systemSpeech = SpeechCapture()
    let audioRecorder = ConversationAudioRecorder()
    var recordingConversationID: UUID?
    @Published var recordAudioForReplay = (UserDefaults.standard.object(forKey: "recordAudioForReplay") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(recordAudioForReplay, forKey: "recordAudioForReplay")
            if oldValue != recordAudioForReplay && listening { scheduleLiveCaptureRestart() }
        }
    }
    @Published var autoStartListeningOnNewConversation = UserDefaults.standard.bool(forKey: "autoStartListeningOnNewConversation") {
        didSet { UserDefaults.standard.set(autoStartListeningOnNewConversation, forKey: "autoStartListeningOnNewConversation") }
    }
    var duplex = DuplexTranscript()
    var captureRun = UUID()
    var routeRetries = 0
    var listeningStartedAt = Date.distantPast
    var missingInputDevicePolls = 0
    let cloudCapture = CloudSpeechCapture()
    var stableCloudTranscript: String?
    var persistenceTask: Task<Void, Never>?
    var hasUnsavedChanges = false
    @Published var selectedLiveBlockID: UUID?
    @Published var recentSeconds: Int = {
        if UserDefaults.standard.object(forKey: "recentActivitySeconds") != nil {
            return UserDefaults.standard.integer(forKey: "recentActivitySeconds")
        }
        return 0
    }() {
        didSet { UserDefaults.standard.set(recentSeconds, forKey: "recentActivitySeconds") }
    }
    @Published var selectedConversationBlockID: String?
    @Published private(set) var readingState = ReadingState()
    @Published var followLive = true {
        didSet {
            guard oldValue != followLive else { return }
            if followLive { readingState.resume(); selectedLiveBlockID = nil; selectedConversationBlockID = nil }
            else { readingState.pause(current, listening: listening) }
        }
    }
    var displayConversation: Conversation? { followLive ? current : readingState.display(current: current) }
    var hasUnreadLiveChanges: Bool {
        guard !followLive, let frozen = readingState.conversation, let current else { return false }
        return frozen.transcript != current.transcript || frozen.advice.count != current.advice.count || frozen.translations?.count != current.translations?.count || frozen.keywordHistory?.count != current.keywordHistory?.count
    }
    func pauseReading() { if followLive { followLive = false } }
    func resumeReading() { followLive = true }
    @Published var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    @Published var listening = false
    @Published var starting = false
    @Published var generating = false
    @Published var autoAdvice = (UserDefaults.standard.object(forKey: "automaticAdvice") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoAdvice, forKey: "automaticAdvice") }
    }
    @Published var bilingualCoach = (UserDefaults.standard.object(forKey: "bilingualCoach") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(bilingualCoach, forKey: "bilingualCoach") }
    }
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedInputUID, forKey: "inputDeviceUID")
            if oldValue != selectedInputUID && listening && !systemAudioOnly {
                scheduleLiveCaptureRestart(notice: "입력 마이크가 변경되어 듣기를 자동 재연결합니다.")
            }
        }
    }
    var liveCaptureRestartTask: Task<Void, Never>?
    var restartingForSettingsChange = false

    func scheduleLiveCaptureRestart(notice: String? = nil) {
        guard listening, !starting, !restartingForSettingsChange else { return }
        if let notice { presetNotice = notice }
        liveCaptureRestartTask?.cancel()
        liveCaptureRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.listening, !self.starting else { return }
            self.restartingForSettingsChange = true
            defer { self.restartingForSettingsChange = false }
            self.stop()
            await self.start()
        }
    }

    func reloadTranslationEngineAfterSettingsChange() {
        translationDebounce?.cancel(); translationDebounce = nil
        translationWatchdog?.cancel()
        translationTask?.cancel()
        translationToken = UUID()
        translating = false
        liveTranslation = ""
        translationSource = ""
        translationRetryCount = 0
        translationRetryAfter = .distantPast
        translationError = nil
        nativeTranslationSessions.removeAll()
        if !(current?.transcript.isEmpty ?? true) {
            translateLatest(automatic: true)
        }
    }
    @Published var summarizing = false
    @Published var summaryError: String?
    var summaryTask: Task<Void, Never>?
    var summaryDebounce: Task<Void, Never>?
    var summaryToken = UUID()
    @Published var organizingScript = false
    @Published var scriptError: String?
    var scriptToken = UUID()
    var speakerCursor = 0
    @Published var speakerStatus = "듣기를 시작하면 화자를 분석합니다."
    @Published var deviceError: String?
    @Published var interfaceLanguage = AppInterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage") }
    }
    var uiLanguage: ResolvedUILanguage { interfaceLanguage.resolved }
    func t(_ key: String) -> String { L10n.t(key, lang: uiLanguage) }
    @Published var language = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "en-US" {
        didSet {
            UserDefaults.standard.set(language, forKey: "recognitionLanguage")
            if language != LanguageCatalog.autoCode {
                lastFixedLanguage = language
                detectedSTTLanguage = nil
            }
        }
    }
    @Published var lastFixedLanguage = UserDefaults.standard.string(forKey: "lastFixedRecognitionLanguage") ?? "en-US" {
        didSet { UserDefaults.standard.set(lastFixedLanguage, forKey: "lastFixedRecognitionLanguage") }
    }
    @Published var detectedSTTLanguage: SupportedLanguage?
    var isAutoDetectLanguage: Bool { language == LanguageCatalog.autoCode }
    var canUseAutoDetectSTT: Bool {
        if settings.stt != .apple { return true }
        if let selected = managedModels.selected(.stt) {
            return managedModels.installed.contains(selected.id)
        }
        return false
    }
    var sttLanguageBadge: String {
        if isAutoDetectLanguage {
            if let detected = detectedSTTLanguage {
                return "\(t("stt.mode.auto")) · \(detected.displayName(in: uiLanguage))"
            }
            return t("stt.mode.auto")
        }
        return languageName
    }
    func setAutoDetectSTT(_ enabled: Bool) {
        if enabled {
            selectSTTLanguage(LanguageCatalog.autoCode)
        } else {
            let fallback = LanguageCatalog.language(for: lastFixedLanguage)?.code ?? "en-US"
            selectSTTLanguage(fallback)
        }
    }
    func selectSTTLanguage(_ code: String) {
        var engineSwitched = false
        if code == LanguageCatalog.autoCode {
            if settings.stt == .apple {
                if let selected = managedModels.selected(.stt), managedModels.installed.contains(selected.id) {
                    settings.stt = .managed
                    engineSwitched = true
                    presetNotice = "STT 언어 자동 인식을 위해 자체 Whisper 엔진으로 전환했습니다."
                } else {
                    presetNotice = "언어 자동 인식은 자체 Whisper 모델(모델 관리에서 다운로드) 또는 Deepgram STT에서 지원됩니다."
                    return
                }
            }
            language = LanguageCatalog.autoCode
            detectedSTTLanguage = nil
        } else {
            language = code
            detectedSTTLanguage = nil
        }
        nativeTranslationSessions.removeAll()
        translationRetryCount = 0
        translationRetryAfter = .distantPast
        translationError = nil
        if !(current?.transcript.isEmpty ?? true) { scheduleTranslation() }
        guard listening else { return }
        if settings.stt == .managed && !engineSwitched {
            managedMic.updateLanguage(language)
            managedSystem.updateLanguage(language)
            sttStatus = "자체 STT · \(sttLanguageBadge)"
        } else {
            stop()
            Task { [weak self] in await self?.start() }
        }
    }
    func selectTargetLanguage(_ code: String) {
        guard code != targetLanguage else { return }
        targetLanguage = code
        translationDebounce?.cancel(); translationDebounce = nil
        translationWatchdog?.cancel()
        translationTask?.cancel()
        translationToken = UUID()
        translating = false
        liveTranslation = ""
        translationSource = ""
        translationPreview = nil
        translationBatchStartedAt = nil
        translationRetryCount = 0
        translationRetryAfter = .distantPast
        translationError = nil
        nativeTranslationSessions.removeAll()
        if !(current?.transcript.isEmpty ?? true) {
            translateLatest(automatic: false)
        }
    }
    @Published var targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "ko-KR" {
        didSet {
            UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage")
            nativeTranslationSessions.removeAll()
        }
    }
    var targetLanguageSpec: SupportedLanguage {
        LanguageCatalog.language(for: targetLanguage) ?? LanguageCatalog.all[1]
    }
    var sourceLanguageSpec: SupportedLanguage? {
        language == LanguageCatalog.autoCode ? nil : LanguageCatalog.language(for: language)
    }
    func effectiveCoachSourceLanguage(for context: String) -> SupportedLanguage? {
        if let fixed = sourceLanguageSpec { return fixed }
        let cleaned = TranslationPolicy.preparedForTranslation(context)
        return LanguageCatalog.detectLanguage(for: cleaned.isEmpty ? context : cleaned) ?? detectedSTTLanguage
    }
    var coachLanguageSummary: String {
        guard bilingualCoach else { return targetLanguageName }
        let sttSpec = sourceLanguageSpec ?? detectedSTTLanguage
        if let sttSpec, sttSpec.code == targetLanguageSpec.code {
            return targetLanguageName
        }
        return "\(sttLanguageBadge) + \(targetLanguageName)"
    }
    @Published var liveResponse = ""
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published var preparingTranslation = false
    @Published var translating = false
    @Published var liveTranslation = ""
    @Published var translationSource = ""
    @Published var translationError: String?
    var translationTask: Task<Void, Never>?
    var translationDebounce: Task<Void, Never>?
    var translationWatchdog: Task<Void, Never>?
    var translationBatchStartedAt: Date?
    var lastTranscriptChange = Date.distantPast
    var translationRetryCount = 0
    var translationRetryAfter = Date.distantPast
    var translationToken = UUID()
    var nativeTranslationSessions: [String: TranslationSession] = [:]
    var debounce: Task<Void, Never>?
    var responseToken = UUID()
    var languages: [(String, String)] {
        let base = LanguageCatalog.all.map { ($0.code, $0.displayName(in: uiLanguage)) }
        if canUseAutoDetectSTT {
            return [(LanguageCatalog.autoCode, t("stt.mode.auto"))] + base
        }
        return base
    }
    var targetLanguages: [(String, String)] {
        LanguageCatalog.all.map { ($0.code, $0.displayName(in: uiLanguage)) }
    }
    var translationEngineDescription: String {
        switch settings.translation {
        case .apple: return "Apple · \(languageName) → \(targetLanguageName)"
        case .azure: return "Azure · \(t("lang.auto")) → \(targetLanguageName)"
        case .local: return "Local LLM · \(languageName) → \(targetLanguageName)"
        case .managed: return "Managed · \(languageName) → \(targetLanguageName)"
        }
    }
    var languageName: String { LanguageCatalog.displayName(for: language, in: uiLanguage) }
    var targetLanguageName: String { targetLanguageSpec.displayName(in: uiLanguage) }
    @Published var message: String?
    @Published var goal = "상대의 의도를 이해하고, 명확하고 자연스럽게 대화를 이어가기"
    let capture = SpeechCapture()
    var timer: Task<Void, Never>?
    @Published var showTranslationKeywords = (UserDefaults.standard.object(forKey: "showTranslationKeywords") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showTranslationKeywords, forKey: "showTranslationKeywords") }
    }
    @Published var extractingKeywords = false
    @Published var keywordError: String?
    var keywordToken = UUID()
    var lastKeywordAttempt = Date.distantPast
    var lastContext = ""
    var lastAdviceAttempt = Date.distantPast
    let store: ConversationStore
    var recordingsRoot: URL { RecordingStorage.recordingsRoot(nextTo: store.file) }
    @Published var replayTarget: Conversation?
    @Published var presetNotice: String?

    var current: Conversation? { conversations.first { $0.id == selectedID } }
    var modelStatus: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return "기기 내 AI를 사용할 수 없습니다 (\(reason)). 시스템 설정에서 Apple Intelligence를 활성화하고 모델 다운로드를 완료해주세요."
        }
    }
    var captureSummary: String {
        let source = systemAudioOnly ? "Mac 소리만" : includeSystemAudio ? "마이크 + Mac 소리" : "마이크만"
        return "\(source) · \(languageName) · \(meetingTarget.title) · 조언 \(autoAdvice ? "자동" : "수동")"
    }

    init() {
        let folder = AppStorageMigration.appSupportDirectory()
        store = ConversationStore(file: folder.appendingPathComponent("conversations.json"))
        do {
            conversations = try store.load()
        } catch { message = "기록을 읽지 못했습니다: \(error.localizedDescription)" }
        refreshInputDevices()
        selectedID = conversations.first { $0.archivedAt == nil }?.id
        if selectedID == nil { newConversation() } else {
            lastContext = current?.advice.last?.sourceSnapshot ?? (current?.advice.isEmpty == false ? current?.transcript ?? "" : "")
            scheduleTranslation()
        }
    }

    func refreshInputDevices() {
        refreshOutputDevices()
        permissionStatus = AudioPermissions.status
        systemAudioPermissionGranted = CGPreflightScreenCaptureAccess()
        do {
            inputDevices = try AudioInputDevices.list()
            deviceError = nil
            let deviceID = try? AudioInputDevices.resolve(uid: selectedInputUID)
            activeInputName = inputDevices.first { $0.id == deviceID }?.name ?? "연결된 입력 없음"
            if !systemAudioOnly && !selectedInputUID.isEmpty && !inputDevices.contains(where: { $0.uid == selectedInputUID }) {
                if listening {
                    missingInputDevicePolls += 1
                    // Tolerate a single 3s poll miss during Bluetooth HFP/A2DP profile switches before stopping capture.
                    if missingInputDevicePolls >= 2 {
                        stop()
                        deviceError = "선택한 입력 디바이스의 연결이 끊겼습니다. 다른 장치를 선택해주세요."
                    }
                } else {
                    missingInputDevicePolls = 0
                    deviceError = "이전에 선택한 마이크가 연결되어 있지 않습니다. 듣기를 시작하면 시스템 기본 입력으로 자동 전환됩니다."
                }
            } else {
                missingInputDevicePolls = 0
            }
        } catch { deviceError = systemAudioOnly ? nil : error.localizedDescription }
    }
    func useDefaultInputDevice() {
        selectedInputUID = ""
        deviceError = nil
        message = nil
        refreshInputDevices()
    }
    func refreshOutputDevices() {
        guard !changingOutputDevice else { return }
        do {
            outputDevices = try AudioOutputDevices.list()
            let current = try AudioOutputDevices.current()
            let device = outputDevices.first { $0.id == current }
            selectedOutputUID = device?.uid ?? ""
            activeOutputName = device?.name ?? "사용 가능한 출력 장치 없음"
        } catch { outputDeviceError = error.localizedDescription }
    }
    func chooseOutputDevice(_ uid: String) {
        guard uid != selectedOutputUID, !changingOutputDevice else { return }
        changingOutputDevice = true
        selectedOutputUID = uid
        outputDeviceError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.changingOutputDevice = false; self.refreshOutputDevices() }
            do {
                try AudioOutputDevices.setDefault(uid: uid)
                for _ in 0..<30 {
                    let current = try AudioOutputDevices.current()
                    if self.outputDevices.first(where: { $0.uid == uid })?.id == current { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                self.outputDeviceError = "출력 장치 전환이 지연되고 있습니다. 연결 상태를 확인해주세요."
            } catch { self.outputDeviceError = error.localizedDescription }
        }
    }

    func applyPreset(_ preset: CapturePreset, browser: MeetingAudioTarget = .chrome) {
        guard !starting else { return }
        let plan = preset.plan(browser: browser)
        let wasListening = listening
        meetingTarget = plan.target
        includeSystemAudio = plan.systemAudio
        systemAudioOnly = plan.systemOnly
        autoAdvice = plan.automaticAdvice
        if wasListening {
            presetNotice = "\(preset.title) 추천 설정 적용됨 · 듣기를 자동으로 재연결합니다."
            scheduleLiveCaptureRestart()
        } else {
            presetNotice = "\(preset.title) 추천 설정 적용됨 · 인식 언어를 확인하고 듣기 시작을 누르세요."
        }
    }

    func newConversation(autoStart: Bool = false) {
        lastKeywordAttempt = .distantPast
        resumeReading()
        selectedLiveBlockID = nil
        stop()
        let item = Conversation()
        conversations.insert(item, at: 0)
        selectedID = item.id
        lastContext = ""
        detectedSTTLanguage = nil
        translationPreview = nil
        save()
        if autoStart && autoStartListeningOnNewConversation {
            Task { [weak self] in await self?.start() }
        }
    }
    func select(_ id: UUID) {
        lastKeywordAttempt = .distantPast
        resumeReading()
        selectedLiveBlockID = nil
        stop()
        translationPreview = nil
        selectedID = id
        lastContext = current?.advice.last?.sourceSnapshot ?? (current?.advice.isEmpty == false ? current?.transcript ?? "" : "")
        lastAdviceAttempt = .distantPast
        scheduleTranslation()
    }
    func openReplay(_ id: UUID) {
        if listening { stop() }
        replayTarget = conversations.first { $0.id == id }
    }
    func archiveConversation(_ id: UUID) { archiveConversations([id]) }
    func archiveConversations(_ ids: Set<UUID>) {
        let targets = Set(conversations.filter { ids.contains($0.id) && $0.archivedAt == nil }.map(\.id))
        guard !targets.isEmpty else { return }
        let movingCurrent = selectedID.map { targets.contains($0) } ?? false
        if movingCurrent { stop() }
        let date = Date()
        for index in conversations.indices where targets.contains(conversations[index].id) { conversations[index].archivedAt = date }
        save()
        if movingCurrent { selectNextActive() }
    }
    func restoreConversation(_ id: UUID) { restoreConversations([id]) }
    func restoreConversations(_ ids: Set<UUID>) {
        guard conversations.contains(where: { ids.contains($0.id) }) else { return }
        for index in conversations.indices where ids.contains(conversations[index].id) { conversations[index].archivedAt = nil }
        save()
    }
    func permanentlyDeleteConversation(_ id: UUID) { permanentlyDeleteConversations([id]) }
    @discardableResult func permanentlyDeleteConversations(_ ids: Set<UUID>) -> Bool {
        let targets = Set(conversations.filter { ids.contains($0.id) }.map(\.id))
        guard !targets.isEmpty else { return true }
        let removingCurrent = selectedID.map { targets.contains($0) } ?? false
        if removingCurrent { stop() }
        persistenceTask?.cancel()
        persistenceTask = nil
        store.cancelAndDrain()
        let remaining = conversations.filter { !targets.contains($0.id) }
        do {
            try ConversationLifecycle.persistRemoval(ids: targets, remaining: remaining, file: store.file)
            conversations = remaining
            hasUnsavedChanges = false
            if removingCurrent { selectNextActive() }
            return true
        } catch { message = "완전 삭제 실패: \(error.localizedDescription)"; return false }
    }
    private func selectNextActive() {
        if let next = conversations.first(where: { $0.archivedAt == nil }) { select(next.id) }
        else { newConversation() }
    }

    func updateText(_ text: String) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }), conversations[index].archivedAt == nil else { return }
        if conversations[index].transcript != text {
            lastTranscriptChange = Date()
            if isAutoDetectLanguage, let detected = LanguageCatalog.detectLanguage(for: text) {
                if detectedSTTLanguage?.code != detected.code { detectedSTTLanguage = detected }
            }
        }
        conversations[index].transcriptSpans = RecentActivity.update(old: conversations[index].transcript, new: text,
                                                                      spans: conversations[index].transcriptSpans ?? [], at: Date())
        conversations[index].transcript = text
        if followLive, let selectedLiveBlockID, !(conversations[index].transcriptSpans ?? []).contains(where: { $0.id == selectedLiveBlockID }) { self.selectedLiveBlockID = nil }
        if conversations[index].title == "새 대화", text.count > 5 { conversations[index].title = String(text.prefix(24)) }
        scheduleSave()
        scheduleTranslation()
        scheduleResponse()
        summaryDebounce?.cancel()
        summaryDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.refreshSummaries()
        }
    }

    func scheduleSave() {
        hasUnsavedChanges = true
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func save() {
        persistenceTask?.cancel()
        persistenceTask = nil
        hasUnsavedChanges = false
        let snapshot = conversations
        store.saveAsync(snapshot) { [weak self] errorMessage in
            Task { @MainActor in self?.message = errorMessage }
        }
    }
    func saveSynchronously() {
        persistenceTask?.cancel()
        persistenceTask = nil
        do {
            try store.saveSync(conversations)
            hasUnsavedChanges = false
        } catch { message = "기록 저장 실패: \(error.localizedDescription)" }
    }
}
