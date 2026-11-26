import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarTrayView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var loginStatusNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.listening ? Color.green : model.starting ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpikDoum").font(.headline)
                    Text(model.sttStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
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
                    Divider()
                    Menu(model.t("settings.targetLanguage")) {
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
                } label: {
                    Text("\(model.sttLanguageBadge) → \(model.targetLanguageName)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.starting)
            }

            HStack(spacing: 8) {
                Button {
                    if model.listening {
                        model.pauseListening()
                    } else {
                        Task { await model.start() }
                    }
                } label: {
                    Label(
                        model.finishingCapture ? model.t("action.finishingAudio") : model.starting ? model.t("action.preparingModel") : model.listening ? model.t("action.stopListening") : model.t("action.startListening"),
                        systemImage: model.listening ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.listening ? .red : .accentColor)
                .disabled(model.finishingCapture || model.starting || model.current == nil || model.current?.archivedAt != nil)

                Button {
                    model.newConversation(autoStart: true)
                    if !model.autoStartListeningOnNewConversation {
                        Task { await model.start() }
                    }
                    openMainWindow()
                } label: {
                    Label(model.t("action.newConversation"), systemImage: "plus")
                }
                .disabled(model.starting)
            }

            Toggle(isOn: $model.simpleFastMode) {
                Label("심플 패스트 모드 (STT · 번역 전용)", systemImage: model.simpleFastMode ? "bolt.fill" : "bolt")
                    .font(.caption)
                    .foregroundStyle(model.simpleFastMode ? Color.orange : Color.primary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack(spacing: 6) {
                QuickAudioSourceMenu(model: model, compact: true)
                QuickSTTModelMenu(model: model, compact: true)
                QuickTranslationModelMenu(model: model, compact: true)
                Spacer(minLength: 0)
            }

            if let error = model.message ?? model.deviceError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(model.message != nil ? .red : .orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(model.message != nil ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((model.message != nil ? Color.red : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            if let current = model.current {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(current.title).font(.caption.bold()).lineLimit(1)
                        Spacer()
                        if !current.transcript.isEmpty {
                            Text("\(current.transcript.count)자").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if let latestTranslation = current.translations?.last?.translated, !latestTranslation.isEmpty {
                        Text(latestTranslation)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    } else if let latestSpan = current.transcriptSpans?.last?.text, !latestSpan.isEmpty {
                        Text(latestSpan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("듣기를 시작하면 실시간 번역과 조언이 여기에 표시됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.t("tray.quickMode")).font(.caption2.bold()).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    presetButton(model.t("preset.youtube"), preset: .youtube)
                    presetButton("Meet", preset: .googleMeet)
                    presetButton("Zoom", preset: .zoom)
                    presetButton(model.t("preset.inPerson"), preset: .inPerson)
                }
                .disabled(model.starting)
                Text(model.captureSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openMainWindow()
                } label: {
                    Label(model.t("tray.openMain"), systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "coach")
                } label: {
                    Label(model.t("panel.coachWindow"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }

            let recent = model.conversations.filter { $0.archivedAt == nil }.prefix(3)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("tray.recent")).font(.caption2.bold()).foregroundStyle(.secondary)
                    ForEach(recent) { item in
                        Button {
                            model.select(item.id)
                            openMainWindow()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.id == model.selectedID ? "checkmark.circle.fill" : "bubble.left")
                                    .font(.caption2)
                                    .foregroundStyle(item.id == model.selectedID ? Color.accentColor : .secondary)
                                Text(item.title).font(.caption).lineLimit(1)
                                Spacer()
                                Text(item.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.starting)
                    }
                }
            }

            Divider()

            Toggle(model.t("tray.launchAtLogin"), isOn: Binding(
                get: { launchAtLogin },
                set: { toggleLaunchAtLogin($0) }
            ))
            .font(.caption)

            if let loginStatusNote {
                Text(loginStatusNote).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                Button(model.t("action.replay")) {
                    if let id = model.selectedID {
                        model.openReplay(id)
                        openMainWindow()
                    }
                }
                .controlSize(.small)
                .disabled(model.starting || model.current == nil)
                Spacer()
                Button(model.t("tray.quit"), role: .destructive) {
                    model.stop()
                    model.saveSynchronously()
                    model.managedModels.shutdown()
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func presetButton(_ title: String, preset: CapturePreset) -> some View {
        Button(title) {
            model.applyPreset(preset)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { window in
            window.canBecomeMain && window.title != "실시간 조언" && window.level == .normal
        }) {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            loginStatusNote = nil
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            loginStatusNote = "자동 실행 설정 실패: 앱을 응용 프로그램 폴더로 옮기거나 시스템 설정에서 허용해 주세요. (\(error.localizedDescription))"
        }
    }
}
