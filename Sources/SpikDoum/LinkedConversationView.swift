import SwiftUI
import AppKit

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

private enum LinkedRowStyle: String, CaseIterable {
    case sideBySide
    case stacked
}

private enum LinkedColumnBalance: String, CaseIterable {
    case equal = "균등"
    case translationWide = "번역 넓게"
    case sttWide = "원문 넓게"

    var weights: (stt: CGFloat, translation: CGFloat, coach: CGFloat) {
        switch self {
        case .equal: return (1.0, 1.0, 0.9)
        case .translationWide: return (0.85, 1.35, 0.85)
        case .sttWide: return (1.35, 0.85, 0.85)
        }
    }
}

private enum LinkedSpeakerFilter: String, CaseIterable {
    case all = "전체"
    case mic = "내 목소리"
    case system = "Mac 소리"
}

/// Ultra-lightweight live streaming caption row that observes ONLY `LiveSTTDisplayStore`.
/// Re-renders in <0.2ms on every partial word without invalidating `ContentView` or `ConversationBlocks`.
struct LiveSTTCaptionRow: View {
    @ObservedObject var liveSTT: LiveSTTDisplayStore
    let appearance: STTAppearance
    let followLive: Bool
    var showSourceBadge: Bool = true
    var sideBySideWidths: (stt: CGFloat, translation: CGFloat, coach: CGFloat)? = nil
    var showTranslationColumn: Bool = false
    var showCoachColumn: Bool = false
    var compact: Bool = false
    var onTextChange: (() -> Void)? = nil

    var body: some View {
        Group {
            if followLive && !liveSTT.text.isEmpty {
                let isMic = liveSTT.sourceTag == "마이크"
                let accent: Color = isMic ? .teal : .blue
                let innerPad: CGFloat = compact ? 7 : 10
                VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 5, height: 5)
                            Text("실시간 인식 중")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.white)
                        .background(accent, in: Capsule())

                        if showSourceBadge, let tag = liveSTT.sourceTag {
                            Label(tag == "마이크" ? "내 목소리" : "Mac 소리", systemImage: isMic ? "mic.fill" : "speaker.wave.2.fill")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(accent)
                                .background(accent.opacity(0.14), in: Capsule())
                        }
                        Spacer(minLength: 4)
                    }

                    if let widths = sideBySideWidths {
                        HStack(alignment: .top, spacing: 10) {
                            Text(liveSTT.text)
                                .font(.system(size: appearance.latestFontSize, weight: .semibold))
                                .foregroundStyle(appearance.latestText.color)
                                .lineSpacing(compact ? 2 : (appearance.fontSize <= 13 ? 3 : 5))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(innerPad)
                                .frame(width: widths.stt, alignment: .topLeading)
                                .background(appearance.latestBackground.color.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))

                            if showTranslationColumn && widths.translation > 0 {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("발화 완료 시 즉시 번역…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(innerPad)
                                .frame(width: widths.translation, alignment: .topLeading)
                                .background((isMic ? Color.teal : Color.purple).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }

                            if showCoachColumn && widths.coach > 0 {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(.quaternary)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(innerPad)
                                    .frame(width: widths.coach, alignment: .topLeading)
                                    .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(liveSTT.text)
                            .font(.system(size: appearance.latestFontSize, weight: .semibold))
                            .foregroundStyle(appearance.latestText.color)
                            .lineSpacing(compact ? 2 : (appearance.fontSize <= 13 ? 3 : 5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, innerPad)
                            .padding(.vertical, compact ? 5 : 8)
                            .background(appearance.latestBackground.color.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(compact ? 7 : 10)
                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.4, dash: [5, 3])))
            }
        }
        .onChange(of: liveSTT.text) { _, next in
            if followLive && !next.isEmpty {
                onTextChange?()
            }
        }
    }
}

private struct EmptyStateUnlessLive<Content: View>: View {
    @ObservedObject var liveSTT: LiveSTTDisplayStore
    @ViewBuilder let content: () -> Content
    var body: some View {
        if liveSTT.text.isEmpty {
            content()
        }
    }
}

struct LinkedConversationView: View {
    @ObservedObject var model: AppModel
    @AppStorage("linkedRowStyle") private var rowStyleRaw = LinkedRowStyle.sideBySide.rawValue
    @AppStorage("linkedColumnBalance") private var columnBalanceRaw = LinkedColumnBalance.translationWide.rawValue
    @AppStorage("linkedNewestFirst") private var newestFirst = false
    @AppStorage("linkedCompactDensity") private var compactDensity = false
    @AppStorage("pinLatestSpotlight") private var pinLatestSpotlight = true
    @AppStorage("pinnedSpotlightCount") private var pinnedSpotlightCount = 1
    @AppStorage("linkedControlHeaderCollapsedV1") private var controlHeaderCollapsed = false
    @State private var showHistory = false
    @State private var showingAppearance = false
    @State private var speakerFilter: LinkedSpeakerFilter = .all
    @State private var searchText = ""
    @State private var showingSearch = false
    @State private var hoveredBlockID: String?
    @State private var copiedBlockID: String?

    private var rowStyle: LinkedRowStyle {
        LinkedRowStyle(rawValue: rowStyleRaw) ?? .sideBySide
    }

    private var columnBalance: LinkedColumnBalance {
        LinkedColumnBalance(rawValue: columnBalanceRaw) ?? .translationWide
    }

    private var effectiveShowSTT: Bool {
        model.panelLayout.isVisible(.stt)
    }

    private var effectiveShowTranslation: Bool {
        model.panelLayout.isVisible(.translation)
    }

    private var effectiveShowCoach: Bool {
        !model.simpleFastMode && model.panelLayout.isVisible(.coach)
    }

    private var visibleColumnCount: Int {
        (effectiveShowSTT ? 1 : 0) + (effectiveShowTranslation ? 1 : 0) + (effectiveShowCoach ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: (model.topHeaderCollapsed || controlHeaderCollapsed) ? 4 : 6) {
            if !model.topHeaderCollapsed {
                if controlHeaderCollapsed {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { controlHeaderCollapsed = false }
                        } label: {
                            Label("보기 옵션 펼치기", systemImage: "chevron.down")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("좌우/상하 배치 · 최근 고정 · 검색 바 펼치기")
                        Spacer()
                        if model.translating { ProgressView().controlSize(.mini) }
                    }
                } else {
                    controlHeader
                }
            }
            if showingSearch {
                searchBar
            }
            GeometryReader { geo in
                let widths = columnWidths(totalWidth: max(320, geo.size.width - 28))
                VStack(alignment: .leading, spacing: 6) {
                    if rowStyle == .sideBySide {
                        columnHeaders(widths: widths)
                    }
                    ZStack(alignment: newestFirst ? .topTrailing : .bottomTrailing) {
                        linkedTimeline(widths: widths)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !model.followLive {
                            Button {
                                model.resumeReading()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: newestFirst ? "arrow.up.to.line" : "arrow.down.to.line")
                                    Text(model.hasUnreadLiveChanges ? "새 발언 보기" : "최신 위치로")
                                    if model.hasUnreadLiveChanges {
                                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThickMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
                                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(14)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                }
            }
        }
        .popover(isPresented: $showingAppearance) { STTAppearanceControls(model: model).padding(20).frame(width: 360) }
    }

    private func columnWidths(totalWidth: CGFloat) -> (stt: CGFloat, translation: CGFloat, coach: CGFloat) {
        let w = columnBalance.weights
        let count = max(1, visibleColumnCount)
        let spacing = CGFloat(max(0, count - 1)) * 10
        let usable = max(220, totalWidth - spacing)
        let sttW: CGFloat = effectiveShowSTT ? w.stt : 0
        let transW: CGFloat = effectiveShowTranslation ? w.translation : 0
        let coachW: CGFloat = effectiveShowCoach ? w.coach : 0
        let sum = max(0.01, sttW + transW + coachW)
        return (usable * sttW / sum, usable * transW / sum, usable * coachW / sum)
    }

    private var controlHeader: some View {
        HStack(spacing: 7) {
            Picker("배치", selection: $rowStyleRaw) {
                Label("좌우 비교", systemImage: "rectangle.split.2x1").tag(LinkedRowStyle.sideBySide.rawValue)
                Label("상하 자막", systemImage: "rectangle.split.1x2").tag(LinkedRowStyle.stacked.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 156)
            .help("좌우 비교 보기 또는 상하 자막 보기로 전환")

            if rowStyle == .sideBySide {
                Menu {
                    ForEach(LinkedColumnBalance.allCases, id: \.self) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { columnBalanceRaw = option.rawValue }
                        } label: {
                            if columnBalance == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(columnBalance.rawValue, systemImage: "rectangle.lefthalf.inset.filled")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.09), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("원문 · 번역 열 너비 비율 변경")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { pinLatestSpotlight.toggle() }
            } label: {
                Label("최근 고정", systemImage: pinLatestSpotlight ? "pin.fill" : "pin")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(pinLatestSpotlight ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
                    .foregroundStyle(pinLatestSpotlight ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(pinLatestSpotlight ? "최근 원문·번역을 상단에 고정해 스크롤 없이 편안하게 봅니다 (클릭하여 해제)" : "최근 원문·번역을 상단에 고정해 스크롤 없이 보기")

            if pinLatestSpotlight {
                Button {
                    pinnedSpotlightCount = pinnedSpotlightCount == 1 ? 2 : 1
                } label: {
                    Text("\(pinnedSpotlightCount)문장")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("상단 고정 영역에 표시할 최근 문장 수 전환 (1문장 / 2문장)")
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { newestFirst.toggle() }
                } label: {
                    Label(newestFirst ? "최신 위" : "시간순", systemImage: newestFirst ? "arrow.up.circle" : "arrow.down.circle")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(newestFirst ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                        .foregroundStyle(newestFirst ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(newestFirst ? "최신 문장이 맨 위에 표시됩니다" : "시간순으로 아래에 쌓입니다")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { compactDensity.toggle() }
            } label: {
                Label(compactDensity ? "조밀" : "여유", systemImage: compactDensity ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(compactDensity ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                    .foregroundStyle(compactDensity ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(compactDensity ? "조밀 보기 (한 화면에 더 많은 문장 표시)" : "여유 보기 (문장 간격 넉넉하게)")

            if hasDuplexSources {
                Picker("화자", selection: $speakerFilter) {
                    ForEach(LinkedSpeakerFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("내 목소리 또는 Mac 소리만 필터링")
            }

            Spacer(minLength: 4)

            if rowStyle == .stacked {
                PanelFontButton(title: "STT 원문", value: $model.sttAppearance.fontSize, range: STTAppearance.minFontSize...STTAppearance.maxFontSize, defaultValue: 20)
                PanelFontButton(title: "번역", value: $model.panelTypography.translation, defaultValue: 19)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingSearch.toggle()
                    if !showingSearch { searchText = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(showingSearch || !searchText.isEmpty ? Color.accentColor : Color.secondary)
                    .padding(4)
                    .background((showingSearch || !searchText.isEmpty) ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("현재 대화 내 원문 · 번역 검색")

            if !model.simpleFastMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.panelLayout.toggle(.coach, includeCoach: true) }
                } label: {
                    Label("조언", systemImage: "sparkles")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(effectiveShowCoach ? Color.green : Color.secondary)
                        .background(effectiveShowCoach ? Color.green.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(effectiveShowCoach && !model.panelLayout.canHide(.coach, includeCoach: true))
                .help(effectiveShowCoach ? "조언 열 숨기기 (원문·번역 넓게 보기)" : "조언 열 표시")
            }

            if model.translating { ProgressView().controlSize(.mini) }

            Menu {
                Toggle("전체 기록 보기", isOn: $showHistory)
                Button("원문 색상 · 글자 설정") { showingAppearance = true }
                Divider()
                Button("번역 다시 시도") { model.translateLatest() }.disabled(model.translating)
                if !model.simpleFastMode {
                    Toggle("키워드 함께 표시", isOn: $model.showTranslationKeywords)
                    Toggle("자동 조언", isOn: $model.autoAdvice)
                    Toggle("STT + 번역 동시 코칭", isOn: $model.bilingualCoach)
                    Button("지금 조언 받기") { Task { await model.advise() } }
                        .disabled(model.generating || model.current?.archivedAt != nil || (model.current?.transcript.isEmpty ?? true))
                }
                if model.settings.translation == .apple && model.sourceLanguageSpec?.translationCode != model.targetLanguageSpec.translationCode {
                    Divider()
                    Button("번역 언어 준비") { model.prepareTranslationLanguages() }.disabled(model.preparingTranslation)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("연계 보기 표시 및 번역·코치 설정")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { controlHeaderCollapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("보기 옵션 바 접기")
        }
        .controlSize(.small)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("이 대화의 원문 또는 번역 검색…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func columnHeaders(widths: (stt: CGFloat, translation: CGFloat, coach: CGFloat)) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if effectiveShowSTT {
                HStack(spacing: 6) {
                    Label("원문", systemImage: "waveform")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                    Spacer(minLength: 4)
                    PanelFontButton(title: "STT 원문", value: $model.sttAppearance.fontSize, range: STTAppearance.minFontSize...STTAppearance.maxFontSize, defaultValue: 20)
                    if model.panelLayout.canHide(.stt, includeCoach: !model.simpleFastMode) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { model.panelLayout.setVisible(.stt, false, includeCoach: !model.simpleFastMode) }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("원문 열 숨기기")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: widths.stt, alignment: .leading)
                .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            if effectiveShowTranslation {
                HStack(spacing: 6) {
                    Label("\(model.targetLanguageName) 번역", systemImage: "character.bubble")
                        .font(.caption.bold())
                        .foregroundStyle(.purple)
                    Text(model.translationError ?? model.translationStatus)
                        .font(.caption2)
                        .foregroundStyle(model.translationError == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    PanelFontButton(title: "번역", value: $model.panelTypography.translation, defaultValue: 19)
                    if model.panelLayout.canHide(.translation, includeCoach: !model.simpleFastMode) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { model.panelLayout.setVisible(.translation, false, includeCoach: !model.simpleFastMode) }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("번역 열 숨기기")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: widths.translation, alignment: .leading)
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            if effectiveShowCoach {
                HStack(spacing: 6) {
                    Label("코치 · 조언", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    if model.generating { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 4)
                    PanelFontButton(title: "대화 코치", value: $model.panelTypography.advice, defaultValue: 18)
                    if model.panelLayout.canHide(.coach, includeCoach: true) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { model.panelLayout.setVisible(.coach, false, includeCoach: true) }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("코치 열 숨기기")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: widths.coach, alignment: .leading)
                .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
    }

    private var hasDuplexSources: Bool {
        guard let transcript = model.displayConversation?.transcript else { return false }
        return transcript.contains("[마이크]") && transcript.contains("[Mac 재생음]")
    }

    private func linkedTimeline(widths: (stt: CGFloat, translation: CGFloat, coach: CGFloat)) -> some View {
        let showAll = showHistory || model.recentSeconds == 0
        return TimelineView(LiveActivitySchedule(active: model.listening && model.followLive && !showAll)) { timeline in
            if let conversation = model.displayConversation {
                let cutoff = activityReference(model, now: timeline.date).addingTimeInterval(-Double(model.recentSeconds))
                let allBlocks = ConversationBlocks.make(conversation)
                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let filteredBlocks = allBlocks.filter { block in
                    let inRange = showAll || (block.date.map { $0 >= cutoff } ?? true) || block.spans.contains { $0.id == model.selectedLiveBlockID }
                    guard inRange else { return false }
                    if speakerFilter != .all {
                        let tag = TranslationPolicy.sourceTag(of: block.text)
                        if speakerFilter == .mic && tag != "마이크" { return false }
                        if speakerFilter == .system && tag != "Mac 재생음" { return false }
                    }
                    if !trimmedQuery.isEmpty {
                        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                        let matchesSource = block.text.range(of: trimmedQuery, options: opts) != nil
                        let matchesTranslation = block.translation?.translated.range(of: trimmedQuery, options: opts) != nil
                        let matchesAdvice = block.advice.contains { $0.text.range(of: trimmedQuery, options: opts) != nil }
                        return matchesSource || matchesTranslation || matchesAdvice
                    }
                    return true
                }
                let usePinnedStage = pinLatestSpotlight && trimmedQuery.isEmpty
                let pinCount = max(1, min(2, pinnedSpotlightCount))
                let pinnedBlocks = usePinnedStage ? Array(filteredBlocks.suffix(pinCount).reversed()) : []
                let historySource = usePinnedStage ? Array(filteredBlocks.dropLast(pinnedBlocks.count)) : filteredBlocks
                let orderedBlocks = (usePinnedStage || newestFirst) ? Array(historySource.reversed()) : historySource
                let latestBlockID = allBlocks.last?.id
                let linkedAdviceIDs = Set(allBlocks.flatMap { $0.advice.map(\.id) })
                let unlinkedAdvice = conversation.advice.filter { !linkedAdviceIDs.contains($0.id) && (showAll || $0.date >= cutoff) }
                let lastBlockIsPendingInPlace = allBlocks.last?.translation == nil && !model.translationSource.isEmpty
                let showSeparatePending = model.followLive
                    && (!lastBlockIsPendingInPlace && (model.translationPreview != nil || (!model.translationSource.isEmpty && allBlocks.isEmpty))
                        || (effectiveShowCoach && (!model.liveResponse.isEmpty || model.generating)))
                let anchorID = newestFirst ? "linked-top" : "linked-bottom"
                let anchorPos: UnitPoint = newestFirst ? .top : .bottom

                VStack(alignment: .leading, spacing: 8) {
                    if usePinnedStage {
                        // FIXED NON-SCROLLING RECENT STAGE: eyes stay locked on one calm spot without scroll jumping.
                        VStack(alignment: .leading, spacing: compactDensity ? 5 : 7) {
                            HStack(spacing: 6) {
                                Label("최근 내용 고정", systemImage: "pin.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.accentColor)
                                Text("스크롤 없이 이 자리에 실시간 갱신")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !orderedBlocks.isEmpty {
                                    Text("아래 이전 기록 \(orderedBlocks.count)건")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 4)

                            if effectiveShowSTT {
                                LiveSTTCaptionRow(
                                    liveSTT: model.liveSTT,
                                    appearance: model.sttAppearance,
                                    followLive: model.followLive,
                                    sideBySideWidths: rowStyle == .sideBySide ? widths : nil,
                                    showTranslationColumn: effectiveShowTranslation,
                                    showCoachColumn: effectiveShowCoach,
                                    compact: compactDensity
                                )
                            }

                            if pinnedBlocks.isEmpty {
                                EmptyStateUnlessLive(liveSTT: model.liveSTT) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(.secondary)
                                        Text(conversation.transcript.isEmpty ? "대화를 시작하면 최근 원문과 번역이 스크롤 없이 여기에 고정 표시됩니다." : "표시할 최근 발언이 없습니다.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                }
                            } else {
                                ForEach(pinnedBlocks) { block in
                                    let isLatest = block.id == latestBlockID
                                    linkedRow(
                                        block,
                                        conversation: conversation,
                                        latest: isLatest,
                                        inPlaceStreaming: isLatest && block.translation == nil && model.followLive,
                                        widths: widths
                                    )
                                }
                            }

                            if showSeparatePending {
                                pendingBanner
                            }
                        }
                        .padding(8)
                        .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
                        .padding(.horizontal, 2)

                        if !orderedBlocks.isEmpty || (effectiveShowCoach && !unlinkedAdvice.isEmpty) {
                            HStack(spacing: 6) {
                                Text("이전 대화 기록")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Text("(\(orderedBlocks.count)건 · 스크롤 고정)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.16))
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 6)
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: compactDensity ? 5 : 8) {
                                Color.clear.frame(height: 1).id("linked-top")
                                if !usePinnedStage && newestFirst && effectiveShowSTT {
                                    LiveSTTCaptionRow(
                                        liveSTT: model.liveSTT,
                                        appearance: model.sttAppearance,
                                        followLive: model.followLive,
                                        sideBySideWidths: rowStyle == .sideBySide ? widths : nil,
                                        showTranslationColumn: effectiveShowTranslation,
                                        showCoachColumn: effectiveShowCoach,
                                        compact: compactDensity
                                    ) {
                                        proxy.scrollTo(anchorID, anchor: anchorPos)
                                    }
                                    .id("linked-live-stt")
                                }
                                if !usePinnedStage && newestFirst && showSeparatePending {
                                    pendingBanner
                                }
                                if !usePinnedStage && orderedBlocks.isEmpty {
                                    EmptyStateUnlessLive(liveSTT: model.liveSTT) {
                                        ContentUnavailableView(
                                            !trimmedQuery.isEmpty ? "검색 결과가 없습니다" : conversation.transcript.isEmpty ? "대화를 시작해 주세요" : "표시할 발언이 없습니다",
                                            systemImage: !trimmedQuery.isEmpty ? "magnifyingglass" : "waveform",
                                            description: Text(!trimmedQuery.isEmpty ? "다른 검색어를 입력하거나 검색을 지워보세요." : "원문과 번역을 한 문장씩 연결해 보여줍니다.")
                                        )
                                        .padding(.vertical, 24)
                                    }
                                }
                                ForEach(orderedBlocks) { block in
                                    let isLatest = !usePinnedStage && block.id == latestBlockID
                                    linkedRow(
                                        block,
                                        conversation: conversation,
                                        latest: isLatest,
                                        inPlaceStreaming: isLatest && block.translation == nil && model.followLive,
                                        widths: widths
                                    )
                                    .id(block.id)
                                }
                                if effectiveShowCoach && !unlinkedAdvice.isEmpty && trimmedQuery.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("추가 조언 기록 (\(unlinkedAdvice.count))").font(.caption.bold()).foregroundStyle(.secondary)
                                        ForEach(unlinkedAdvice) { item in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                                                AdviceCardBody(advice: item, fontSize: model.panelTypography.advice)
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                        }
                                    }.padding(.top, 4)
                                }
                                if !usePinnedStage && !newestFirst && effectiveShowSTT {
                                    LiveSTTCaptionRow(
                                        liveSTT: model.liveSTT,
                                        appearance: model.sttAppearance,
                                        followLive: model.followLive,
                                        sideBySideWidths: rowStyle == .sideBySide ? widths : nil,
                                        showTranslationColumn: effectiveShowTranslation,
                                        showCoachColumn: effectiveShowCoach,
                                        compact: compactDensity
                                    ) {
                                        proxy.scrollTo(anchorID, anchor: anchorPos)
                                    }
                                    .id("linked-live-stt")
                                }
                                if !usePinnedStage && !newestFirst && showSeparatePending {
                                    pendingBanner
                                }
                                Color.clear.frame(height: 1).id("linked-bottom")
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                        .readingScrollControl(model)
                        .onAppear { if !usePinnedStage && model.followLive { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: model.displayConversation?.transcript) { _, _ in if !usePinnedStage && model.followLive { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: model.displayConversation?.translations?.count) { _, _ in if !usePinnedStage && model.followLive { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: model.displayConversation?.advice.count) { _, _ in if !usePinnedStage && model.followLive { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: model.selectedConversationBlockID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: model.selectedLiveBlockID) { _, id in
                            if model.selectedConversationBlockID == nil, let id, let block = orderedBlocks.last(where: { $0.spans.contains { $0.id == id } }) {
                                proxy.scrollTo(block.id, anchor: .center)
                            }
                        }
                        .onChange(of: model.followLive) { _, follow in if !usePinnedStage && follow { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: model.selectedID) { _, _ in if !usePinnedStage { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                        .onChange(of: newestFirst) { _, _ in if !usePinnedStage && model.followLive { proxy.scrollTo(anchorID, anchor: anchorPos) } }
                    }
                }
            }
        }
    }

    private func rowMetaBar(
        block: ConversationBlock,
        selected: Bool,
        latest: Bool,
        sourceTag: String?,
        isMic: Bool,
        displaySTT: String
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                model.pauseReading()
                model.selectedConversationBlockID = block.id
                model.selectedLiveBlockID = block.spans.last?.id
            } label: {
                Text("#\(block.ordinal)")
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(selected ? Color.white : (latest ? Color.accentColor : Color.secondary))
                    .background(
                        selected ? Color.orange : (latest ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .help("이 문장을 강조하고 읽기 위치 고정")

            if sourceTag != nil {
                Label(isMic ? "내 목소리" : "Mac 소리", systemImage: isMic ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(isMic ? Color.teal : Color.blue)
                    .background((isMic ? Color.teal : Color.blue).opacity(0.14), in: Capsule())
            }

            if let entry = block.translation,
               let srcCode = entry.sourceLanguageCode,
               let srcLang = LanguageCatalog.language(for: srcCode) {
                let dstShort = entry.targetLanguage.flatMap { LanguageCatalog.language(for: $0)?.shortCode } ?? model.targetLanguageSpec.shortCode
                let badgeText = srcLang.shortCode == dstShort
                    ? srcLang.shortCode.uppercased()
                    : "\(srcLang.shortCode.uppercased())→\(dstShort.uppercased())"
                Text(badgeText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(Color.purple)
                    .background(Color.purple.opacity(0.12), in: Capsule())
            }

            if latest && model.listening {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .foregroundStyle(Color.white)
                    .background(Color.blue, in: Capsule())
            }

            if let date = block.date {
                Text(date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if block.translation == nil && !model.translating && (hoveredBlockID == block.id || !model.listening) {
                Button {
                    model.translateLatest()
                } label: {
                    Label("지금 번역", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("이 문장 지금 번역 실행")
            }

            if hoveredBlockID == block.id || copiedBlockID == block.id {
                Button {
                    let translated = block.translation?.translated ?? ""
                    let payload = translated.isEmpty ? displaySTT : "\(displaySTT)\n\(translated)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    copiedBlockID = block.id
                    let currentID = block.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        if copiedBlockID == currentID { copiedBlockID = nil }
                    }
                } label: {
                    Label(copiedBlockID == block.id ? "복사됨" : "복사", systemImage: copiedBlockID == block.id ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedBlockID == block.id ? Color.green : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("원문과 번역 함께 복사")
            }
        }
    }

    @ViewBuilder
    private func translationBody(block: ConversationBlock, inPlaceStreaming: Bool) -> some View {
        if let entry = block.translation {
            Text(entry.translated)
                .font(.system(size: model.panelTypography.translation, weight: .medium))
                .lineSpacing(compactDensity ? 3 : 5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if inPlaceStreaming && !model.liveTranslation.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.liveTranslation)
                    .font(.system(size: model.panelTypography.translation, weight: .medium))
                    .lineSpacing(compactDensity ? 3 : 5)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("실시간 번역 중…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if inPlaceStreaming && model.translating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("번역 중…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(model.listening ? "한 문장 모으는 중…" : "연결된 번역 없음")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkedRow(
        _ block: ConversationBlock,
        conversation: Conversation,
        latest: Bool,
        inPlaceStreaming: Bool,
        widths: (stt: CGFloat, translation: CGFloat, coach: CGFloat)
    ) -> some View {
        let selected = model.selectedConversationBlockID.map { $0 == block.id } ?? block.spans.contains { $0.id == model.selectedLiveBlockID }
        let sourceTag = TranslationPolicy.sourceTag(of: block.text)
        let isMic = sourceTag == "마이크"
        let displaySTT = sourceTag == nil ? block.text : TranslationPolicy.displayText(strippingSourceTag: block.text)
        let accentColor: Color = selected ? .orange : (isMic ? .teal : (latest ? .accentColor : .secondary.opacity(0.25)))
        let innerPad: CGFloat = compactDensity ? 7 : 10

        return VStack(alignment: .leading, spacing: compactDensity ? 5 : 8) {
            rowMetaBar(block: block, selected: selected, latest: latest, sourceTag: sourceTag, isMic: isMic, displaySTT: displaySTT)

            if rowStyle == .stacked {
                VStack(alignment: .leading, spacing: compactDensity ? 5 : 7) {
                    if effectiveShowSTT {
                        Text(displaySTT)
                            .font(.system(size: latest ? model.sttAppearance.latestFontSize : model.sttAppearance.fontSize, weight: latest ? .semibold : .regular))
                            .foregroundStyle(latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                            .lineSpacing(compactDensity ? 2 : (model.sttAppearance.fontSize <= 13 ? 3 : 5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, innerPad)
                            .padding(.vertical, compactDensity ? 5 : 8)
                            .background(
                                (latest ? model.sttAppearance.latestBackground.color : model.sttAppearance.background.color),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }

                    if effectiveShowTranslation {
                        translationBody(block: block, inPlaceStreaming: inPlaceStreaming)
                            .padding(.horizontal, innerPad)
                            .padding(.vertical, compactDensity ? 5 : 8)
                            .background((isMic ? Color.teal : Color.purple).opacity(latest ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if effectiveShowCoach && !block.advice.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(block.advice) { item in
                                AdviceCardBody(advice: item, fontSize: model.panelTypography.advice)
                            }
                        }
                        .padding(.horizontal, innerPad)
                        .padding(.vertical, compactDensity ? 5 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if effectiveShowSTT {
                        Text(displaySTT)
                            .font(.system(size: latest ? model.sttAppearance.latestFontSize : model.sttAppearance.fontSize, weight: latest ? .semibold : .regular))
                            .foregroundStyle(latest ? model.sttAppearance.latestText.color : model.sttAppearance.text.color)
                            .lineSpacing(compactDensity ? 2 : (model.sttAppearance.fontSize <= 13 ? 3 : 5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(innerPad)
                            .frame(width: widths.stt, alignment: .topLeading)
                            .background(
                                (latest ? model.sttAppearance.latestBackground.color : model.sttAppearance.background.color),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }

                    if effectiveShowTranslation {
                        translationBody(block: block, inPlaceStreaming: inPlaceStreaming)
                            .padding(innerPad)
                            .frame(width: widths.translation, alignment: .topLeading)
                            .background((isMic ? Color.teal : Color.purple).opacity(latest ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if effectiveShowCoach {
                        VStack(alignment: .leading, spacing: 6) {
                            if block.advice.isEmpty {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(.quaternary)
                            } else {
                                ForEach(block.advice) { item in
                                    AdviceCardBody(advice: item, fontSize: model.panelTypography.advice)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(innerPad)
                        .frame(width: widths.coach, alignment: .topLeading)
                        .background(
                            block.advice.isEmpty ? Color.secondary.opacity(0.03) : Color.green.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compactDensity ? 7 : 10)
        .background(
            selected
                ? Color.orange.opacity(0.10)
                : (latest ? Color.accentColor.opacity(0.04) : Color(nsColor: .controlBackgroundColor).opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(accentColor, lineWidth: selected ? 2.2 : (latest || isMic ? 1.2 : 0.7))
        )
        .onHover { hovering in
            hoveredBlockID = hovering ? block.id : (hoveredBlockID == block.id ? nil : hoveredBlockID)
        }
    }

    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = model.translationPreview {
                HStack(alignment: .top, spacing: 10) {
                    Text(TranslationPolicy.displayText(strippingSourceTag: preview.source))
                        .font(.system(size: model.sttAppearance.fontSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(preview.translated)
                        .font(.system(size: model.panelTypography.translation))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if effectiveShowCoach && (!model.liveResponse.isEmpty || model.generating) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    if !model.liveResponse.isEmpty {
                        Text(model.liveResponse)
                            .font(.system(size: model.panelTypography.advice))
                            .textSelection(.enabled)
                    } else {
                        Text("조언 생성 중…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.horizontal, 4)
    }
}
