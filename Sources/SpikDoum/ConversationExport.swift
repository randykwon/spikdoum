import Foundation
import AppKit
import UniformTypeIdentifiers

enum ConversationSearch {
    static func filter(_ conversations: [Conversation], query: String, archived: Bool) -> [Conversation] {
        let scoped = conversations.filter { ($0.archivedAt != nil) == archived }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scoped }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return scoped.filter { item in
            if item.title.range(of: trimmed, options: options) != nil { return true }
            if let preview = item.preview, preview.range(of: trimmed, options: options) != nil { return true }
            if item.transcript.range(of: trimmed, options: options) != nil { return true }
            if (item.translations ?? []).contains(where: { $0.translated.range(of: trimmed, options: options) != nil }) { return true }
            if (item.summaries?.values ?? [:].values).contains(where: { $0.text.range(of: trimmed, options: options) != nil }) { return true }
            if item.allKeywords.contains(where: { $0.range(of: trimmed, options: options) != nil }) { return true }
            return false
        }
    }
}

enum ConversationExport {
    static func suggestedFilename(for conversation: Conversation) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = conversation.title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "SpikDoum-대화" : String(cleaned.prefix(60))
        return base + ".md"
    }

    static func markdown(for conversation: Conversation) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        lines.append("# \(conversation.title)")
        lines.append("")
        lines.append("- 일시: \(formatter.string(from: conversation.date))")
        if let archivedAt = conversation.archivedAt {
            lines.append("- 아카이브 시각: \(formatter.string(from: archivedAt))")
        }

        if let summary = conversation.summaries?["all"], !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## 전체 요약")
            lines.append("")
            lines.append(summary.text)
        }

        let speakerSummaries = (conversation.summaries ?? [:])
            .filter { $0.key.hasPrefix("speaker-") }
            .sorted { $0.key < $1.key }
        if !speakerSummaries.isEmpty {
            lines.append("")
            lines.append("## 화자별 요약")
            for (key, state) in speakerSummaries {
                let speakerNumber = key.replacingOccurrences(of: "speaker-", with: "")
                lines.append("")
                lines.append("### 화자 \(speakerNumber)")
                lines.append("")
                lines.append(state.text)
            }
        }

        let allKeywords = conversation.allKeywords
        if !allKeywords.isEmpty {
            lines.append("")
            lines.append("## 핵심 키워드")
            lines.append("")
            lines.append(allKeywords.map { "`\($0)`" }.joined(separator: " · "))
        }

        if let organized = conversation.organizedScript,
           !organized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## 정리된 전체 스크립트")
            lines.append("")
            lines.append(organized.text)
        }

        let blocks = ConversationBlocks.make(conversation)
        if !blocks.isEmpty {
            lines.append("")
            lines.append("## 대화 원문 및 번역")
            for block in blocks {
                lines.append("")
                lines.append("### 묶음 #\(block.ordinal)")
                lines.append("")
                lines.append(block.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let translation = block.translation {
                    lines.append("")
                    lines.append("> **번역:** \(translation.translated.replacingOccurrences(of: "\n", with: "\n> "))")
                }
            }
        } else if !conversation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## 대화 원문")
            lines.append("")
            lines.append(conversation.transcript)
        }

        if !conversation.advice.isEmpty {
            lines.append("")
            lines.append("## 대화 코치 조언")
            for (offset, item) in conversation.advice.enumerated() {
                lines.append("")
                lines.append("### 조언 #\(offset + 1) (\(formatter.string(from: item.date)))")
                lines.append("")
                lines.append(item.text)
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func saveWithPanel(_ conversation: Conversation) -> String? {
        let panel = NSSavePanel()
        panel.title = "대화를 Markdown으로 내보내기"
        panel.nameFieldStringValue = suggestedFilename(for: conversation)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try markdown(for: conversation).write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "내보내기 실패: \(error.localizedDescription)"
        }
    }
}
