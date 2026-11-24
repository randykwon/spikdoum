import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ManagedModelsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var manager: ManagedModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var removing: ManagedModel?
    @State private var working: Set<ManagedRole> = []
    @State private var selectedTab = "models"
    @State private var roleFilter = "all"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("자체 모델 · 서버 관리").font(.title2.bold())
                Spacer()
                Button("모델 폴더 열기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: manager.store.root.path) }
                Button("완료") { dismiss() }
            }
            Text("모델만 다운로드하거나 로컬 .bin/.gguf 파일을 추가하면 외부 Python·Ollama 설치 없이 이 Mac에서 바로 실행합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("관리 화면", selection: $selectedTab) { Text("모델 다운로드 · 적용").tag("models"); Text("서버 모니터 · 로그").tag("servers") }.pickerStyle(.segmented)
            if let error = manager.lastError {
                HStack { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled); Spacer(); Button("닫기") { manager.lastError = nil } }
            }
            if selectedTab == "models" {
                HStack(spacing: 10) {
                    Picker("종류", selection: $roleFilter) {
                        Text("전체 (\(manager.allModels.count))").tag("all")
                        Text("STT 모델 (\(manager.models(for: .stt).count))").tag(ManagedRole.stt.rawValue)
                        Text("번역 모델 (\(manager.models(for: .translation).count))").tag(ManagedRole.translation.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    Spacer()
                    Text("설치됨 \(manager.installed.count)개").font(.caption).foregroundStyle(.secondary)
                    Button { importCustomModel(role: .stt) } label: { Label("로컬 STT (.bin)", systemImage: "plus") }
                        .controlSize(.small)
                        .help("직접 내려받은 Whisper GGML .bin 모델 파일 추가")
                    Button { importCustomModel(role: .translation) } label: { Label("로컬 번역 (.gguf)", systemImage: "plus") }
                        .controlSize(.small)
                        .help("직접 내려받은 llama.cpp .gguf 번역 모델 파일 추가")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedTab == "models" {
                        let visibleRoles = ManagedRole.allCases.filter { roleFilter == "all" || roleFilter == $0.rawValue }
                        ForEach(visibleRoles) { role in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(role.title + " 모델").font(.headline)
                                    Text(role == .stt ? "Whisper.cpp · Metal GPU" : "llama.cpp · Metal GPU")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(manager.models(for: role)) { item in modelRow(item) }
                            }
                        }
                        Text("다운로드는 Hugging Face의 고정된 모델 버전을 사용하고 용량과 SHA-256을 검증합니다. 다운로드하거나 추가한 모델은 앱을 업데이트해도 보관됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(ManagedRole.allCases) { role in serverCard(role) }
                    }
                }.padding(4)
            }
        }.padding(22).frame(width: 900, height: 740)
        .alert("모델 파일을 삭제할까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("취소", role: .cancel) { removing = nil }
            Button("모델 삭제", role: .destructive) { if let item = removing { Task { await manager.remove(item) } }; removing = nil }
        } message: { Text("다운로드하거나 추가한 모델 파일만 삭제합니다. 대화 기록은 유지됩니다.") }
    }

    private func importCustomModel(role: ManagedRole) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = role == .stt ? "로컬 Whisper STT 모델(.bin) 선택" : "로컬 GGUF 번역 모델(.gguf) 선택"
        if let type = UTType(filenameExtension: role.customFileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try manager.importCustomModel(from: url, role: role)
            manager.lastError = nil
            if !model.starting {
                apply(added)
            }
        } catch {
            manager.lastError = error.localizedDescription
        }
    }

    private func inUse(_ role: ManagedRole) -> Bool {
        (model.listening || model.starting || model.finishingCapture) && (role == .stt ? model.settings.stt == .managed : model.settings.translation == .managed)
    }

    private func isActiveInUse(_ item: ManagedModel) -> Bool {
        inUse(item.role) && manager.selected(item.role)?.id == item.id
    }

    private func modelRow(_ item: ManagedModel) -> some View {
        let installed = manager.installed.contains(item.id)
        let chosen = manager.selected(item.role)?.id == item.id
        let applied = chosen && (item.role == .stt ? model.settings.stt == .managed : model.settings.translation == .managed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.headline)
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(item.isCustom ? Color.purple.opacity(0.16) : Color.blue.opacity(0.16), in: Capsule())
                                .foregroundStyle(item.isCustom ? .purple : .blue)
                        }
                        if applied {
                            Text("적용됨").font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                    Text(item.sizeLabel + " · " + item.note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let sourceURL = item.sourceURL {
                    Link("출처", destination: sourceURL).font(.caption)
                }
                if manager.transfers[item.id] != nil {
                    Button("다운로드 취소") { manager.cancelDownload(item.id) }
                } else if installed {
                    Button(applied ? "다시 적용" : "적용") { apply(item) }.disabled(model.starting || working.contains(item.role))
                    Button { removing = item } label: { Image(systemName: "trash") }.help("모델 파일 삭제")
                        .disabled(isActiveInUse(item) || working.contains(item.role))
                } else {
                    Button("다운로드") { Task { do { try await manager.download(item) } catch {} } }.buttonStyle(.borderedProminent)
                }
            }
            if let transfer = manager.transfers[item.id] {
                ProgressView(value: transfer.progress)
                Text("\(transfer.phase) · \(Int(transfer.progress * 100))%").font(.caption).monospacedDigit()
            } else {
                Text(installed ? (item.isCustom ? "로컬 파일 추가됨" : "다운로드 완료 · 검증됨") : "다운로드되지 않음")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func apply(_ item: ManagedModel) {
        working.insert(item.role)
        Task {
            defer { working.remove(item.role) }
            let wasListening = model.listening
            if item.role == .stt && wasListening {
                model.restartingForSettingsChange = true
                model.stop()
            }
            await manager.select(item)
            if item.role == .stt {
                model.settings.stt = .managed
            } else {
                model.settings.translation = .managed
            }
            do {
                try await manager.ensureReady(item.role)
                if item.role == .stt && wasListening {
                    await model.start()
                    model.restartingForSettingsChange = false
                } else if item.role == .translation {
                    model.reloadTranslationEngineAfterSettingsChange()
                }
            } catch {
                model.restartingForSettingsChange = false
                manager.lastError = error.localizedDescription
            }
        }
    }

    private func serverCard(_ role: ManagedRole) -> some View {
        let status = manager.servers[role] ?? ManagedServerStatus()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(role.title + " 서버", systemImage: "server.rack").font(.headline)
                Text(status.phase.rawValue).foregroundStyle(status.phase == .ready ? Color.green : .secondary)
                Spacer()
                Button("시작") { serverAction(role, restart: false) }
                    .disabled(working.contains(role) || status.phase == .starting || status.phase == .ready || status.phase == .stopping)
                Button("재시작") { serverAction(role, restart: true) }.disabled(inUse(role) || working.contains(role) || status.phase == .stopping)
                Button("중지") { Task { await manager.stop(role) } }.disabled(inUse(role) || status.pid == nil || status.phase == .stopping)
            }
            Text("모델: \(manager.selected(role)?.name ?? "미선택") · \(role.baseURL.absoluteString)").font(.caption).textSelection(.enabled)
            HStack(spacing: 18) {
                Text("PID \(status.pid.map(String.init) ?? "—")")
                Text(String(format: "CPU %.1f%%", status.cpu))
                Text(String(format: "메모리 %.0f MB", status.memoryMB)).help("프로세스 RSS입니다. GPU 모델 할당량은 별도입니다.")
                Text("처리 \(status.requests)회")
                if let latency = status.lastLatencyMS { Text("최근 \(latency)ms") }
            }.font(.caption).monospacedDigit()
            if let started = status.startedAt { Text("시작: \(started.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary) }
            if let error = status.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if inUse(role) { Text("현재 듣기에서 사용 중입니다. 다른 모델을 ‘적용’하면 자동으로 전환·재연결됩니다.").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("서버 로그 · 최근 24,000자") {
                ScrollView {
                    Text(manager.logs[role].flatMap { $0.isEmpty ? nil : $0 } ?? "서버를 시작하면 로그가 표시됩니다.")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }.font(.caption)
        }.padding(14).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func serverAction(_ role: ManagedRole, restart: Bool) {
        working.insert(role)
        Task {
            defer { working.remove(role) }
            do { if restart { try await manager.restart(role) } else { try await manager.ensureReady(role) } }
            catch { manager.lastError = error.localizedDescription }
        }
    }
}
