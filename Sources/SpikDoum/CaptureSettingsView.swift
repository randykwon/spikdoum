import SwiftUI

struct CaptureOptionsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("settings.presets")).font(.headline)
            HStack {
                Button(model.t("preset.youtube")) { model.applyPreset(.youtube) }
                Menu("Google Meet") {
                    ForEach([MeetingAudioTarget.chrome, .safari, .edge, .firefox, .all], id: \.self) { browser in
                        Button(browser.title) { model.applyPreset(.googleMeet, browser: browser) }
                    }
                }
                Button("Zoom") { model.applyPreset(.zoom) }
                Button(model.t("preset.inPerson")) { model.applyPreset(.inPerson) }
            }.disabled(model.starting)
            if let notice = model.presetNotice { Text(notice).font(.caption).foregroundStyle(.blue) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Picker(model.t("settings.sttMode"), selection: Binding(
                            get: { model.isAutoDetectLanguage },
                            set: { model.setAutoDetectSTT($0) }
                        )) {
                            Text(model.t("stt.mode.auto")).tag(true)
                            Text(model.t("stt.mode.fixed")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .disabled(model.starting)

                        if !model.isAutoDetectLanguage {
                            Picker(model.t("settings.sourceLanguage"), selection: Binding(
                                get: { model.language },
                                set: { model.selectSTTLanguage($0) }
                            )) {
                                ForEach(LanguageCatalog.all) { lang in
                                    Text(lang.displayName(in: model.uiLanguage)).tag(lang.code)
                                }
                            }
                            .frame(minWidth: 180)
                            .disabled(model.starting)
                        } else {
                            Text(model.detectedSTTLanguage.map { "\(model.t("stt.mode.auto")) · \($0.displayName(in: model.uiLanguage))" } ?? "말하는 언어를 자동으로 감지합니다 (Whisper / Deepgram)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Picker(model.t("settings.targetLanguage"), selection: Binding(
                            get: { model.targetLanguage },
                            set: { model.selectTargetLanguage($0) }
                        )) {
                            ForEach(model.targetLanguages, id: \.0) { code, name in Text(name).tag(code) }
                        }.frame(minWidth: 210)
                        Picker(model.t("settings.uiLanguage"), selection: $model.interfaceLanguage) {
                            ForEach(AppInterfaceLanguage.allCases) { option in
                                Text(option.displayName(in: model.uiLanguage)).tag(option)
                            }
                        }.frame(minWidth: 210)
                    }
                    TextField(model.t("settings.goalPlaceholder"), text: $model.goal).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Picker("입력 디바이스", selection: $model.selectedInputUID) {
                        Text("시스템 기본 입력").tag("")
                        ForEach(model.inputDevices) { device in Text(device.name).tag(device.uid) }
                        if !model.selectedInputUID.isEmpty && !model.inputDevices.contains(where: { $0.uid == model.selectedInputUID }) {
                            Text("연결되지 않은 장치").tag(model.selectedInputUID)
                        }
                    }.disabled(model.starting)
                    Button { model.refreshInputDevices() } label: { Image(systemName: "arrow.clockwise") }.help("입력 장치 새로고침")
                    Text("이 앱에서 사용할 마이크를 선택하세요. 듣기 중 변경 시 자동 재연결됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("출력 디바이스", selection: Binding(get: { model.selectedOutputUID }, set: model.chooseOutputDevice)) {
                        if model.selectedOutputUID.isEmpty { Text("사용 가능한 출력 없음").tag("") }
                        ForEach(model.outputDevices) { device in Text(device.name).tag(device.uid) }
                    }.disabled(model.outputDevices.isEmpty || model.changingOutputDevice)
                    Button { model.refreshOutputDevices() } label: { Image(systemName: "arrow.clockwise") }.help("출력 장치 새로고침")
                    Text(model.changingOutputDevice ? "출력 장치 변경 중…" : "Mac 기본 출력을 변경합니다 · 다른 앱의 소리에도 영향").font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.outputDeviceError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Picker("통화 대상", selection: $model.meetingTarget) {
                        ForEach(MeetingAudioTarget.allCases, id: \.self) { target in Text(target.title).tag(target) }
                    }.disabled(model.starting)
                    Text("회의 앱과 동일한 마이크·스피커를 선택하세요.").font(.caption).foregroundStyle(.secondary)
                }
                if model.meetingTarget != .all && model.meetingTarget != .zoom {
                    Text("선택한 브라우저의 다른 탭 소리도 포함될 수 있습니다.").font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("통화 모드 · 마이크와 회의 상대방 소리 함께 듣기", isOn: $model.includeSystemAudio)
                    .font(.caption).disabled(model.starting)
                if !model.systemAudioOnly {
                    HStack(spacing: 10) {
                        Text("내 마이크 언어").font(.caption)
                        Picker("내 마이크 언어", selection: $model.micLanguageMode) {
                            Text(model.settings.stt == .apple ? "내 번역 언어 (\(model.targetLanguageName))" : "자동 감지 (권장)").tag(MicLanguageMode.autoOrTarget)
                            Text("상대 STT 언어와 동일 (\(model.sttLanguageBadge))").tag(MicLanguageMode.sameAsSTT)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .disabled(model.starting)
                    }
                }
                HStack {
                    Toggle("Mac 소리만 인식 · 마이크 사용 안 함", isOn: $model.systemAudioOnly).disabled(model.starting)
                    if model.includeSystemAudio || model.systemAudioOnly {
                        SystemAudioLevelBar(monitor: model.audioLevelMonitor)
                        Text("Mac 소리 입력").font(.caption)
                    }
                }.font(.caption)
                Toggle(model.t("settings.recordAudio"), isOn: $model.recordAudioForReplay)
                    .font(.caption).disabled(model.starting)
                Toggle(model.t("settings.autoStartNew"), isOn: $model.autoStartListeningOnNewConversation)
                    .font(.caption)
                Text(model.systemAudioOnly ? "Mac 재생음 전용 · 선택한 마이크의 연결 상태와 무관하게 동작합니다." : "입력: \(model.activeInputName) · \(model.permissionStatus)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
private struct SystemAudioLevelBar: View {
    @ObservedObject var monitor: AudioLevelMonitor
    var body: some View {
        ProgressView(value: monitor.level).frame(width: 80)
    }
}

struct CaptureSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.t("settings.captureTitle")).font(.title2.bold()); Spacer(); Button(model.t("action.done")) { dismiss() } }
            ScrollView { CaptureOptionsView(model: model).padding(4) }
        }.padding(24).frame(width: 660, height: 570)
    }
}
