import SwiftUI
import AppKit
import NaturalLanguage

enum ScriptDisplayMode: String, CaseIterable {
    case organized = "문단 정리"
    case bilingual = "원문+번역"
    case koreanOnly = "번역만"
    case originalOnly = "원문만"

    func title(in ui: ResolvedUILanguage) -> String {
        switch self {
        case .organized: return L10n.t("script.mode.organized", lang: ui)
        case .bilingual: return L10n.t("script.mode.bilingual", lang: ui)
        case .koreanOnly: return L10n.t("script.mode.translated", lang: ui)
        case .originalOnly: return L10n.t("script.mode.original", lang: ui)
        }
    }
}

struct ConversationScriptItem: Identifiable, Equatable {
    var id: String
    var ordinal: Int
    var date: Date?
    var sourceLabel: String?
    var original: String
    var translated: String?
}

struct ConversationScriptParagraph: Identifiable, Equatable {
    var id: String
    var ordinal: Int
    var startDate: Date?
    var endDate: Date?
    var sourceLabel: String?
    var sentences: [String]
    var translatedSentences: [String]

    var originalText: String { sentences.joined(separator: " ") }
    var translatedText: String? {
        guard !translatedSentences.isEmpty else { return nil }
        return translatedSentences.joined(separator: " ")
    }
}

struct OrganizedScriptSection: Identifiable, Equatable {
    var id: String
    var heading: String?
    var paragraphs: [String]
}

enum ConversationScriptFormatter {
    static func items(for conversation: Conversation) -> [ConversationScriptItem] {
        let blocks = ConversationBlocks.make(conversation)
        if !blocks.isEmpty {
            return blocks.compactMap { block in
                let raw = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                let (label, cleaned) = extractSourceLabel(from: raw)
                let normalized = normalizeFlow(cleaned.isEmpty ? raw : cleaned)
                let translated = block.translation.map { normalizeFlow($0.translated) }
                return ConversationScriptItem(
                    id: block.id,
                    ordinal: block.ordinal,
                    date: block.date,
                    sourceLabel: label,
                    original: normalized,
                    translated: translated?.isEmpty == false ? translated : nil
                )
            }
        }
        let raw = conversation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let (label, cleaned) = extractSourceLabel(from: raw)
        return [ConversationScriptItem(id: "raw", ordinal: 1, date: conversation.date, sourceLabel: label, original: normalizeFlow(cleaned.isEmpty ? raw : cleaned), translated: nil)]
    }

    /// Groups raw STT/translation blocks into well-proportioned, readable paragraphs
    /// broken by source changes, pauses (>=15s), or sentence/length bounds (3–4 sentences / ~340 chars).
    static func paragraphs(for conversation: Conversation) -> [ConversationScriptParagraph] {
        let rawItems = items(for: conversation)
        guard !rawItems.isEmpty else { return [] }

        var result: [ConversationScriptParagraph] = []
        var currentSource: String? = rawItems[0].sourceLabel
        var currentStartDate: Date? = rawItems[0].date
        var currentEndDate: Date? = rawItems[0].date
        var origSentences: [String] = []
        var transSentences: [String] = []
        var origCharCount = 0

        func flush() {
            guard !origSentences.isEmpty else { return }
            let ordinal = result.count + 1
            result.append(ConversationScriptParagraph(
                id: "para-\(ordinal)",
                ordinal: ordinal,
                startDate: currentStartDate,
                endDate: currentEndDate,
                sourceLabel: currentSource,
                sentences: origSentences,
                translatedSentences: transSentences
            ))
            origSentences = []
            transSentences = []
            origCharCount = 0
        }

        for item in rawItems {
            let sourceChanged = item.sourceLabel != nil && currentSource != nil && item.sourceLabel != currentSource
            let pauseGap: Bool = {
                guard let prev = currentEndDate, let next = item.date else { return false }
                return next.timeIntervalSince(prev) >= 15
            }()
            let itemSentences = splitSentences(item.original)
            let itemTranslated = item.translated.map(splitSentences) ?? []
            let wouldOverflow = !origSentences.isEmpty && (origSentences.count + itemSentences.count > 4 || origCharCount + item.original.count > 360)

            if !origSentences.isEmpty && (sourceChanged || pauseGap || wouldOverflow) {
                flush()
                currentSource = item.sourceLabel ?? currentSource
                currentStartDate = item.date
                currentEndDate = item.date
            } else {
                if currentSource == nil { currentSource = item.sourceLabel }
                if currentStartDate == nil { currentStartDate = item.date }
                if let date = item.date { currentEndDate = date }
            }

            origSentences.append(contentsOf: itemSentences)
            transSentences.append(contentsOf: itemTranslated)
            origCharCount += item.original.count
        }
        flush()
        return result
    }

    /// Parses AI-polished script markdown (optional `### heading` + blank-line paragraphs) into display sections.
    static func parseOrganizedSections(_ text: String) -> [OrganizedScriptSection] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var sections: [OrganizedScriptSection] = []
        var currentHeading: String? = nil
        var currentParagraphs: [String] = []

        func flushSection() {
            guard currentHeading != nil || !currentParagraphs.isEmpty else { return }
            sections.append(OrganizedScriptSection(id: "sec-\(sections.count + 1)", heading: currentHeading, paragraphs: currentParagraphs))
            currentHeading = nil
            currentParagraphs = []
        }

        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = lines.first else { continue }
            if first.hasPrefix("#") {
                flushSection()
                currentHeading = first.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                let remainder = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty { currentParagraphs.append(remainder) }
            } else {
                currentParagraphs.append(lines.joined(separator: " "))
            }
        }
        flushSection()
        return sections
    }

    static func scriptInputForPolishing(_ conversation: Conversation, paragraphs precomputed: [ConversationScriptParagraph]? = nil) -> String {
        let paras = precomputed ?? paragraphs(for: conversation)
        guard !paras.isEmpty else { return normalizeFlow(conversation.transcript) }
        return paras.map { para in
            let prefix = para.sourceLabel.map { "[\($0)] " } ?? ""
            if let translated = para.translatedText {
                return "\(prefix)\(translated)\n(원문: \(para.originalText))"
            }
            return "\(prefix)\(para.originalText)"
        }.joined(separator: "\n\n")
    }

    static func nextPolishChunk(from pending: String, maxChars: Int) -> String {
        guard pending.count > maxChars else { return pending }
        let limit = pending.index(pending.startIndex, offsetBy: maxChars)
        let candidate = pending[..<limit]
        if let paragraphBreak = candidate.range(of: "\n\n", options: .backwards) {
            return String(pending[..<paragraphBreak.upperBound])
        }
        if let lineBreak = candidate.lastIndex(of: "\n") {
            return String(pending[...lineBreak])
        }
        if let space = candidate.lastIndex(of: " ") {
            return String(pending[...space])
        }
        return String(candidate)
    }

    static func plainText(for conversation: Conversation, mode: ScriptDisplayMode) -> String {
        if mode == .organized, let organized = conversation.organizedScript,
           !organized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return organized.text
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let paras = paragraphs(for: conversation)
        return paras.compactMap { para -> String? in
            var headerParts = ["문단 #\(para.ordinal)"]
            if let start = para.startDate {
                if let end = para.endDate, end.timeIntervalSince(start) >= 2 {
                    headerParts.append("\(formatter.string(from: start))–\(formatter.string(from: end))")
                } else {
                    headerParts.append(formatter.string(from: start))
                }
            }
            if let label = para.sourceLabel { headerParts.append(label) }
            let header = headerParts.joined(separator: " · ")

            switch mode {
            case .organized, .bilingual:
                if let translated = para.translatedText {
                    return "[\(header)]\n\(para.originalText)\n→ \(translated)"
                }
                return "[\(header)]\n\(para.originalText)"
            case .koreanOnly:
                guard let translated = para.translatedText else { return "[\(header)]\n(번역 대기) \(para.originalText)" }
                return "[\(header)]\n\(translated)"
            case .originalOnly:
                return "[\(header)]\n\(para.originalText)"
            }
        }.joined(separator: "\n\n")
    }

    static func splitSentences(_ text: String) -> [String] {
        let cleaned = normalizeFlow(text)
        guard !cleaned.isEmpty else { return [] }
        // Fast single-pass sentence split avoids creating hundreds of CoreNLP NLTokenizer instances per SwiftUI frame.
        var sentences: [String] = []
        var start = cleaned.startIndex
        var index = cleaned.startIndex
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", ")", "]", "}"]
        while index < cleaned.endIndex {
            let ch = cleaned[index]
            let next = cleaned.index(after: index)
            if terminators.contains(ch) {
                var end = next
                while end < cleaned.endIndex && closers.contains(cleaned[end]) {
                    end = cleaned.index(after: end)
                }
                let atBoundary = end == cleaned.endIndex || cleaned[end].isWhitespace
                if atBoundary {
                    let piece = cleaned[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { sentences.append(piece) }
                    start = end
                    while start < cleaned.endIndex && cleaned[start].isWhitespace {
                        start = cleaned.index(after: start)
                    }
                    index = start
                    continue
                }
            }
            index = next
        }
        if start < cleaned.endIndex {
            let tail = cleaned[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
        }
        return sentences.isEmpty ? [cleaned] : sentences
    }

    static func normalizeFlow(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "[Mac 재생음]", with: "")
            .replacingOccurrences(of: "[마이크]", with: "")
        let components = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    private static func extractSourceLabel(from text: String) -> (String?, String) {
        for tag in ["[Mac 재생음]", "[마이크]"] {
            if text.hasPrefix(tag) {
                let label = String(tag.dropFirst().dropLast())
                let body = text.dropFirst(tag.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return (label, body)
            }
        }
        return (nil, text)
    }
}

struct SummaryScriptPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage("scriptDisplayMode") private var scriptModeRaw = ScriptDisplayMode.organized.rawValue
    @State private var copied = false

    private var scriptMode: Binding<ScriptDisplayMode> {
        Binding(
            get: { ScriptDisplayMode(rawValue: scriptModeRaw) ?? .organized },
            set: { scriptModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        let showSummary = model.panelLayout.isVisible(.summary)
        let showScript = model.panelLayout.isVisible(.script)
        Group {
            if showSummary && showScript {
                VSplitView {
                    if model.panelLayout.summaryScriptReversed {
                        fullScriptSection
                            .padding(.bottom, 10)
                            .frame(minHeight: 220, maxHeight: .infinity)

                        SummaryPanel(model: model)
                            .padding(.top, 10)
                            .frame(minHeight: 160, idealHeight: 230)
                    } else {
                        SummaryPanel(model: model)
                            .padding(.bottom, 10)
                            .frame(minHeight: 160, idealHeight: 230)

                        fullScriptSection
                            .padding(.top, 10)
                            .frame(minHeight: 220, maxHeight: .infinity)
                    }
                }
            } else if showSummary {
                SummaryPanel(model: model)
                    .frame(maxHeight: .infinity)
            } else if showScript {
                fullScriptSection
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var fullScriptSection: some View {
        let conversation = model.displayConversation
        let paragraphs = conversation.map { ConversationScriptFormatter.paragraphs(for: $0) } ?? []
        let organized = conversation?.organizedScript
        let mode = scriptMode.wrappedValue
        let hasUnpolishedTail: Bool = {
            guard let conversation else { return false }
            let input = ConversationScriptFormatter.scriptInputForPolishing(conversation, paragraphs: paragraphs)
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return organized?.coveredSource != input
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(model.t("panel.fullScript"), systemImage: "doc.text").font(.headline)
                if !paragraphs.isEmpty {
                    Text("\(paragraphs.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PanelFontButton(title: "전체 스크립트", value: $model.panelTypography.summary, defaultValue: 16)
                if model.organizingScript {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.organizeScript(automatic: false, force: false) }
                } label: {
                    Label(organized == nil ? model.t("script.polishAI") : (hasUnpolishedTail ? model.t("script.polishContinue") : model.t("script.polishRedo")), systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(model.organizingScript || paragraphs.isEmpty || model.current?.archivedAt != nil)

                Button {
                    guard let conversation else { return }
                    let text = ConversationScriptFormatter.plainText(for: conversation, mode: mode)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? model.t("action.copied") : model.t("action.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(paragraphs.isEmpty && organized == nil)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.panelLayout.setVisible(.script, false) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("전체 스크립트 패널 숨기기")
            }

            Picker("스크립트 표시", selection: scriptMode) {
                ForEach(ScriptDisplayMode.allCases, id: \.self) { option in
                    Text(option.title(in: model.uiLanguage)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            if let error = model.scriptError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if paragraphs.isEmpty && organized == nil {
                            ContentUnavailableView(
                                "정리된 스크립트가 없습니다",
                                systemImage: "text.alignleft",
                                description: Text("대화가 쌓이면 문장과 문단 단위로 깔끔하게 정리해 표시합니다.")
                            )
                        } else if mode == .organized, let organized, !organized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            organizedDocumentView(organized, hasPendingTail: hasUnpolishedTail)
                        } else {
                            if mode == .organized {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                                    Text("자동 문단 구성 중 · 상단 ‘AI 문단 정리’를 누르면 문장부호와 주제별 소제목까지 다듬습니다.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)
                            }
                            ForEach(paragraphs) { paragraph in
                                paragraphCard(paragraph, mode: mode == .organized ? .bilingual : mode)
                                    .id(paragraph.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("script-bottom")
                    }
                    .padding(4)
                }
                .readingScrollControl(model)
                .onChange(of: model.displayConversation?.transcript) { _, _ in
                    if model.followLive { proxy.scrollTo("script-bottom", anchor: .bottom) }
                }
                .onChange(of: model.displayConversation?.translations?.count) { _, _ in
                    if model.followLive { proxy.scrollTo("script-bottom", anchor: .bottom) }
                }
                .onChange(of: model.displayConversation?.organizedScript?.updatedAt) { _, _ in
                    if model.followLive { proxy.scrollTo("script-bottom", anchor: .bottom) }
                }
                .onChange(of: model.followLive) { _, follow in
                    if follow { proxy.scrollTo("script-bottom", anchor: .bottom) }
                }
                .onChange(of: model.selectedID) { _, _ in
                    proxy.scrollTo("script-bottom", anchor: .bottom)
                }
                .onAppear {
                    if model.followLive { proxy.scrollTo("script-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func organizedDocumentView(_ organized: OrganizedScript, hasPendingTail: Bool) -> some View {
        let sections = ConversationScriptFormatter.parseOrganizedSections(organized.text)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 문장·문단 정리본", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(organized.updatedAt, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let heading = section.heading, !heading.isEmpty {
                        Text(heading)
                            .font(.system(size: model.panelTypography.summary + 1, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(.top, 2)
                    }
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: model.panelTypography.summary))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            if hasPendingTail {
                HStack {
                    Text("이후 새로 추가된 발언이 있습니다.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("새 발언 이어 정리") {
                        Task { await model.organizeScript(automatic: false, force: false) }
                    }
                    .controlSize(.mini)
                    .disabled(model.organizingScript)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func paragraphCard(_ paragraph: ConversationScriptParagraph, mode: ScriptDisplayMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("문단 \(paragraph.ordinal)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                if let label = paragraph.sourceLabel {
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let start = paragraph.startDate {
                    if let end = paragraph.endDate, end.timeIntervalSince(start) >= 2 {
                        Text("\(start.formatted(date: .omitted, time: .standard)) – \(end.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text(start, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if mode == .bilingual || mode == .koreanOnly {
                if let translated = paragraph.translatedText {
                    Text(translated)
                        .font(.system(size: model.panelTypography.summary, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if mode == .koreanOnly {
                    Text("(번역 대기) \(paragraph.originalText)")
                        .font(.system(size: max(12, model.panelTypography.summary - 1)))
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if mode == .bilingual || mode == .originalOnly {
                Text(paragraph.originalText)
                    .font(.system(size: mode == .bilingual ? max(12, model.panelTypography.summary - 1) : model.panelTypography.summary))
                    .foregroundStyle(mode == .bilingual ? .secondary : .primary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
