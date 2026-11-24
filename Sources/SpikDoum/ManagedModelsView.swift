import SwiftUI
import AppKit

struct ManagedModelsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var manager: ManagedModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var removing: ManagedModel?
    @State private var working: Set<ManagedRole> = []
    @State private var selectedTab = "models"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("자체 모델 · 서버 관리").font(.title2.bold())
                Spacer()
                Button("모델 폴더 열기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: manager.store.root.path) }
                Button("완료") { dismiss() }
            }
            Text("모델만 다운로드하면 외부 Python·Ollama 설치 없이 실행합니다. 다운로드 이후 STT와 번역은 이 Mac에서 처리합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("관리 화면", selection: $selectedTab) { Text("모델 다운로드 · 적용").tag("models"); Text("서버 모니터 · 로그").tag("servers") }.pickerStyle(.segmented)
            if let error = manager.lastError {
                HStack { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled); Spacer(); Button("닫기") { manager.lastError = nil } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedTab == "models" {
                        ForEach(ManagedRole.allCases) { role in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(role.title + " 모델").font(.headline)
                                ForEach(ManagedModelCatalog.all.filter { $0.role == role }) { item in modelRow(item) }
                            }
                        }
                        Text("다운로드는 Hugging Face의 고정된 모델 버전을 사용하고 용량과 SHA-256을 확인합니다. 다운로드한 모델은 앱을 업데이트해도 보관됩니다. 작은 번역 모델은 표현의 정확도에 한계가 있으므로 중요한 내용은 원문과 함께 확인하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(ManagedRole.allCases) { role in serverCard(role) }
                    }
                }.padding(4)
            }
        }.padding(22).frame(width: 860, height: 700)
        .alert("모델 파일을 삭제할까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("취소", role: .cancel) { removing = nil }
            Button("모델 삭제", role: .destructive) { if let item = removing { Task { await manager.remove(item) } }; removing = nil }
        } message: { Text("다운로드한 모델 파일만 삭제합니다. 대화 기록은 유지됩니다. 필요한 경우 다시 다운로드할 수 있습니다.") }
    }
    private func inUse(_ role: ManagedRole) -> Bool {
        (model.listening || model.starting || model.finishingCapture) && (role == .stt ? model.settings.stt == .managed : model.settings.translation == .managed)
    }
    private func modelRow(_ item: ManagedModel) -> some View {
        let installed = manager.installed.contains(item.id)
        let chosen = manager.selected(item.role)?.id == item.id
        let applied = chosen && (item.role == .stt ? model.settings.stt == .managed : model.settings.translation == .managed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(item.name).font(.headline); if applied { Text("적용됨").font(.caption.bold()).foregroundStyle(.green) } }
                    Text(item.sizeLabel + " · " + item.note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("출처", destination: item.sourceURL).font(.caption)
                if manager.transfers[item.id] != nil { Button("다운로드 취소") { manager.cancelDownload(item.id) } }
                else if installed {
                    Button(applied ? "다시 적용" : "적용") { apply(item) }.disabled(model.listening || model.starting || working.contains(item.role))
                    Button { removing = item } label: { Image(systemName: "trash") }.help("모델 파일 삭제")
                        .disabled(inUse(item.role) || working.contains(item.role))
                } else {
                    Button("다운로드") { Task { do { try await manager.download(item) } catch {} } }.buttonStyle(.borderedProminent)
                }
            }
            if let transfer = manager.transfers[item.id] {
                ProgressView(value: transfer.progress)
                Text("\(transfer.phase) · \(Int(transfer.progress * 100))%").font(.caption).monospacedDigit()
            } else { Text(installed ? "다운로드 완료 · 검증됨" : "다운로드되지 않음").font(.caption2).foregroundStyle(.secondary) }
        }.padding(14).background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
    private func apply(_ item: ManagedModel) {
        working.insert(item.role)
        Task {
            defer { working.remove(item.role) }
            await manager.select(item)
            if item.role == .stt { model.settings.stt = .managed } else { model.settings.translation = .managed }
            do { try await manager.ensureReady(item.role) } catch { manager.lastError = error.localizedDescription }
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
            if inUse(role) { Text("현재 듣기에서 사용 중입니다. 중지·재시작·모델 변경은 듣기를 중지한 뒤 사용할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
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
