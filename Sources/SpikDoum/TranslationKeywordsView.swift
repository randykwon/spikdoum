import SwiftUI

struct TranslationKeywordsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let terms: [String] = {
            guard let conversation = model.displayConversation else { return [] }
            if model.recentSeconds == 0 { return conversation.allKeywords }
            let recent = conversation.keywords?.terms ?? []
            return recent.isEmpty ? conversation.allKeywords : recent
        }()
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(model.recentSeconds == 0 ? "\(model.t("keywords.accumulated")) (\(terms.count))" : model.t("keywords.recent"), systemImage: "number").font(.caption.bold()).foregroundStyle(.purple)
                Spacer()
                if let error = model.keywordError { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(error) }
                if model.extractingKeywords { ProgressView().controlSize(.mini) }
                Button { Task { await model.extractKeywords() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("키워드 갱신")
                    .disabled(!model.followLive || model.extractingKeywords || model.current?.archivedAt != nil || (model.current?.transcript.isEmpty ?? true))
            }
            if !terms.isEmpty {
                let latestSet = Set((model.displayConversation?.keywords?.terms ?? []).map { $0.lowercased() })
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: max(80, model.panelTypography.keywords * 4)))], alignment: .leading, spacing: 5) {
                            ForEach(terms, id: \.self) { term in
                                let isLatest = latestSet.contains(term.lowercased())
                                Text(term).font(.system(size: model.panelTypography.keywords, weight: isLatest ? .semibold : .regular)).lineLimit(2)
                                    .textSelection(.enabled).padding(.horizontal, 7).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.purple.opacity(isLatest ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 6))
                                    .id(term)
                            }
                        }
                    }.frame(maxHeight: max(64, model.panelTypography.keywords * 3.5)).readingScrollControl(model)
                    .onChange(of: terms.first) { _, first in
                        if model.followLive, let first { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            } else {
                Text(model.extractingKeywords ? "키워드 추출 중…" : "대화가 쌓이면 키워드가 번역 옆에 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .leading)
            }
        }.padding(8).background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .task(id: model.selectedID) { if model.showTranslationKeywords { await model.extractKeywords(automatic: true) } }
    }
}
