import SwiftUI

struct QuickAudioSourceMenu: View {
    @ObservedObject var model: AppModel
    var compact: Bool = false

    private var tintColor: Color {
        if model.micMuted && model.audioInputMode != .systemOnly { return .red }
        switch model.audioInputMode {
        case .micAndSystem: return .teal
        case .systemOnly: return .secondary
        case .micOnly: return .blue
        }
    }

    private var pillIcon: String {
        if model.micMuted && model.audioInputMode != .systemOnly { return "mic.slash.fill" }
        return model.audioInputMode.icon
    }

    private var pillLabel: String {
        if model.micMuted && model.audioInputMode != .systemOnly {
            return model.audioInputMode == .micAndSystem ? "마이크 음소거 + Mac" : "마이크 음소거됨"
        }
        return model.audioInputMode.shortLabel
    }

    var body: some View {
        Menu {
            if model.audioInputMode != .systemOnly {
                Button {
                    model.micMuted.toggle()
                } label: {
                    Label(
                        model.micMuted ? "내 마이크 음소거 해제 (⇧⌘M)" : "내 마이크 음소거 (⇧⌘M)",
                        systemImage: model.micMuted ? "mic.fill" : "mic.slash.fill"
                    )
                }
                Divider()
            }
            Section("음성 입력 소스 (내 목소리 · Mac 소리)") {
                Button {
                    model.setAudioInputMode(.micAndSystem)
                } label: {
                    if model.audioInputMode == .micAndSystem {
                        Label("내 마이크 + Mac 소리 함께 듣기 (양방향)", systemImage: "checkmark")
                    } else {
                        Label("내 마이크 + Mac 소리 함께 듣기 (양방향)", systemImage: "waveform.and.mic")
                    }
                }
                Button {
                    model.setAudioInputMode(.systemOnly)
                } label: {
                    if model.audioInputMode == .systemOnly {
                        Label("Mac 소리만 듣기 (마이크 끔)", systemImage: "checkmark")
                    } else {
                        Label("Mac 소리만 듣기 (마이크 끔)", systemImage: "speaker.wave.2")
                    }
                }
                Button {
                    model.setAudioInputMode(.micOnly)
                } label: {
                    if model.audioInputMode == .micOnly {
                        Label("내 마이크만 듣기", systemImage: "checkmark")
                    } else {
                        Label("내 마이크만 듣기", systemImage: "mic")
                    }
                }
            }

            if model.audioInputMode != .systemOnly {
                Divider()
                Section("내 마이크 인식 언어") {
                    Button {
                        model.micLanguageMode = .autoOrTarget
                    } label: {
                        let label = model.settings.stt == .apple
                            ? "내 번역 언어 (\(model.targetLanguageName))"
                            : "자동 감지 (한국어·외국어 자동 인식)"
                        if model.micLanguageMode == .autoOrTarget {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Label(label, systemImage: "sparkles")
                        }
                    }
                    Button {
                        model.micLanguageMode = .sameAsSTT
                    } label: {
                        let label = "상대 STT 언어와 동일 (\(model.sttLanguageBadge))"
                        if model.micLanguageMode == .sameAsSTT {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }

                if !model.inputDevices.isEmpty {
                    Divider()
                    Menu("마이크 장치 · \(model.activeInputName)") {
                        Button {
                            model.selectedInputUID = ""
                        } label: {
                            if model.selectedInputUID.isEmpty {
                                Label("시스템 기본 입력", systemImage: "checkmark")
                            } else {
                                Text("시스템 기본 입력")
                            }
                        }
                        ForEach(model.inputDevices) { device in
                            Button {
                                model.selectedInputUID = device.uid
                            } label: {
                                if model.selectedInputUID == device.uid {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: pillIcon)
                    .font(.caption2)
                Text(pillLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(tintColor)
            .background(tintColor.opacity((model.micMuted || model.audioInputMode == .micAndSystem) ? 0.14 : 0.10), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.starting)
        .help("내 마이크 목소리와 Mac 재생음 동시 캡처 설정 (헤드셋/이어폰 사용 시 가장 깔끔하게 분리됩니다)")
    }
}

struct QuickSpeedQualityMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var parakeet: ParakeetModelManager
    @ObservedObject var appleAssets: AppleSpeechAssetManager
    var compact: Bool = false

    init(model: AppModel, compact: Bool = false) {
        self.model = model
        self.parakeet = model.parakeetModels
        self.appleAssets = model.appleSpeechAssets
        self.compact = compact
    }

    private var unifiedTier: SpeedQualityTier? {
        model.sttTier == model.translationTier ? model.sttTier : nil
    }

    private var pillLabel: String {
        if let tier = unifiedTier {
            return tier.shortBadge
        }
        return "STT \(model.sttTier.rawValue) · 번역 \(model.translationTier.rawValue)"
    }

    private var pillColor: Color {
        (unifiedTier ?? model.sttTier).tintColor
    }

    private var pillIcon: String {
        (unifiedTier ?? model.sttTier).icon
    }

    private var isBusy: Bool {
        parakeet.isPreparing || appleAssets.installingLocale != nil
    }

    var body: some View {
        Menu {
            Section("추천 아키텍처 (실시간 고속 + 지능형 LLM)") {
                Button {
                    Task { await model.applyHybridFastPreset() }
                } label: {
                    let bestName = model.managedModels.bestInstalledLLMModel()?.name
                        .replacingOccurrences(of: " Instruct", with: "")
                        .replacingOccurrences(of: " · Q4", with: "") ?? "로컬 LLM"
                    let title = "초고속 하이브리드 (STT 초신속 · Apple 번역 · \(bestName) 코치)"
                    if model.isHybridFastPresetActive {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Label(title, systemImage: "bolt.badge.a.fill")
                    }
                }
            }

            Divider()

            Section("STT · 번역 5단계 통합 전환 (속도 ↔ 정확도)") {
                ForEach(SpeedQualityTier.allCases) { tier in
                    let isSelected = model.sttTier == tier && model.translationTier == tier
                    Button {
                        Task { await model.applySpeedQualityTier(tier) }
                    } label: {
                        let label = "\(tier.rawValue)단계 · \(tier.title)"
                        if isSelected {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Label(label, systemImage: tier.icon)
                        }
                    }
                }
            }

            Divider()

            Menu("STT 5단계만 변경 · 현재 \(model.sttTier.shortBadge)") {
                ForEach(SpeedQualityTier.allCases) { tier in
                    Button {
                        Task { await model.applySTTTier(tier) }
                    } label: {
                        let text = "\(tier.rawValue). \(tier.title) — \(tier.sttSummary)"
                        if model.sttTier == tier {
                            Label(text, systemImage: "checkmark")
                        } else {
                            Text(text)
                        }
                    }
                }
            }

            Menu("번역 5단계만 변경 · 현재 \(model.translationTier.shortBadge)") {
                ForEach(SpeedQualityTier.allCases) { tier in
                    Button {
                        Task { await model.applyTranslationTier(tier) }
                    } label: {
                        let text = "\(tier.rawValue). \(tier.title) — \(tier.translationSummary)"
                        if model.translationTier == tier {
                            Label(text, systemImage: "checkmark")
                        } else {
                            Text(text)
                        }
                    }
                }
            }

            Divider()

            Section("초저지연 가속기 (Apple M5 ANE · macOS 26)") {
                Button {
                    Task {
                        do {
                            _ = try await parakeet.ensureReady()
                            model.presetNotice = "Parakeet TDT v3 (M5 ANE) 준비 완료 · 영어/유럽어 1~2단계에서 자동 사용됩니다."
                        } catch {
                            model.message = error.localizedDescription
                        }
                    }
                } label: {
                    if parakeet.isPreparing {
                        Label("Parakeet ANE 다운로드 · 컴파일 중…", systemImage: "arrow.down.circle")
                    } else if parakeet.isLoaded || parakeet.isCachedOnDisk {
                        let msText = parakeet.lastLatencyMS.map { " · 최근 \($0)ms" } ?? ""
                        Label("Parakeet TDT v3 (ANE 준비됨\(msText))", systemImage: "checkmark.seal.fill")
                    } else {
                        Label("Parakeet TDT v3 (ANE) 설치 (~600MB · 영어/유럽어 초고속)", systemImage: "bolt.circle")
                    }
                }
                .disabled(parakeet.isPreparing)

                Menu("Apple 실시간 스트리밍 에셋 (macOS 26)") {
                    ForEach(AppleSpeechAssetManager.trackedLocales, id: \.self) { code in
                        let name = LanguageCatalog.displayName(for: code, in: model.uiLanguage)
                        let installed = appleAssets.isInstalled(for: code)
                        let installing = appleAssets.installingLocale == code
                        Button {
                            Task {
                                await appleAssets.installAsset(for: code)
                                if appleAssets.isInstalled(for: code) {
                                    model.presetNotice = "Apple 실시간 스트리밍 에셋(\(name)) 설치 완료 · Apple STT가 초저지연 스트리밍으로 동작합니다."
                                } else if let err = appleAssets.lastError {
                                    model.message = err
                                }
                            }
                        } label: {
                            if installed {
                                Label("\(name) · 설치됨 (실시간 스트리밍 활성)", systemImage: "checkmark")
                            } else if installing {
                                Label("\(name) · 설치 중 (\(Int(appleAssets.installProgress * 100))%)…", systemImage: "arrow.down.circle")
                            } else {
                                Label("\(name) · 실시간 에셋 설치", systemImage: "icloud.and.arrow.down")
                            }
                        }
                        .disabled(installed || appleAssets.installingLocale != nil)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: pillIcon)
                        .font(.caption2)
                }
                Text(pillLabel)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillColor)
            .background(pillColor.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.starting)
        .help("STT · 번역 5단계 속도/정확도 전환 (1 초신속 ~ 5 최고 정확 · ⌥⌘1~5)\nSTT: \(model.activeSTTModelLabel) · 번역: \(model.activeTranslationModelLabel)")
    }
}

struct QuickSTTModelMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var managed: ManagedModelManager
    var compact: Bool = false
    var onOpenManager: (() -> Void)? = nil

    init(model: AppModel, compact: Bool = false, onOpenManager: (() -> Void)? = nil) {
        self.model = model
        self.managed = model.managedModels
        self.compact = compact
        self.onOpenManager = onOpenManager
    }

    private var installedSTT: [ManagedModel] {
        managed.models(for: .stt).filter { managed.installed.contains($0.id) }
    }

    private var downloadableSTT: [ManagedModel] {
        managed.models(for: .stt).filter { !managed.installed.contains($0.id) && !$0.isCustom }
    }

    private var isDownloadingSTT: Bool {
        managed.models(for: .stt).contains { managed.transfers[$0.id] != nil }
    }

    var body: some View {
        Menu {
            Section("STT 엔진 · 모델 빠른 변경") {
                Button {
                    Task { await model.switchSTTEngine(.apple) }
                } label: {
                    if model.settings.stt == .apple {
                        Label("Apple 음성 인식 (기기 내)", systemImage: "checkmark")
                    } else {
                        Label("Apple 음성 인식 (기기 내)", systemImage: "apple.logo")
                    }
                }
                Button {
                    Task { await model.switchSTTEngine(.parakeet) }
                } label: {
                    let badge = model.parakeetModels.isCachedOnDisk ? "준비됨" : "첫 실행 시 ~600MB"
                    if model.settings.stt == .parakeet {
                        Label("Parakeet TDT v3 · M5 ANE 초저지연 (\(badge))", systemImage: "checkmark")
                    } else {
                        Label("Parakeet TDT v3 · M5 ANE 초저지연 (\(badge))", systemImage: "bolt.fill")
                    }
                }
            }

            if !installedSTT.isEmpty {
                Section("설치된 자체 Whisper 모델") {
                    ForEach(installedSTT) { item in
                        let isActive = model.settings.stt == .managed && managed.selectedSTT == item.id
                        Button {
                            Task { await model.switchSTTEngine(.managed, managedModelID: item.id) }
                        } label: {
                            let label = "\(item.name) (\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)))"
                            if isActive {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }

            if !downloadableSTT.isEmpty {
                Menu("미설치 Whisper 모델 다운로드") {
                    ForEach(downloadableSTT) { item in
                        let transferring = managed.transfers[item.id] != nil
                        Button {
                            Task {
                                do {
                                    try await managed.download(item)
                                    await model.switchSTTEngine(.managed, managedModelID: item.id)
                                } catch {
                                    model.message = error.localizedDescription
                                }
                            }
                        } label: {
                            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                            if transferring {
                                Label("\(item.name) 다운로드 중…", systemImage: "arrow.down.circle")
                            } else {
                                Text("\(item.name) · \(size)")
                            }
                        }
                        .disabled(transferring)
                    }
                }
            }

            Section("클라우드") {
                Button {
                    Task { await model.switchSTTEngine(.deepgram) }
                } label: {
                    if model.settings.stt == .deepgram {
                        Label("Deepgram (클라우드)", systemImage: "checkmark")
                    } else {
                        Label("Deepgram (클라우드)", systemImage: "cloud")
                    }
                }
            }

            if let onOpenManager {
                Divider()
                Button {
                    onOpenManager()
                } label: {
                    Label("모델 다운로드 · 서버 관리…", systemImage: "server.rack")
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isDownloadingSTT {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.settings.stt == .parakeet ? "bolt.fill" : model.settings.stt == .managed ? "cpu" : model.settings.stt == .deepgram ? "cloud" : "waveform")
                        .font(.caption2)
                }
                Text(model.activeSTTModelLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.blue)
            .background(Color.blue.opacity(0.11), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.starting)
        .help("STT 엔진 및 모델 빠른 변경 (현재: \(model.activeSTTModelLabel))")
    }
}

struct QuickTranslationModelMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var managed: ManagedModelManager
    var compact: Bool = false
    var onOpenManager: (() -> Void)? = nil

    init(model: AppModel, compact: Bool = false, onOpenManager: (() -> Void)? = nil) {
        self.model = model
        self.managed = model.managedModels
        self.compact = compact
        self.onOpenManager = onOpenManager
    }

    private var installedTranslation: [ManagedModel] {
        managed.models(for: .translation).filter { managed.installed.contains($0.id) }
    }

    private var downloadableTranslation: [ManagedModel] {
        managed.models(for: .translation).filter { !managed.installed.contains($0.id) && !$0.isCustom }
    }

    private var isDownloadingTranslation: Bool {
        managed.models(for: .translation).contains { managed.transfers[$0.id] != nil }
    }

    var body: some View {
        Menu {
            Section("번역 엔진 · 모델 빠른 변경") {
                Button {
                    Task { await model.switchTranslationEngine(.apple) }
                } label: {
                    if model.settings.translation == .apple {
                        Label("Apple 번역 (기기 내 초저지연)", systemImage: "checkmark")
                    } else {
                        Label("Apple 번역 (기기 내 초저지연)", systemImage: "apple.logo")
                    }
                }
            }

            if !installedTranslation.isEmpty {
                Section("설치된 자체 번역 모델") {
                    ForEach(installedTranslation) { item in
                        let isActive = model.settings.translation == .managed && managed.selectedTranslation == item.id
                        Button {
                            Task { await model.switchTranslationEngine(.managed, managedModelID: item.id) }
                        } label: {
                            let label = "\(item.name) (\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)))"
                            if isActive {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }

            if !downloadableTranslation.isEmpty {
                Menu("미설치 번역 모델 다운로드") {
                    ForEach(downloadableTranslation) { item in
                        let transferring = managed.transfers[item.id] != nil
                        Button {
                            Task {
                                do {
                                    try await managed.download(item)
                                    await model.switchTranslationEngine(.managed, managedModelID: item.id)
                                } catch {
                                    model.message = error.localizedDescription
                                }
                            }
                        } label: {
                            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                            if transferring {
                                Label("\(item.name) 다운로드 중…", systemImage: "arrow.down.circle")
                            } else {
                                Text("\(item.name) · \(size)")
                            }
                        }
                        .disabled(transferring)
                    }
                }
            }

            Section("외부 · 클라우드") {
                Button {
                    Task { await model.switchTranslationEngine(.local) }
                } label: {
                    if model.settings.translation == .local {
                        Label("로컬 번역 서버 (HTTP)", systemImage: "checkmark")
                    } else {
                        Label("로컬 번역 서버 (HTTP)", systemImage: "network")
                    }
                }
                Button {
                    Task { await model.switchTranslationEngine(.azure) }
                } label: {
                    if model.settings.translation == .azure {
                        Label("Azure 번역 (클라우드)", systemImage: "checkmark")
                    } else {
                        Label("Azure 번역 (클라우드)", systemImage: "cloud")
                    }
                }
            }

            if let onOpenManager {
                Divider()
                Button {
                    onOpenManager()
                } label: {
                    Label("모델 다운로드 · 서버 관리…", systemImage: "server.rack")
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isDownloadingTranslation {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.settings.translation == .managed ? "sparkles" : model.settings.translation == .apple ? "character.bubble" : "network")
                        .font(.caption2)
                }
                Text(model.activeTranslationModelLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.purple)
            .background(Color.purple.opacity(0.11), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("번역 엔진 및 모델 빠른 변경 (현재: \(model.activeTranslationModelLabel))")
    }
}

struct QuickLLMModelMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var managed: ManagedModelManager
    var compact: Bool = false
    var onOpenSettings: (() -> Void)? = nil
    var onOpenManager: (() -> Void)? = nil

    init(model: AppModel, compact: Bool = false, onOpenSettings: (() -> Void)? = nil, onOpenManager: (() -> Void)? = nil) {
        self.model = model
        self.managed = model.managedModels
        self.compact = compact
        self.onOpenSettings = onOpenSettings
        self.onOpenManager = onOpenManager
    }

    private var installedGGUF: [ManagedModel] {
        managed.models(for: .llm).filter { managed.installed.contains($0.id) }
    }

    private var downloadableGGUF: [ManagedModel] {
        managed.models(for: .llm).filter { !managed.installed.contains($0.id) && !$0.isCustom }
    }

    private var isDownloadingLLM: Bool {
        managed.models(for: .llm).contains { managed.transfers[$0.id] != nil }
    }

    private var hasSplitRouting: Bool {
        model.settings.keywordLLM != .followMain || model.settings.summaryLLM != .followMain
    }

    var body: some View {
        Menu {
            Section("추천 하이브리드 구성") {
                Button {
                    Task { await model.applyHybridFastPreset() }
                } label: {
                    if model.isHybridFastPresetActive {
                        Label("초고속 하이브리드 활성 (STT 초신속 + Apple 번역 + 로컬 LLM)", systemImage: "checkmark")
                    } else {
                        Label("초고속 하이브리드 적용 (STT 초신속 + Apple 번역 + 로컬 LLM)", systemImage: "bolt.badge.a.fill")
                    }
                }
            }

            Divider()

            if !installedGGUF.isEmpty {
                Section("설치된 자체 로컬 LLM (코치 · 요약 · 키워드)") {
                    ForEach(installedGGUF) { item in
                        let isActive = model.settings.llm == .managed && managed.selectedLLM == item.id
                        Button {
                            Task { await model.switchLLMEngine(.managed, managedModelID: item.id) }
                        } label: {
                            let label = "\(item.name) (\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)))"
                            if isActive {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }

            if !downloadableGGUF.isEmpty {
                Menu("고성능 로컬 LLM 모델 다운로드") {
                    ForEach(downloadableGGUF) { item in
                        let transferring = managed.transfers[item.id] != nil
                        Button {
                            Task {
                                do {
                                    try await managed.download(item)
                                    await model.switchLLMEngine(.managed, managedModelID: item.id)
                                } catch {
                                    model.message = error.localizedDescription
                                }
                            }
                        } label: {
                            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                            if transferring {
                                Label("\(item.name) 다운로드 중…", systemImage: "arrow.down.circle")
                            } else {
                                Text("\(item.name) · \(size)")
                            }
                        }
                        .disabled(transferring)
                    }
                }
            }

            Section("기본 · 클라우드 · 외부 LLM") {
                Button {
                    Task { await model.switchLLMEngine(.apple) }
                } label: {
                    if model.settings.llm == .apple {
                        Label("Apple Intelligence (기기 내 기본)", systemImage: "checkmark")
                    } else {
                        Label("Apple Intelligence (기기 내 기본)", systemImage: "apple.logo")
                    }
                }
                Button {
                    Task { await model.switchLLMEngine(.openAI) }
                } label: {
                    let label = "OpenAI API (\(model.settings.cloudModel))"
                    if model.settings.llm == .openAI {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Label(label, systemImage: "cloud")
                    }
                }
                Button {
                    Task { await model.switchLLMEngine(.compatible) }
                } label: {
                    let label = "외부 로컬 서버 (\(model.settings.serverModel))"
                    if model.settings.llm == .compatible {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Label(label, systemImage: "network")
                    }
                }
            }

            Divider()

            Menu("작업별 LLM 분리 · \(hasSplitRouting ? "분리 중" : "통합")") {
                Section("핵심 키워드 추출 엔진 (경량 분리 추천)") {
                    ForEach(LLMTaskOverride.allCases) { option in
                        Button {
                            model.settings.keywordLLM = option
                            model.presetNotice = "키워드 추출 엔진: \(option.title)"
                        } label: {
                            if model.settings.keywordLLM == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
                Divider()
                Section("대화 요약 · 스크립트 정리 엔진") {
                    ForEach(LLMTaskOverride.allCases) { option in
                        Button {
                            model.settings.summaryLLM = option
                            model.presetNotice = "대화 요약·스크립트 엔진: \(option.title)"
                        } label: {
                            if model.settings.summaryLLM == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }

            if onOpenSettings != nil || onOpenManager != nil {
                Divider()
                if let onOpenManager {
                    Button { onOpenManager() } label: {
                        Label("로컬 LLM 모델 다운로드 · 서버 모니터…", systemImage: "server.rack")
                    }
                }
                if let onOpenSettings {
                    Button { onOpenSettings() } label: {
                        Label("API 키 · 외부 LLM 서버 설정…", systemImage: "gearshape")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isDownloadingLLM {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.settings.llm == .managed ? "brain" : model.settings.llm == .openAI ? "cloud" : model.settings.llm == .compatible ? "network" : "sparkles")
                        .font(.caption2)
                }
                Text("코치: \(model.activeLLMModelLabel)\(hasSplitRouting ? "·분리" : "")")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.green)
            .background(Color.green.opacity(0.11), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("대화 코치 · 요약 · 키워드 LLM 엔진 빠른 변경 (현재: \(model.activeLLMModelLabel))")
    }
}
