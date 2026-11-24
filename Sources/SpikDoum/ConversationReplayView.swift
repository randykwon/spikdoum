import SwiftUI
import AppKit

struct ConversationReplayView: View {
    @ObservedObject var model: AppModel
    @StateObject private var controller: ConversationReplayController
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, conversation: Conversation) {
        self.model = model
        _controller = StateObject(wrappedValue: ConversationReplayController(conversation: conversation, recordingsRoot: model.recordingsRoot))
    }

    var body: some View {
        let snapshot = controller.currentSnapshot
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            transportBar
            if let note = controller.statusNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if !controller.timeline.markers.isEmpty {
                markerBar
            }
            Divider()
            HSplitView {
                replaySTTPanel(snapshot)
                    .frame(minWidth: 220)
                    .padding(.trailing, 8)
                replayTranslationPanel(snapshot)
                    .frame(minWidth: 230)
                    .padding(.horizontal, 8)
                replayAdvicePanel(snapshot)
                    .frame(minWidth: 220)
                    .padding(.horizontal, 8)
                replaySummaryAndScriptPanel(snapshot)
                    .frame(minWidth: 260)
                    .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: 1120, idealWidth: 1240, minHeight: 740, idealHeight: 820)
        .onDisappear { controller.stop() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.timeline.conversation.title).font(.title3.bold()).lineLimit(1)
                HStack(spacing: 8) {
                    Label(
                        controller.hasAudio
                            ? "음성 + 전체 기록 동기 재현 · 녹음 \(controller.timeline.clips.count)개"
                            : "타임라인 재현 (녹음된 음성 없음 · STT/번역/조언/요약/키워드 시점 재현)",
                        systemImage: controller.hasAudio ? "waveform.badge.magnifyingglass" : "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(controller.hasAudio ? .blue : .secondary)
                    Text("· 재생 시각 \(controller.currentDate, format: .dateTime.hour().minute().second())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if controller.hasAudio {
                Button(model.t("replay.openFolder")) {
                    let folder = RecordingStorage.conversationFolder(for: controller.timeline.conversation.id, root: model.recordingsRoot)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                }
            }
            Button(model.t("action.close")) {
                controller.stop()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var transportBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    controller.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("10초 뒤로")

                Button {
                    controller.togglePlay()
                } label: {
                    Label(controller.isPlaying ? model.t("replay.pause") : model.t("replay.play"), systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    controller.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .help("10초 앞으로")

                Text(formatDuration(controller.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.seek(to: $0) }
                    ),
                    in: 0...max(1, controller.timeline.duration)
                )

                Text(formatDuration(controller.timeline.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Picker("재생 속도", selection: $controller.playbackRate) {
                    Text("0.75×").tag(Float(0.75))
                    Text("1.0×").tag(Float(1.0))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("2.0×").tag(Float(2.0))
                }
                .labelsHidden()
                .frame(width: 74)

                Button {
                    controller.muted.toggle()
                } label: {
                    Image(systemName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .disabled(!controller.hasAudio)
                .help(controller.muted ? "음소거 해제" : "음소거")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var markerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("주요 시점").font(.caption2.bold()).foregroundStyle(.secondary)
                ForEach(controller.timeline.markers) { marker in
                    let active = abs(marker.offset - controller.currentTime) < 2.0
                    Button {
                        controller.seek(to: marker.offset)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(markerColor(marker.kind)).frame(width: 6, height: 6)
                            Text("\(formatDuration(marker.offset)) \(marker.title)")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(active ? markerColor(marker.kind).opacity(0.22) : Color.secondary.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func replaySTTPanel(_ snapshot: Conversation) -> some View {
        let spans = snapshot.transcriptSpans ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("STT 원문", systemImage: "waveform").font(.headline).foregroundStyle(.blue)
                Spacer()
                Text("\(spans.count)개 발화").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !spans.isEmpty {
                            ForEach(spans) { span in
                                let latest = span.id == spans.last?.id
                                Button {
                                    controller.seek(to: span.date)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(span.date, format: .dateTime.hour().minute().second())
                                            .font(.caption2)
                                            .foregroundStyle((latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color).opacity(0.8))
                                        Text(span.text)
                                            .font(.system(size: max(STTAppearance.minFontSize, model.sttAppearance.fontSize), weight: latest ? .semibold : .regular))
                                            .lineSpacing(model.sttAppearance.fontSize <= 13 ? 3 : 4)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(10)
                                    .foregroundStyle(latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                                    .background(latest ? model.sttAppearance.latestBackground.color : model.sttAppearance.text.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .id(span.id)
                            }
                        } else if !snapshot.transcript.isEmpty {
                            Text(snapshot.transcript)
                                .font(.system(size: max(STTAppearance.minFontSize, model.sttAppearance.fontSize)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("재생을 시작하면 이 시점의 STT 원문이 순서대로 나타납니다.")
                                .font(.caption)
                                .foregroundStyle(model.sttAppearance.text.color.opacity(0.75))
                                .padding(.top, 12)
                        }
                        Color.clear.frame(height: 1).id("replay-stt-bottom")
                    }
                    .padding(4)
                }
                .onChange(of: spans.count) { _, _ in
                    if controller.isPlaying { proxy.scrollTo("replay-stt-bottom", anchor: .bottom) }
                }
            }
        }
        .padding(10)
        .foregroundStyle(model.sttAppearance.text.color)
        .background(model.sttAppearance.background.color, in: RoundedRectangle(cornerRadius: 12))
    }

    private func replayTranslationPanel(_ snapshot: Conversation) -> some View {
        let entries = snapshot.translations ?? []
        let keywords = snapshot.allKeywords
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(model.targetLanguageName) \(model.t("panel.translation")) · 키워드", systemImage: "character.bubble").font(.headline).foregroundStyle(.purple)
                Spacer()
                Text("\(entries.count)개").font(.caption2).foregroundStyle(.secondary)
            }
            if !keywords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("누적 키워드 (\(keywords.count))").font(.caption2.bold()).foregroundStyle(.purple)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(keywords, id: \.self) { term in
                                Text(term)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if entries.isEmpty {
                            Text("이 시점까지 생성된 \(model.targetLanguageName) 번역이 여기에 재현됩니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        } else {
                            ForEach(entries) { entry in
                                let latest = entry.id == entries.last?.id
                                Button {
                                    if let date = entry.date { controller.seek(to: date) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if let date = entry.date {
                                            Text(date, format: .dateTime.hour().minute().second())
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(entry.source)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                        Text(entry.translated)
                                            .font(.system(size: max(13, model.panelTypography.translation - 2), weight: .medium))
                                            .lineSpacing(4)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(10)
                                    .background(Color.teal.opacity(latest ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.teal.opacity(latest ? 0.65 : 0.2), lineWidth: latest ? 1.5 : 1))
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("replay-tr-bottom")
                    }
                    .padding(4)
                }
                .onChange(of: entries.count) { _, _ in
                    if controller.isPlaying { proxy.scrollTo("replay-tr-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func replayAdvicePanel(_ snapshot: Conversation) -> some View {
        let items = snapshot.advice
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("대화 코치 조언", systemImage: "sparkles").font(.headline).foregroundStyle(.green)
                Spacer()
                Text("\(items.count)개").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        Text("이 시점까지 생성된 답변·조언이 여기에 재현됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    } else {
                        ForEach(items.reversed()) { advice in
                            let latest = advice.id == items.last?.id
                            Button {
                                controller.seek(to: advice.date)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(advice.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                                        if latest { Spacer(); Text("현재 시점 최신").font(.caption2.bold()).foregroundStyle(.green) }
                                    }
                                    Text(advice.text)
                                        .font(.system(size: max(13, model.panelTypography.advice - 2)))
                                        .lineSpacing(4)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(Color.green.opacity(latest ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(latest ? 0.6 : 0.2), lineWidth: latest ? 1.5 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private func replaySummaryAndScriptPanel(_ snapshot: Conversation) -> some View {
        let scriptParagraphs = ConversationScriptFormatter.paragraphs(for: snapshot)
        return VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("시점별 대화 요약", systemImage: "list.bullet.rectangle").font(.headline)
                    Spacer()
                    let count = snapshot.summaryHistory?.count ?? 0
                    if count > 0 {
                        Text("누적 \(count)회").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    if let summary = snapshot.summaries?["all"] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(snapshot.title).font(.caption.bold()).foregroundStyle(Color.accentColor)
                                Spacer()
                                Text(summary.updatedAt, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(summary.text)
                                .font(.system(size: max(12, model.panelTypography.summary - 1)))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("요약이 생성된 시점에 도달하면 누적 요약 변화가 재현됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                    }
                }
            }
            .padding(.bottom, 8)
            .frame(minHeight: 150, idealHeight: 220)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("정리된 스크립트", systemImage: "doc.text").font(.headline)
                    Spacer()
                    Text("\(scriptParagraphs.count)문단").font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if scriptParagraphs.isEmpty {
                            Text("재생 위치까지의 원문과 번역이 문단별로 정리됩니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                        } else {
                            ForEach(scriptParagraphs) { para in
                                Button {
                                    if let date = para.startDate { controller.seek(to: date) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text("문단 \(para.ordinal)").font(.caption2.bold())
                                            if let label = para.sourceLabel { Text(label).font(.caption2).foregroundStyle(.secondary) }
                                            Spacer()
                                            if let date = para.startDate { Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary) }
                                        }
                                        if let translated = para.translatedText {
                                            Text(translated)
                                                .font(.system(size: max(12, model.panelTypography.summary - 1), weight: .medium))
                                                .lineSpacing(4)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Text(para.originalText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineSpacing(3)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(9)
                                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(2)
                }
            }
            .padding(.top, 8)
            .frame(minHeight: 180, maxHeight: .infinity)
        }
    }

    private func markerColor(_ kind: ReplayMarker.Kind) -> Color {
        switch kind {
        case .audio: return .blue
        case .speech: return .cyan
        case .translation: return .teal
        case .advice: return .green
        case .summary: return .orange
        case .keyword: return .purple
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
