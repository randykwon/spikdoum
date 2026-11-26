import SwiftUI
import FoundationModels
import Translation
import CoreGraphics

enum AudioInputMode: String, CaseIterable {
    case micAndSystem
    case systemOnly
    case micOnly

    var shortLabel: String {
        switch self {
        case .micAndSystem: return "내 목소리 + Mac"
        case .systemOnly: return "Mac 소리만"
        case .micOnly: return "내 마이크만"
        }
    }

    var icon: String {
        switch self {
        case .micAndSystem: return "waveform.and.mic"
        case .systemOnly: return "speaker.wave.2.fill"
        case .micOnly: return "mic.fill"
        }
    }
}

enum MicLanguageMode: String, CaseIterable {
    case autoOrTarget
    case sameAsSTT
}

@MainActor
final class AudioLevelMonitor: ObservableObject {
    @Published var level: Double = 0
}

/// Dedicated ultra-lightweight observable store for live uncommitted STT hypotheses.
/// Updating this store redraws ONLY the live caption row (<0.2ms) instead of invalidating
/// `ContentView`, the sidebar, `ConversationBlocks`, `SummaryScriptPanel`, or triggering disk saves.
@MainActor
final class LiveSTTDisplayStore: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var sourceTag: String? = nil
    @Published private(set) var updatedAt: Date = .distantPast
    private var perSource: [String: String] = [:]

    func update(text raw: String, sourceTag: String?) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = sourceTag ?? "_default"
        if cleaned.isEmpty {
            perSource.removeValue(forKey: key)
        } else {
            perSource[key] = cleaned
        }
        let nextText: String
        let nextTag: String?
        if !cleaned.isEmpty {
            nextText = cleaned
            nextTag = sourceTag
        } else if let remaining = perSource.first {
            nextText = remaining.value
            nextTag = remaining.key == "_default" ? nil : remaining.key
        } else {
            nextText = ""
            nextTag = nil
        }
        if self.text != nextText || self.sourceTag != nextTag {
            self.text = nextText
            self.sourceTag = nextTag
            self.updatedAt = Date()
        }
    }

    func clear(sourceTag: String? = nil) {
        if let sourceTag {
            update(text: "", sourceTag: sourceTag)
            return
        }
        perSource.removeAll()
        if !text.isEmpty || self.sourceTag != nil {
            text = ""
            self.sourceTag = nil
            updatedAt = .distantPast
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let managedModels = ManagedModelManager()
    let managedMic = ManagedSpeechCapture()
    let managedSystem = ManagedSpeechCapture()
    let parakeetModels = ParakeetModelManager()
    let parakeetMic = ParakeetSpeechCapture()
    let parakeetSystem = ParakeetSpeechCapture()
    let appleSpeechAssets = AppleSpeechAssetManager()
    let pptSlideSync = PPTSlideSyncMonitor()
    let liveSTT = LiveSTTDisplayStore()
    @Published var sttTier = SpeedQualityTier.loadSTT() {
        didSet { sttTier.saveSTT() }
    }
    @Published var translationTier = SpeedQualityTier.loadTranslation() {
        didSet { translationTier.saveTranslation() }
    }
    @Published var finishingCapture = false
    @Published var perspective: AppPerspective = AppPerspective.load() {
        didSet { perspective.save() }
    }
    @Published var hideFromScreenShare = false
    @Published var presentationTimerRunning = false
    @Published var compressingCueCards = false
    @Published var recommendingPresentation = false
    @Published var presentationRecommendation: PresentationRecommendation? = nil
    @Published var presentationError: String?
    @Published var linkedPPTNotesPendingUpdate: String? = nil
    var presentationTimerTask: Task<Void, Never>?
    var presentationCompressToken = UUID()
    var presentationRecommendToken = UUID()
    @Published var micMuted = false {
        didSet {
            applyMicMuteState()
            guard oldValue != micMuted, listening, !systemAudioOnly else { return }
            if micMuted {
                sttStatus = includeSystemAudio ? "내 마이크 음소거 · Mac 재생음 수신 중" : "내 마이크 음소거됨"
            } else {
                sttStatus = includeSystemAudio ? "마이크 + Mac 재생음 수신 중" : "마이크 연결됨 · 음성 대기"
            }
        }
    }
    func applyMicMuteState() {
        let effectiveMute = micMuted && !systemAudioOnly
        capture.setMuted(effectiveMute)
        managedMic.setMuted(effectiveMute)
        parakeetMic.setMuted(effectiveMute)
        cloudCapture.setMuted(effectiveMute)
    }
    @Published var topHeaderCollapsed = UserDefaults.standard.bool(forKey: "topHeaderCollapsedV1") {
        didSet {
            UserDefaults.standard.set(topHeaderCollapsed, forKey: "topHeaderCollapsedV1")
        }
    }
    @Published var simpleFastMode = UserDefaults.standard.bool(forKey: "simpleFastMode") {
        didSet {
            UserDefaults.standard.set(simpleFastMode, forKey: "simpleFastMode")
            guard oldValue != simpleFastMode else { return }
            if simpleFastMode {
                debounce?.cancel(); debounce = nil
                summaryDebounce?.cancel(); summaryDebounce = nil
                responseToken = UUID()
                keywordToken = UUID()
                summaryToken = UUID()
                scriptToken = UUID()
                liveResponse = ""
                if !(current?.transcript.isEmpty ?? true) {
                    scheduleTranslation(immediate: true)
                }
            } else if !(current?.transcript.isEmpty ?? true) {
                scheduleResponse()
            }
        }
    }
    @Published var deletionMode = DeletionMode(rawValue: UserDefaults.standard.string(forKey: "conversationDeletionMode") ?? "") ?? .archive {
        didSet { UserDefaults.standard.set(deletionMode.rawValue, forKey: "conversationDeletionMode") }
    }
    @Published var panelTypography = PanelTypography.load() { didSet { panelTypography.save() } }
    @Published var panelLayout = PanelLayout.load() { didSet { panelLayout.save() } }
    var cueCardToken = UUID()
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
            if oldValue.llm != settings.llm
                || oldValue.keywordLLM != settings.keywordLLM
                || oldValue.summaryLLM != settings.summaryLLM {
                refreshModelStatus()
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
    @Published var micLanguageMode = MicLanguageMode(rawValue: UserDefaults.standard.string(forKey: "micLanguageMode") ?? "") ?? .autoOrTarget {
        didSet {
            UserDefaults.standard.set(micLanguageMode.rawValue, forKey: "micLanguageMode")
            guard oldValue != micLanguageMode else { return }
            if listening && !systemAudioOnly {
                if settings.stt == .managed {
                    managedMic.updateLanguage(effectiveMicWhisperLanguage)
                } else {
                    scheduleLiveCaptureRestart(notice: "내 마이크 인식 언어를 전환합니다.")
                }
            }
        }
    }
    var audioInputMode: AudioInputMode {
        if systemAudioOnly { return .systemOnly }
        return includeSystemAudio ? .micAndSystem : .micOnly
    }
    var effectiveMicWhisperLanguage: String {
        switch micLanguageMode {
        case .autoOrTarget: return LanguageCatalog.autoCode
        case .sameAsSTT: return language
        }
    }
    var effectiveMicAppleLocale: String {
        switch micLanguageMode {
        case .autoOrTarget: return targetLanguage
        case .sameAsSTT: return language == LanguageCatalog.autoCode ? "en-US" : language
        }
    }
    func setAudioInputMode(_ mode: AudioInputMode) {
        guard audioInputMode != mode else { return }
        switch mode {
        case .micAndSystem:
            systemAudioOnly = false
            includeSystemAudio = true
            presetNotice = "내 마이크와 Mac 재생음을 함께 인식·번역합니다. (헤드셋 권장)"
        case .systemOnly:
            systemAudioOnly = true
            includeSystemAudio = true
            presetNotice = "Mac 재생음만 인식합니다."
        case .micOnly:
            systemAudioOnly = false
            includeSystemAudio = false
            presetNotice = "내 마이크 목소리만 인식합니다."
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
    @Published var summaryLanguages = SummaryLanguagePreferences.load() {
        didSet { summaryLanguages.save() }
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

    var activeSTTModelLabel: String {
        switch settings.stt {
        case .apple:
            let locale = isAutoDetectLanguage ? lastFixedLanguage : language
            return appleSpeechAssets.isInstalled(for: locale) ? "Apple 실시간 STT" : "Apple STT"
        case .deepgram: return "Deepgram"
        case .managed: return managedModels.selected(.stt)?.name ?? "Whisper"
        case .parakeet: return "Parakeet ANE"
        }
    }

    var activeTranslationModelLabel: String {
        switch settings.translation {
        case .apple: return "Apple 번역"
        case .azure: return "Azure 번역"
        case .local: return "로컬 번역"
        case .managed: return managedModels.selected(.translation)?.name ?? "자체 번역"
        }
    }

    var activeLLMModelLabel: String {
        switch settings.llm {
        case .apple: return "Apple AI"
        case .managed:
            if let name = managedModels.selected(.llm)?.name {
                return name.replacingOccurrences(of: " Instruct", with: "").replacingOccurrences(of: " · Q4", with: "")
            }
            return "자체 LLM"
        case .openAI:
            let model = settings.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "OpenAI" : model
        case .compatible:
            let model = settings.serverModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? "외부 LLM" : model
        }
    }

    var isHybridFastPresetActive: Bool {
        sttTier == .ultraFast
            && settings.translation == .apple
            && settings.llm != .apple
    }

    /// One-click Hybrid Fast Architecture:
    /// Real-time fast lane (Ultra-fast STT + Apple ~30ms on-device translation)
    /// + Intelligence lane (Dedicated local Qwen3/Gemma LLM or configured cloud/server LLM for coaching, summaries, keywords).
    func applyHybridFastPreset() async {
        await applySTTTier(.ultraFast, announce: false)
        await applyTranslationTier(.ultraFast, announce: false)
        if let bestLocal = managedModels.bestInstalledLLMModel() {
            await switchLLMEngine(.managed, managedModelID: bestLocal.id, announce: false)
            Task { [weak self] in
                _ = try? await self?.managedModels.ensureReady(.llm)
            }
        } else if settings.llm == .apple {
            // Keep Apple AI if no local GGUF model is installed yet, and inform the user clearly.
            presetNotice = "초고속 STT + Apple 번역 적용됨 · 코치·요약용 자체 LLM(Qwen3 4B 등)을 모델 관리에서 다운로드하면 하이브리드 모드가 완성됩니다."
            return
        }
        presetNotice = "⚡ 초고속 하이브리드 적용 · STT: \(activeSTTModelLabel) · 번역: Apple 번역(~30ms) · 코치·요약: \(activeLLMModelLabel)"
    }

    func switchLLMEngine(_ engine: LLMEngine, managedModelID: String? = nil, announce: Bool = true) async {
        let previousEngine = settings.llm
        let previousModelID = managedModels.selectedLLM
        if engine == .managed {
            let targetModel: ManagedModel?
            if let managedModelID {
                targetModel = managedModels.models(for: .llm).first { $0.id == managedModelID && managedModels.installed.contains($0.id) }
            } else if let current = managedModels.selected(.llm), managedModels.installed.contains(current.id) {
                targetModel = current
            } else {
                targetModel = managedModels.bestInstalledLLMModel()
            }
            guard let chosen = targetModel else {
                message = "설치된 자체 로컬 LLM(.gguf) 모델이 없습니다. 모델 관리에서 Qwen3 4B 등을 다운로드해주세요."
                return
            }
            if previousModelID != chosen.id {
                await managedModels.select(chosen, for: .llm)
            }
            if previousEngine != .managed {
                settings.llm = .managed
            } else if previousModelID != chosen.id {
                objectWillChange.send()
            }
            if announce {
                presetNotice = "코치·요약·키워드 LLM을 자체 로컬 모델(\(chosen.name))로 전환했습니다."
            }
            Task { [weak self] in
                _ = try? await self?.managedModels.ensureReady(.llm)
            }
            return
        }
        guard previousEngine != engine else { return }
        settings.llm = engine
        if announce {
            presetNotice = "코치·요약·키워드 LLM을 \(activeLLMModelLabel)(으)로 전환했습니다."
        }
    }

    func applySpeedQualityTier(_ tier: SpeedQualityTier) async {
        await applySTTTier(tier, announce: false)
        await applyTranslationTier(tier, announce: false)
        presetNotice = "[\(tier.shortBadge)] 적용 완료 · STT: \(activeSTTModelLabel) · 번역: \(activeTranslationModelLabel)"
    }

    func applySTTTier(_ tier: SpeedQualityTier, announce: Bool = true) async {
        sttTier = tier
        let targetLang = isAutoDetectLanguage ? LanguageCatalog.autoCode : language
        let appleLocale = isAutoDetectLanguage ? lastFixedLanguage : language
        let plan = tier.resolveSTTPlan(
            languageCode: targetLang,
            installedWhisperIDs: managedModels.installed,
            parakeetReady: parakeetModels.isCachedOnDisk || parakeetModels.isLoaded,
            appleModernReady: appleSpeechAssets.isInstalled(for: appleLocale)
        )
        let whisperTuningChanged = managedModels.whisperAudioContext != plan.audioContext
            || managedModels.whisperBestOf != plan.bestOf
        managedModels.whisperAudioContext = plan.audioContext
        managedModels.whisperBestOf = plan.bestOf

        let prevEngine = settings.stt
        let prevModel = managedModels.selectedSTT
        await switchSTTEngine(plan.engine, managedModelID: plan.managedModelID)
        if plan.engine == .managed && prevEngine == .managed && prevModel == managedModels.selectedSTT && whisperTuningChanged {
            if listening {
                scheduleLiveCaptureRestart(notice: "STT [\(tier.shortBadge)] 속도·스트리밍 설정으로 재연결합니다.")
            } else {
                await managedModels.stop(.stt)
            }
        }
        if announce {
            presetNotice = "STT [\(tier.shortBadge)] 적용 · \(activeSTTModelLabel) (\(plan.reason))"
        }
    }

    func applyTranslationTier(_ tier: SpeedQualityTier, announce: Bool = true) async {
        translationTier = tier
        let plan = tier.resolveTranslationPlan(installedTranslationIDs: managedModels.installed)
        await switchTranslationEngine(plan.engine, managedModelID: plan.managedModelID)
        if announce {
            presetNotice = "번역 [\(tier.shortBadge)] 적용 · \(activeTranslationModelLabel)"
        }
    }

    func switchSTTEngine(_ engine: STTEngine, managedModelID: String? = nil) async {
        let previousEngine = settings.stt
        let previousModelID = managedModels.selectedSTT
        if engine == .managed {
            let targetModel: ManagedModel?
            if let managedModelID {
                targetModel = managedModels.models(for: .stt).first { $0.id == managedModelID && managedModels.installed.contains($0.id) }
            } else if let current = managedModels.selected(.stt), managedModels.installed.contains(current.id) {
                targetModel = current
            } else {
                targetModel = managedModels.models(for: .stt).first { managedModels.installed.contains($0.id) }
            }
            guard let chosen = targetModel else {
                message = "설치된 자체 STT 모델이 없습니다. 메뉴에서 모델을 다운로드해주세요."
                return
            }
            if previousModelID != chosen.id {
                await managedModels.select(chosen)
            }
            if previousEngine != .managed {
                settings.stt = .managed
                presetNotice = "STT 모델(\(chosen.name))로 전환했습니다."
            } else if previousModelID != chosen.id {
                objectWillChange.send()
                if listening {
                    scheduleLiveCaptureRestart(notice: "STT 모델(\(chosen.name))로 자동 전환합니다.")
                } else {
                    presetNotice = "STT 모델(\(chosen.name))로 전환했습니다."
                }
            }
            return
        }
        guard previousEngine != engine else { return }
        settings.stt = engine
        presetNotice = "STT 엔진을 \(activeSTTModelLabel)(으)로 전환했습니다."
    }

    func switchTranslationEngine(_ engine: TranslationEngine, managedModelID: String? = nil) async {
        let previousEngine = settings.translation
        let previousModelID = managedModels.selectedTranslation
        if engine == .managed {
            let targetModel: ManagedModel?
            if let managedModelID {
                targetModel = managedModels.models(for: .translation).first { $0.id == managedModelID && managedModels.installed.contains($0.id) }
            } else if let current = managedModels.selected(.translation), managedModels.installed.contains(current.id) {
                targetModel = current
            } else {
                targetModel = managedModels.models(for: .translation).first { managedModels.installed.contains($0.id) }
            }
            guard let chosen = targetModel else {
                message = "설치된 자체 번역 모델이 없습니다. 메뉴에서 모델을 다운로드해주세요."
                return
            }
            if previousModelID != chosen.id {
                await managedModels.select(chosen)
            }
            if previousEngine != .managed {
                settings.translation = .managed
                presetNotice = "번역 모델(\(chosen.name))로 전환했습니다."
            } else if previousModelID != chosen.id {
                objectWillChange.send()
                reloadTranslationEngineAfterSettingsChange()
                presetNotice = "번역 모델(\(chosen.name))로 전환했습니다."
            }
            return
        }
        guard previousEngine != engine else { return }
        settings.translation = engine
        presetNotice = "번역 엔진을 \(activeTranslationModelLabel)(으)로 전환했습니다."
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
    @Published var summarizingWindow: RecentSummaryWindow? = nil
    @Published var summaryError: String?
    @Published var recentSummaryNotice: String?
    var summaryTask: Task<Void, Never>?
    var summaryDebounce: Task<Void, Never>?
    var summaryToken = UUID()
    var recentSummaryToken = UUID()
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
    @Published var autoLanguagePrefs = AutoLanguagePreferences.load() {
        didSet {
            autoLanguagePrefs.save()
            let allowLock = autoLanguagePrefs.mode == .singleLanguageFast
            managedMic.setAllowWarmLanguageLock(allowLock)
            managedSystem.setAllowWarmLanguageLock(allowLock)
        }
    }
    @Published var detectedSTTLanguage: SupportedLanguage?
    @Published var detectedLanguageConfidence: Double?
    @Published var recentDetectedLanguages: [SupportedLanguage] = []
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
            let candidatesSuffix = autoLanguagePrefs.preferredCodes.isEmpty ? "" : " (\(autoLanguagePrefs.shortSummary))"
            if recentDetectedLanguages.count >= 2 {
                let topTwo = recentDetectedLanguages.prefix(2).map { $0.shortCode.uppercased() }.joined(separator: "/")
                return "\(t("stt.mode.auto")) · \(topTwo)"
            }
            if let detected = detectedSTTLanguage {
                return "\(t("stt.mode.auto")) · \(detected.displayName(in: uiLanguage))"
            }
            return t("stt.mode.auto") + candidatesSuffix
        }
        return languageName
    }

    func recordDetectedLanguage(_ result: LanguageDetectionResult) {
        let preferred = autoLanguagePrefs.preferredCodes
        if !preferred.isEmpty && !preferred.contains(result.language.code) {
            // If user set explicit candidate languages, only accept out-of-set detections when script confidence is unmistakable.
            guard result.source == .script && result.confidence >= 0.92 else { return }
        }
        if detectedSTTLanguage?.code != result.language.code {
            detectedSTTLanguage = result.language
        }
        detectedLanguageConfidence = result.confidence
        recentDetectedLanguages.removeAll { $0.code == result.language.code }
        recentDetectedLanguages.insert(result.language, at: 0)
        if recentDetectedLanguages.count > 5 {
            recentDetectedLanguages = Array(recentDetectedLanguages.prefix(5))
        }
    }

    func applyAutoLanguagePreset(_ codes: [String], notice: String) {
        autoLanguagePrefs.preferredCodes = codes
        if !isAutoDetectLanguage {
            selectSTTLanguage(LanguageCatalog.autoCode)
        }
        presetNotice = notice
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
    func resolvedSummaryLanguages(for transcript: String? = nil) -> [SupportedLanguage] {
        let context = transcript ?? current?.transcript ?? ""
        let sttSpec = effectiveCoachSourceLanguage(for: context)
        return summaryLanguages.resolvedLanguages(sttSpec: sttSpec, targetSpec: targetLanguageSpec)
    }
    var summaryLanguageBadge: String {
        let langs = resolvedSummaryLanguages()
        if langs.count <= 2 {
            return langs.map { $0.displayName(in: uiLanguage) }.joined(separator: " + ")
        }
        let first = langs.first?.displayName(in: uiLanguage) ?? targetLanguageName
        return "\(first) 외 \(langs.count - 1)개"
    }
    func updateSummaryLanguages(_ mutate: (inout SummaryLanguagePreferences) -> Void) {
        mutate(&summaryLanguages)
        if !(current?.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            Task { [weak self] in await self?.refreshSummaries() }
        }
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

    @Published private(set) var cachedModelStatus: String? = nil
    var current: Conversation? { conversations.first { $0.id == selectedID } }
    var modelStatus: String? { cachedModelStatus }

    func refreshModelStatus() {
        guard settings.usesAppleLLMForAnyTask else {
            if cachedModelStatus != nil { cachedModelStatus = nil }
            return
        }
        Task.detached(priority: .utility) {
            let status: String?
            switch SystemLanguageModel.default.availability {
            case .available:
                status = nil
            case .unavailable(let reason):
                status = "기기 내 AI를 사용할 수 없습니다 (\(reason)). 시스템 설정에서 Apple Intelligence를 활성화하고 모델 다운로드를 완료해주세요."
            }
            await MainActor.run { [weak self] in
                guard let self, self.cachedModelStatus != status else { return }
                self.cachedModelStatus = status
            }
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
        refreshModelStatus()
        selectedID = conversations.first { $0.archivedAt == nil }?.id
        if selectedID == nil { newConversation() } else {
            lastContext = current?.advice.last?.sourceSnapshot ?? (current?.advice.isEmpty == false ? current?.transcript ?? "" : "")
            scheduleTranslation()
        }
        let initialLang = language
        pptSlideSync.onSlideChange = { [weak self] slideNumber in
            guard let self, self.perspective == .presentation else { return }
            let cards = PresentationNotesParser.parse(self.activePresentation.notesMarkdown)
            guard !cards.isEmpty else { return }
            let targetIndex = min(max(0, slideNumber - 1), cards.count - 1)
            if self.activePresentation.activeCardIndex != targetIndex {
                self.mutatePresentation { $0.activeCardIndex = targetIndex }
            }
        }
        pptSlideSync.onDeckSnapshot = { [weak self] snapshot, becameSlideShow, deckChanged in
            guard let self, self.perspective == .presentation else { return }
            self.handleLinkedPPTDeckEvent(snapshot: snapshot, becameSlideShow: becameSlideShow, deckChanged: deckChanged)
        }
        Task { [weak self] in
            await self?.appleSpeechAssets.refreshStatuses(extraLocale: initialLang)
        }
    }

    func refreshInputDevices() {
        refreshOutputDevices()
        let nextPerm = AudioPermissions.status
        if permissionStatus != nextPerm { permissionStatus = nextPerm }
        let nextSysPerm = CGPreflightScreenCaptureAccess()
        if systemAudioPermissionGranted != nextSysPerm { systemAudioPermissionGranted = nextSysPerm }
        do {
            let nextInputs = try AudioInputDevices.list()
            if inputDevices != nextInputs { inputDevices = nextInputs }
            let deviceID = try? AudioInputDevices.resolve(uid: selectedInputUID)
            let nextInputName = nextInputs.first { $0.id == deviceID }?.name ?? "연결된 입력 없음"
            if activeInputName != nextInputName { activeInputName = nextInputName }
            var nextDeviceError: String? = nil
            if !systemAudioOnly && !selectedInputUID.isEmpty && !nextInputs.contains(where: { $0.uid == selectedInputUID }) {
                if listening {
                    missingInputDevicePolls += 1
                    // Tolerate a single 3s poll miss during Bluetooth HFP/A2DP profile switches before stopping capture.
                    if missingInputDevicePolls >= 2 {
                        stop()
                        nextDeviceError = "선택한 입력 디바이스의 연결이 끊겼습니다. 다른 장치를 선택해주세요."
                    }
                } else {
                    missingInputDevicePolls = 0
                    nextDeviceError = "이전에 선택한 마이크가 연결되어 있지 않습니다. 듣기를 시작하면 시스템 기본 입력으로 자동 전환됩니다."
                }
            } else {
                missingInputDevicePolls = 0
            }
            if deviceError != nextDeviceError { deviceError = nextDeviceError }
        } catch {
            let nextErr = systemAudioOnly ? nil : error.localizedDescription
            if deviceError != nextErr { deviceError = nextErr }
        }
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
            let nextOutputs = try AudioOutputDevices.list()
            if outputDevices != nextOutputs { outputDevices = nextOutputs }
            let current = try AudioOutputDevices.current()
            let device = nextOutputs.first { $0.id == current }
            let nextUID = device?.uid ?? ""
            if selectedOutputUID != nextUID { selectedOutputUID = nextUID }
            let nextName = device?.name ?? "사용 가능한 출력 장치 없음"
            if activeOutputName != nextName { activeOutputName = nextName }
            if outputDeviceError != nil { outputDeviceError = nil }
        } catch {
            let err = error.localizedDescription
            if outputDeviceError != err { outputDeviceError = err }
        }
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
        pausePresentationTimer()
        lastKeywordAttempt = .distantPast
        resumeReading()
        selectedLiveBlockID = nil
        stop()
        let item = Conversation()
        conversations.insert(item, at: 0)
        selectedID = item.id
        liveSTT.clear()
        lastContext = ""
        detectedSTTLanguage = nil
        detectedLanguageConfidence = nil
        recentDetectedLanguages = []
        translationPreview = nil
        save()
        if autoStart && autoStartListeningOnNewConversation {
            Task { [weak self] in await self?.start() }
        }
    }
    func select(_ id: UUID) {
        pausePresentationTimer()
        lastKeywordAttempt = .distantPast
        resumeReading()
        selectedLiveBlockID = nil
        stop()
        translationPreview = nil
        liveSTT.clear()
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
        let previous = conversations[index].transcript
        guard previous != text else { return }
        lastTranscriptChange = Date()
        if isAutoDetectLanguage {
            let sampleText = text.count > 240 ? String(text.suffix(240)) : text
            if let detected = LanguageCatalog.detectLanguageDetailed(for: sampleText, preferredCodes: autoLanguagePrefs.preferredCodes) {
                recordDetectedLanguage(detected)
            }
        }
        conversations[index].transcriptSpans = RecentActivity.update(old: previous, new: text,
                                                                      spans: conversations[index].transcriptSpans ?? [], at: Date())
        conversations[index].transcript = text
        if conversations[index].presentation != nil {
            syncPresentationChecklist(with: text, at: index)
        }
        if followLive, let selectedLiveBlockID, !(conversations[index].transcriptSpans ?? []).contains(where: { $0.id == selectedLiveBlockID }) { self.selectedLiveBlockID = nil }
        if conversations[index].title == "새 대화", text.count > 5 { conversations[index].title = String(text.prefix(24)) }
        scheduleSave()
        scheduleTranslation()
        if !simpleFastMode {
            scheduleResponse()
            summaryDebounce?.cancel()
            summaryDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.refreshSummaries()
            }
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
