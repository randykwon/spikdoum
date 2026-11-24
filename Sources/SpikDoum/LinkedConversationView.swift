import SwiftUI

struct LinkBadge: View {
    @ObservedObject var model: AppModel
    let spans: [TranscriptSpan]
    var context = false
    var title: String? = nil
    var body: some View {
        if let conversation = model.displayConversation, !spans.isEmpty {
            Button {
                model.pauseReading()
                model.selectedConversationBlockID = nil
                model.selectedLiveBlockID = spans.last?.id
            } label: {
                Label(title ?? ((context ? "맥락 " : "발언 ") + ConversationLinks.label(spans, in: conversation)), systemImage: "link")
                    .font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                    .foregroundStyle(Color.black)
                    .background(spans.contains { $0.id == model.selectedLiveBlockID } ? Color.orange : Color(red: 1, green: 0.90, blue: 0.67), in: Capsule())
            }.buttonStyle(.plain).help("연결된 원문·번역·조언 강조")
        } else { Text("연결 정보 없음").font(.caption2).foregroundStyle(.secondary) }
    }
}

struct LinkedConversationView: View {
    @ObservedObject var model: AppModel
    @State private var showHistory = false
    @State private var showingAppearance = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("STT Live · 원문", systemImage: "waveform").font(.headline).foregroundStyle(.blue)
                        Spacer()
                        Menu {
                            Toggle("전체 기록", isOn: $showHistory)
                            Button("원문 색상 · 글자 설정") { showingAppearance = true }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("원문 표시 설정")
                    }
                    Text((showHistory || model.recentSeconds == 0) ? "전체 기록 · 원문과 번역을 행별로 연결" : "최근 \(model.recentSeconds / 60)분 · 같은 번호는 같은 문장 묶음")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Label("\(model.targetLanguageName) \(model.t("panel.translation"))", systemImage: "character.bubble").font(.headline).foregroundStyle(.purple)
                        Spacer(minLength: 4)
                        Menu {
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
                        } label: {
                            Text(model.targetLanguage == "en-US" ? "EN" : model.targetLanguageName)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                        }
                        .menuStyle(.borderlessButton).fixedSize().help(model.t("settings.targetLanguage"))
                        if model.translating { ProgressView().controlSize(.mini) }
                        Menu {
                            Button("번역 다시 시도") { model.translateLatest() }.disabled(model.translating)
                            Toggle("키워드 함께 표시", isOn: $model.showTranslationKeywords)
                            if model.settings.translation == .apple && model.sourceLanguageSpec?.translationCode != model.targetLanguageSpec.translationCode {
                                Button("번역 언어 준비") { model.prepareTranslationLanguages() }.disabled(model.preparingTranslation)
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("번역 및 키워드 설정")
                    }
                    Text(model.translationError ?? model.translationStatus).font(.caption2)
                        .foregroundStyle(model.translationError == nil ? Color.secondary : .orange).lineLimit(1)
                        .help(model.translationError ?? (model.translationEngineDescription + " · " + model.translationStatus))
                    if model.showTranslationKeywords { TranslationKeywordsView(model: model) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("답변 · 조언", systemImage: "sparkles").font(.headline).foregroundStyle(.green)
                        Spacer()
                        if model.generating { ProgressView().controlSize(.mini) }
                        Menu {
                            Toggle("자동 조언", isOn: $model.autoAdvice)
                            Button("지금 조언 받기") { Task { await model.advise() } }
                                .disabled(model.generating || model.current?.archivedAt != nil || (model.current?.transcript.isEmpty ?? true))
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("대화 코치 설정")
                    }
                    Text(model.autoAdvice ? "자동 조언 켜짐 · 참고한 맥락에 연결" : "수동 조언 · 메뉴에서 지금 조언 받기")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.controlSize(.small)
            linkedTimeline.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .popover(isPresented: $showingAppearance) { STTAppearanceControls(model: model).padding(20).frame(width: 360) }
    }
    private var linkedTimeline: some View {
        let showAll = showHistory || model.recentSeconds == 0
        return TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
            if let conversation = model.displayConversation {
                let cutoff = activityReference(model, now: timeline.date).addingTimeInterval(-Double(model.recentSeconds))
                let allBlocks = ConversationBlocks.make(conversation)
                let blocks = allBlocks.filter { showAll || ($0.date.map { $0 >= cutoff } ?? true) || $0.spans.contains { $0.id == model.selectedLiveBlockID } }
                let linkedAdviceIDs = Set(allBlocks.flatMap { $0.advice.map(\.id) })
                let unlinkedAdvice = conversation.advice.filter { !linkedAdviceIDs.contains($0.id) && (showAll || $0.date >= cutoff) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if blocks.isEmpty {
                                ContentUnavailableView(conversation.transcript.isEmpty ? "대화를 시작해 주세요" : "최근 발언이 없습니다", systemImage: "waveform", description: Text("원문과 번역을 같은 번호로 연결합니다. 상단 범위에서 전체 기록을 볼 수 있습니다."))
                            }
                            ForEach(blocks) { block in
                                linkedRow(block, conversation: conversation, latest: block.id == allBlocks.last?.id).id(block.id)
                            }
                            if !unlinkedAdvice.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("추가 조언 기록 (\(unlinkedAdvice.count))").font(.caption.bold()).foregroundStyle(.secondary)
                                    ForEach(unlinkedAdvice) { item in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                                            Text(item.text).font(.system(size: model.panelTypography.advice)).lineSpacing(5).textSelection(.enabled)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }.padding(.top, 4)
                            }
                            if model.followLive && (model.translating || model.translationPreview != nil || !model.liveResponse.isEmpty) { pendingResults }
                            Color.clear.frame(height: 1).id("linked-bottom")
                        }.padding(4)
                    }
                    .readingScrollControl(model)
                    .onAppear { if model.followLive { proxy.scrollTo("linked-bottom", anchor: .bottom) } }
                    .onChange(of: model.displayConversation?.transcript) { _, _ in if model.followLive { proxy.scrollTo("linked-bottom", anchor: .bottom) } }
                    .onChange(of: model.displayConversation?.translations?.count) { _, _ in if model.followLive { proxy.scrollTo("linked-bottom", anchor: .bottom) } }
                    .onChange(of: model.displayConversation?.advice.count) { _, _ in if model.followLive { proxy.scrollTo("linked-bottom", anchor: .bottom) } }
                    .onChange(of: model.selectedConversationBlockID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.selectedLiveBlockID) { _, id in
                        if model.selectedConversationBlockID == nil, let id, let block = blocks.last(where: { $0.spans.contains { $0.id == id } }) { proxy.scrollTo(block.id, anchor: .center) }
                    }
                    .onChange(of: model.followLive) { _, follow in if follow { proxy.scrollTo("linked-bottom", anchor: .bottom) } }
                    .onChange(of: model.selectedID) { _, _ in proxy.scrollTo("linked-bottom", anchor: .bottom) }
                }
            }
        }
    }
    private func blockLink(_ block: ConversationBlock, selected: Bool) -> some View {
        Button {
            model.pauseReading()
            model.selectedConversationBlockID = block.id
            model.selectedLiveBlockID = block.spans.last?.id
        } label: {
            Label("묶음 #\(block.ordinal)", systemImage: "link")
                .font(.caption.bold()).foregroundStyle(Color.black).padding(.horizontal, 8).padding(.vertical, 4)
                .background(selected ? Color.orange : Color(red: 1, green: 0.90, blue: 0.67), in: Capsule())
        }.buttonStyle(.plain).help("이 문장 묶음의 원문과 번역을 함께 강조하고 읽기 고정")
    }
    private func linkedRow(_ block: ConversationBlock, conversation: Conversation, latest: Bool) -> some View {
        let selected = model.selectedConversationBlockID.map { $0 == block.id } ?? block.spans.contains { $0.id == model.selectedLiveBlockID }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    blockLink(block, selected: selected)
                    Spacer()
                    if let date = block.date { Text(date, format: .dateTime.hour().minute().second()).font(.caption2) }
                }
                Text(block.text).font(.system(size: latest ? model.sttAppearance.latestFontSize : model.sttAppearance.fontSize, weight: latest ? .semibold : .regular)).textSelection(.enabled).lineSpacing(model.sttAppearance.fontSize <= 13 ? 3 : 5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                .foregroundStyle(latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                .background(latest ? model.sttAppearance.latestBackground.color : model.sttAppearance.background.color, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                blockLink(block, selected: selected)
                if let entry = block.translation {
                    Text(entry.translated).font(.system(size: model.panelTypography.translation, weight: .medium)).lineSpacing(5).textSelection(.enabled)
                } else { Text(model.listening || model.translating ? "2~3문장 모으는 중 · 번역 대기" : "연결된 번역 없음").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                if block.advice.isEmpty { Text("이 구간에 새 조언 없음").font(.caption).foregroundStyle(.secondary) }
                ForEach(block.advice) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        LinkBadge(model: model, spans: ConversationLinks.spans(for: item, in: conversation), context: true)
                        Text(item.text).font(.system(size: model.panelTypography.advice)).lineSpacing(5).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }.fixedSize(horizontal: false, vertical: true).padding(4)
            .background(selected ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.orange : Color.secondary.opacity(0.2), lineWidth: selected ? 3 : 1))
    }
    private var pendingResults: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("번역 처리 원문 · 확정 전").font(.caption).foregroundStyle(.secondary)
                Text(model.translationPreview?.source ?? model.translationSource).font(.system(size: model.sttAppearance.fontSize)).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("번역 중 · 확정 전").font(.caption).foregroundStyle(.secondary)
                if let preview = model.translationPreview { Text(preview.translated).font(.system(size: model.panelTypography.translation)).textSelection(.enabled) }
                if !model.translationSource.isEmpty { Text(model.liveTranslation.isEmpty ? "번역 중…" : model.liveTranslation).font(.system(size: model.panelTypography.translation)).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if !model.liveResponse.isEmpty { Text("조언 생성 중 · 확정 전").font(.caption).foregroundStyle(.secondary); Text(model.liveResponse).font(.system(size: model.panelTypography.advice)).textSelection(.enabled) }
                else if model.generating { ProgressView("조언 생성 중") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12)
    }
}
