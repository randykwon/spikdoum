import SwiftUI
import UniformTypeIdentifiers

enum WorkspacePanelKind: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case stt
    case translation
    case coach
    case summaryScript

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .stt: return "mic.fill"
        case .translation: return "character.bubble"
        case .coach: return "sparkles"
        case .summaryScript: return "doc.text"
        }
    }

    func title(in ui: ResolvedUILanguage) -> String {
        switch self {
        case .stt: return L10n.t("panel.stt", lang: ui)
        case .translation: return L10n.t("panel.translation", lang: ui)
        case .coach: return L10n.t("panel.coach", lang: ui)
        case .summaryScript: return L10n.t("panel.summaryScriptToggle", lang: ui)
        }
    }
}

enum HideablePanel: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case stt
    case translation
    case coach
    case summary
    case script

    var id: String { rawValue }
}

struct PanelLayout: Codable, Equatable, Sendable {
    static let storageKey = "panelLayoutOrderV1"
    static let defaultOrder: [WorkspacePanelKind] = [.stt, .translation, .coach, .summaryScript]

    var splitOrder: [WorkspacePanelKind] = defaultOrder
    var linkedSummaryOnLeft: Bool = false
    var summaryScriptReversed: Bool = false
    var hiddenPanels: Set<HideablePanel> = []

    init(
        splitOrder: [WorkspacePanelKind] = defaultOrder,
        linkedSummaryOnLeft: Bool = false,
        summaryScriptReversed: Bool = false,
        hiddenPanels: Set<HideablePanel> = []
    ) {
        self.splitOrder = Self.normalized(splitOrder)
        self.linkedSummaryOnLeft = linkedSummaryOnLeft
        self.summaryScriptReversed = summaryScriptReversed
        self.hiddenPanels = hiddenPanels
        ensureAtLeastOneMainPanelVisible()
    }

    private enum CodingKeys: String, CodingKey {
        case splitOrder, linkedSummaryOnLeft, summaryScriptReversed, hiddenPanels
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let order = try values.decodeIfPresent([WorkspacePanelKind].self, forKey: .splitOrder) ?? Self.defaultOrder
        let linkedLeft = try values.decodeIfPresent(Bool.self, forKey: .linkedSummaryOnLeft) ?? false
        let reversed = try values.decodeIfPresent(Bool.self, forKey: .summaryScriptReversed) ?? false
        let hidden = try values.decodeIfPresent(Set<HideablePanel>.self, forKey: .hiddenPanels) ?? []
        self.init(splitOrder: order, linkedSummaryOnLeft: linkedLeft, summaryScriptReversed: reversed, hiddenPanels: hidden)
    }

    static func normalized(_ order: [WorkspacePanelKind]) -> [WorkspacePanelKind] {
        var result: [WorkspacePanelKind] = []
        for panel in order where !result.contains(panel) {
            result.append(panel)
        }
        for panel in defaultOrder where !result.contains(panel) {
            result.append(panel)
        }
        return result
    }

    func isVisible(_ panel: HideablePanel) -> Bool {
        !hiddenPanels.contains(panel)
    }

    var hasHiddenPanels: Bool {
        !hiddenPanels.isEmpty
    }

    var hasAnySummaryScriptVisible: Bool {
        isVisible(.summary) || isVisible(.script)
    }

    /// Always keeps at least one core conversation panel (STT, Translation, or Coach) visible.
    func canHide(_ panel: HideablePanel, includeCoach: Bool = true) -> Bool {
        guard isVisible(panel) else { return false }
        switch panel {
        case .summary, .script:
            return true
        case .stt, .translation, .coach:
            let core: [HideablePanel] = includeCoach ? [.stt, .translation, .coach] : [.stt, .translation]
            let visibleCore = core.filter { isVisible($0) }
            return visibleCore.count > 1 || !visibleCore.contains(panel)
        }
    }

    mutating func setVisible(_ panel: HideablePanel, _ visible: Bool, includeCoach: Bool = true) {
        if visible {
            hiddenPanels.remove(panel)
        } else if canHide(panel, includeCoach: includeCoach) {
            hiddenPanels.insert(panel)
        }
        ensureAtLeastOneMainPanelVisible()
    }

    mutating func toggle(_ panel: HideablePanel, includeCoach: Bool = true) {
        setVisible(panel, !isVisible(panel), includeCoach: includeCoach)
    }

    mutating func showAllPanels() {
        hiddenPanels = []
    }

    private mutating func ensureAtLeastOneMainPanelVisible() {
        let core: [HideablePanel] = [.stt, .translation, .coach]
        if !core.contains(where: { !hiddenPanels.contains($0) }) {
            hiddenPanels.remove(.stt)
        }
    }

    func visibleSplitPanels(includeSummaryScript: Bool) -> [WorkspacePanelKind] {
        let filtered = Self.normalized(splitOrder).filter { panel in
            switch panel {
            case .stt: return isVisible(.stt)
            case .translation: return isVisible(.translation)
            case .coach: return isVisible(.coach)
            case .summaryScript: return includeSummaryScript && hasAnySummaryScriptVisible
            }
        }
        return filtered.isEmpty ? [.stt] : filtered
    }

    mutating func move(_ panel: WorkspacePanelKind, by delta: Int, includeSummaryScript: Bool) {
        splitOrder = Self.normalized(splitOrder)
        let visible = visibleSplitPanels(includeSummaryScript: includeSummaryScript)
        guard let visibleIndex = visible.firstIndex(of: panel) else { return }
        let targetVisibleIndex = visibleIndex + delta
        guard targetVisibleIndex >= 0, targetVisibleIndex < visible.count else { return }
        let neighbor = visible[targetVisibleIndex]
        guard let fromIndex = splitOrder.firstIndex(of: panel),
              let toIndex = splitOrder.firstIndex(of: neighbor) else { return }
        splitOrder.swapAt(fromIndex, toIndex)
    }

    mutating func move(_ source: WorkspacePanelKind, to target: WorkspacePanelKind) {
        guard source != target else { return }
        splitOrder = Self.normalized(splitOrder)
        guard let fromIndex = splitOrder.firstIndex(of: source),
              let toIndex = splitOrder.firstIndex(of: target) else { return }
        let item = splitOrder.remove(at: fromIndex)
        splitOrder.insert(item, at: toIndex)
    }

    mutating func swapLinkedSide() {
        linkedSummaryOnLeft.toggle()
    }

    mutating func toggleSummaryScriptOrder() {
        summaryScriptReversed.toggle()
    }

    mutating func reset() {
        splitOrder = Self.defaultOrder
        linkedSummaryOnLeft = false
        summaryScriptReversed = false
        hiddenPanels = []
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

struct PanelReorderBar: View {
    let title: String
    let icon: String
    let dragPayload: String
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeftHelp: String
    let moveRightHelp: String
    let dragHelp: String
    var onMoveLeft: () -> Void
    var onMoveRight: () -> Void
    var extraActionIcon: String? = nil
    var extraActionHelp: String? = nil
    var onExtraAction: (() -> Void)? = nil
    var hideHelp: String = "이 패널 숨기기"
    var onHide: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .help(dragHelp)
            .draggable(dragPayload) {
                Label(title, systemImage: icon)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 4)

            if let extraActionIcon, let onExtraAction {
                Button(action: onExtraAction) {
                    Image(systemName: extraActionIcon)
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(extraActionHelp ?? "")
            }

            Button(action: onMoveLeft) {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canMoveLeft ? .secondary : .quaternary)
            .disabled(!canMoveLeft)
            .help(moveLeftHelp)

            Button(action: onMoveRight) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canMoveRight ? .secondary : .quaternary)
            .disabled(!canMoveRight)
            .help(moveRightHelp)

            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(hideHelp)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
