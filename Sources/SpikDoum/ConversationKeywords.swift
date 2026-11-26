import Foundation
import FoundationModels

struct ConversationKeywords: Codable {
    var terms: [String]
    var date: Date
    var source: String
    var relatedTerms: [String: [String]]? = nil

    init(terms: [String], date: Date, source: String, relatedTerms: [String: [String]]? = nil) {
        self.terms = terms
        self.date = date
        self.source = source
        self.relatedTerms = relatedTerms
    }
}

@Generable
struct ExtractedKeywordItem {
    @Guide(description: "일상 기본 단어를 제외하고 원문에 실제 등장하는 핵심 전문 용어·생소한 용어·고유명사·약어·핵심 도메인 개념 1개 (원문 언어 그대로).")
    var term: String
    @Guide(description: "이 용어를 이해하거나 대화에 활용하는 데 도움이 되는 관련 전문 용어·쉬운 동의어·연관 표현 2~3개 (짧은 단어/구절, 기본 일상어 제외).")
    var related: [String]
}

@Generable
struct ExtractedKeywords {
    @Guide(description: "대화에서 기본 일상 단어를 제외한 핵심 용어 또는 생소한 용어 0~6개와 각 용어의 관련 단어. 핵심·생소 용어가 없으면 반드시 빈 배열 반환.")
    var items: [ExtractedKeywordItem]
}

enum KeywordPolicy {
    /// Trivial everyday greetings, pronouns, time words, and generic filler nouns that should never be surfaced as keywords.
    private static let basicStopwords: Set<String> = [
        // Korean
        "안녕", "안녕하세요", "감사", "감사합니다", "감사 인사", "고맙습니다", "고마워", "고마워요",
        "죄송", "죄송합니다", "미안", "미안해요", "실례", "반갑습니다", "환영", "인사",
        "오늘", "내일", "어제", "지금", "요즘", "최근", "시간", "하루", "날씨",
        "사람", "우리", "여러분", "저희", "여기", "거기", "저기", "이것", "그것", "저것",
        "이야기", "얘기", "말씀", "생각", "느낌", "마음", "기분", "대화",
        "정말", "진짜", "너무", "아주", "매우", "조금", "많이", "그냥", "이제", "다시",
        "먼저", "함께", "같이", "항상", "자주", "가끔", "보통", "원래", "사실", "일단", "아마",
        "부분", "경우", "정도", "내용", "문제", "질문", "대답", "답변", "설명", "도움", "부탁",
        "시작", "마지막", "처음", "이번", "다음", "지난", "하나", "모두", "전부",
        "좋아요", "괜찮아요", "네", "아니요", "예", "확인", "진행", "준비", "필요", "가능", "중요", "기본", "일반",
        // English
        "hello", "hi", "hey", "thanks", "thank you", "sorry", "please", "yes", "no", "okay", "ok",
        "well", "good", "great", "nice", "bad", "very", "really", "just", "like", "actually", "basically",
        "thing", "things", "stuff", "people", "person", "someone", "everyone", "anyone", "nobody",
        "today", "tomorrow", "yesterday", "now", "here", "there", "time", "day", "days", "week", "year",
        "way", "life", "work", "world", "man", "woman", "friend", "home", "house",
        "question", "answer", "idea", "point", "part", "place", "case", "fact", "lot", "bit", "kind", "sort",
        "something", "anything", "nothing", "everything", "talk", "chat", "word", "words",
        // Japanese
        "こんにちは", "こんばんは", "おはよう", "おはようございます", "ありがとう", "ありがとうございます",
        "すみません", "ごめんなさい", "よろしく", "よろしくお願いします", "お疲れ様", "お疲れ様です",
        "はい", "いいえ", "うん", "ええ", "そう", "そうです", "そうですね",
        "今日", "明日", "昨日", "今", "時間", "毎日", "最近", "最初", "最後", "今回", "次回",
        "人", "みんな", "私", "わたし", "僕", "ぼく", "あなた", "こちら", "そちら",
        "ここ", "そこ", "あそこ", "これ", "それ", "あれ", "こと", "もの", "ところ",
        "話", "会話", "気持ち", "考え", "本当", "本当に", "とても", "すごく", "ちょっと", "たくさん",
        "いつも", "一緒", "大丈夫", "すごい", "いい", "よい", "感謝", "挨拶", "質問", "問題", "お願い",
        // Chinese
        "你好", "您好", "谢谢", "感谢", "对不起", "抱歉", "没关系", "好的", "是的", "不是",
        "今天", "明天", "昨天", "现在", "时间", "人们", "大家", "我们", "你们", "他们",
        "这里", "那里", "这个", "那个", "事情", "东西", "问题", "想法", "感觉", "对话",
        "真的", "非常", "很多", "一点", "一起", "总是", "最近", "开始", "最后"
    ]

    static func isBasicWord(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = trimmed.lowercased()
        if lower.isEmpty { return true }
        if basicStopwords.contains(lower) { return true }
        // Single-character pure ASCII or pure Hiragana/Katakana/Hangul words are almost always trivial filler.
        if trimmed.count == 1 {
            let scalars = trimmed.unicodeScalars
            let isAsciiLetterOrDigit = scalars.allSatisfy { $0.isASCII }
            let isHangul = scalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
            let isKana = scalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
            if isAsciiLetterOrDigit || isHangul || isKana { return true }
        }
        return false
    }

    static func clean(_ terms: [String], source: String) -> [String] {
        var seen: Set<String> = []
        return terms.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard !term.isEmpty, term.count <= 40, !term.contains("\n"),
                  !isBasicWord(term),
                  source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }.prefix(8).map { $0 }
    }

    static func cleanRelated(_ raw: [String: [String]], validTerms: [String]) -> [String: [String]] {
        let canonicalByLower: [String: String] = Dictionary(
            validTerms.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [String: [String]] = [:]
        for (rawKey, rawValues) in raw {
            let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard let canonicalKey = canonicalByLower[trimmedKey.lowercased()] else { continue }
            var seen: Set<String> = [canonicalKey.lowercased()]
            var cleanedList = result[canonicalKey] ?? []
            for existing in cleanedList { seen.insert(existing.lowercased()) }
            for value in rawValues {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'•-")))
                guard !cleaned.isEmpty, cleaned.count <= 36, !cleaned.contains("\n"),
                      !isBasicWord(cleaned),
                      seen.insert(cleaned.lowercased()).inserted else { continue }
                cleanedList.append(cleaned)
                if cleanedList.count >= 4 { break }
            }
            if !cleanedList.isEmpty {
                result[canonicalKey] = cleanedList
            }
        }
        return result
    }

    /// Returns accumulated deduplicated keywords ordered newest-first so the latest keywords appear at the top.
    static func merged(current: ConversationKeywords?, history: [ConversationKeywords]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let snapshots = (current.map { [$0] } ?? []) + history.reversed()
        for snapshot in snapshots {
            for term in snapshot.terms {
                let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, !isBasicWord(cleaned), seen.insert(cleaned.lowercased()).inserted else { continue }
                result.append(cleaned)
            }
        }
        return result
    }

    /// Returns accumulated deduplicated related words per keyword (keyed by lowercased keyword), newest-first.
    static func mergedRelated(current: ConversationKeywords?, history: [ConversationKeywords]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var seenByKey: [String: Set<String>] = [:]
        let snapshots = (current.map { [$0] } ?? []) + history.reversed()
        for snapshot in snapshots {
            guard let map = snapshot.relatedTerms else { continue }
            for (term, relatedList) in map {
                let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }
                var seen = seenByKey[key] ?? [key]
                var acc = result[key] ?? []
                for word in relatedList {
                    let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
                    acc.append(cleaned)
                    if acc.count >= 5 { break }
                }
                if !acc.isEmpty {
                    result[key] = acc
                    seenByKey[key] = seen
                }
            }
        }
        return result
    }

    static func parse(_ text: String) throws -> [String] {
        try parseWithRelated(text).terms
    }

    static func parseWithRelated(_ text: String) throws -> (terms: [String], related: [String: [String]]) {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            var lines = json.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            json = lines.joined(separator: "\n")
        }
        struct RichItem: Decodable {
            var term: String
            var related: [String]?
        }
        struct Output: Decodable {
            var items: [RichItem]?
            var keywords: [String]?
            var related: [String: [String]]?
        }
        let decoded = try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        if let items = decoded.items {
            var terms: [String] = []
            var related: [String: [String]] = [:]
            for item in items {
                terms.append(item.term)
                if let rel = item.related, !rel.isEmpty {
                    related[item.term] = rel
                }
            }
            return (terms, related)
        }
        if let keywords = decoded.keywords {
            return (keywords, decoded.related ?? [:])
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing keywords/items array"))
    }
}
