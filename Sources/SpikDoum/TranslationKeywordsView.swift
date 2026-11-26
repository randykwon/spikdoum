import SwiftUI
import AppKit

struct TranslationKeywordsView: View {
    static let minHeight: Double = 56
    static let maxHeight: Double = 420
    static let defaultHeight: Double = 130

    @ObservedObject var model: AppModel
    @AppStorage("keywordPanelHeight") private var panelHeight: Double = defaultHeight
    @AppStorage("showRelatedKeywords") private var showRelatedKeywords = true
    @State private var dragStartHeight: Double?
    @State private var hoveringHandle = false

    private var clampedHeight: CGFloat {
        CGFloat(min(Self.maxHeight, max(Self.minHeight, panelHeight)))
    }

    var body: some View {
        let terms: [String] = {
            guard let conversation = model.displayConversation else { return [] }
            if model.recentSeconds == 0 { return conversation.allKeywords }
            let recent = (conversation.keywords?.terms ?? []).filter { !KeywordPolicy.isBasicWord($0) }
            return recent.isEmpty ? conversation.allKeywords : recent
        }()
        let relatedMap: [String: [String]] = {
            guard let conversation = model.displayConversation else { return [:] }
            return conversation.allRelatedKeywords
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(model.recentSeconds == 0 ? "\(model.t("keywords.accumulated")) (\(terms.count))" : model.t("keywords.recent"), systemImage: "number")
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
                Spacer()
                if let error = model.keywordError {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(error)
                }
                if model.extractingKeywords { ProgressView().controlSize(.mini) }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRelatedKeywords.toggle() }
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(showRelatedKeywords ? Color.purple : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(showRelatedKeywords ? Color.purple.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(showRelatedKeywords ? "관련 단어 숨기기" : "관련 단어 함께 표시")
                PanelFontButton(title: "키워드", value: $model.panelTypography.keywords, defaultValue: 18)
                Button { adjustHeight(by: -40) } label: {
                    Image(systemName: "minus")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(panelHeight > Self.minHeight ? .secondary : .quaternary)
                .disabled(panelHeight <= Self.minHeight)
                .help("키워드 영역 세로 줄이기")
                Button { adjustHeight(by: 40) } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(panelHeight < Self.maxHeight ? .secondary : .quaternary)
                .disabled(panelHeight >= Self.maxHeight)
                .help("키워드 영역 세로 늘리기")
                Button { Task { await model.extractKeywords() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("핵심·생소 용어 및 관련 단어 갱신")
                    .disabled(!model.followLive || model.extractingKeywords || model.current?.archivedAt != nil || (model.current?.transcript.isEmpty ?? true))
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showTranslationKeywords = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("키워드 패널 숨기기")
            }
            if !terms.isEmpty {
                let latestSet = Set((model.displayConversation?.keywords?.terms ?? []).map { $0.lowercased() })
                let hasAnyRelated = showRelatedKeywords && terms.contains { !(relatedMap[$0.lowercased()] ?? []).isEmpty }
                let minCardWidth = hasAnyRelated
                    ? max(168, model.panelTypography.keywords * 9.5)
                    : max(96, model.panelTypography.keywords * 5)
                let relatedFontSize = max(11, model.panelTypography.keywords - 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minCardWidth), spacing: 6, alignment: .top)], alignment: .leading, spacing: 6) {
                            ForEach(terms, id: \.self) { term in
                                let isLatest = latestSet.contains(term.lowercased())
                                let relatedWords = showRelatedKeywords ? (relatedMap[term.lowercased()] ?? []) : []
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(term)
                                        .font(.system(size: model.panelTypography.keywords, weight: isLatest ? .semibold : .regular))
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    if !relatedWords.isEmpty {
                                        KeywordFlowLayout(spacing: 4) {
                                            ForEach(relatedWords, id: \.self) { related in
                                                Text(related)
                                                    .font(.system(size: relatedFontSize))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .textSelection(.enabled)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(isLatest ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 7))
                                .id(term)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .frame(height: clampedHeight)
                    .readingScrollControl(model)
                    .onChange(of: terms.first) { _, first in
                        if model.followLive, let first { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            } else {
                Text(model.extractingKeywords ? "핵심·생소 용어 분석 중…" : "핵심 용어나 생소한 용어가 나오면 관련 단어와 함께 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: max(32, min(clampedHeight, 48)), alignment: .leading)
            }
            resizeHandle
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 4)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.purple.opacity(hoveringHandle ? 0.35 : 0.14), lineWidth: 1))
        .task(id: model.selectedID) { if model.showTranslationKeywords { await model.extractKeywords(automatic: true) } }
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(height: 12)
            Capsule()
                .fill(hoveringHandle || dragStartHeight != nil ? Color.purple.opacity(0.75) : Color.secondary.opacity(0.35))
                .frame(width: 40, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help("위아래로 드래그하여 세로 크기 조절 (더블클릭: 기본 크기)")
        .onHover { hovering in
            if hovering && !hoveringHandle {
                hoveringHandle = true
                NSCursor.resizeUpDown.push()
            } else if !hovering && hoveringHandle {
                hoveringHandle = false
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hoveringHandle {
                hoveringHandle = false
                NSCursor.pop()
            }
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.18)) { panelHeight = Self.defaultHeight }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = min(Self.maxHeight, max(Self.minHeight, panelHeight)) }
                    let base = dragStartHeight ?? Self.defaultHeight
                    panelHeight = min(Self.maxHeight, max(Self.minHeight, base + value.translation.height))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }

    private func adjustHeight(by delta: Double) {
        withAnimation(.easeInOut(duration: 0.15)) {
            panelHeight = min(Self.maxHeight, max(Self.minHeight, panelHeight + delta))
        }
    }
}

private struct KeywordFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, currentX + size.width)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        return CGSize(width: min(maxWidth, usedWidth), height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
