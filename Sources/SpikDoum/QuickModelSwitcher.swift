import SwiftUI

struct QuickAudioSourceMenu: View {
    @ObservedObject var model: AppModel
    var compact: Bool = false

    private var tintColor: Color {
        switch model.audioInputMode {
        case .micAndSystem: return .teal
        case .systemOnly: return .secondary
        case .micOnly: return .blue
        }
    }

    var body: some View {
        Menu {
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
                Image(systemName: model.audioInputMode.icon)
                    .font(.caption2)
                Text(model.audioInputMode.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .foregroundStyle(tintColor)
            .background(tintColor.opacity(model.audioInputMode == .micAndSystem ? 0.14 : 0.10), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.starting)
        .help("내 마이크 목소리와 Mac 재생음 동시 캡처 설정 (헤드셋/이어폰 사용 시 가장 깔끔하게 분리됩니다)")
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
                    Image(systemName: model.settings.stt == .managed ? "cpu" : model.settings.stt == .deepgram ? "cloud" : "waveform")
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
