import Foundation
import AVFoundation

struct ReplayMarker: Identifiable, Equatable {
    enum Kind: String { case speech, translation, advice, summary, keyword, audio }
    var id: String
    var kind: Kind
    var date: Date
    var offset: Double
    var title: String
}

/// Pure, time-indexed replay model that reproduces STT, translations, keywords, advice, summaries,
/// and audio clips at any timestamp along a conversation's timeline.
struct ReplayTimeline {
    let conversation: Conversation
    let startDate: Date
    let endDate: Date
    let duration: Double
    let clips: [AudioClipRecord]
    let markers: [ReplayMarker]

    init(conversation: Conversation) {
        self.conversation = conversation
        let sortedClips = (conversation.audioClips ?? []).sorted { $0.startedAt < $1.startedAt }
        self.clips = sortedClips

        var dates: [Date] = []
        dates.append(contentsOf: sortedClips.map(\.startedAt))
        dates.append(contentsOf: sortedClips.map(\.endedAt))
        dates.append(contentsOf: (conversation.transcriptSpans ?? []).map(\.date))
        dates.append(contentsOf: (conversation.translations ?? []).compactMap(\.date))
        dates.append(contentsOf: conversation.advice.map(\.date))
        dates.append(contentsOf: (conversation.summaryHistory ?? []).map(\.date))
        dates.append(contentsOf: (conversation.keywordHistory ?? []).map(\.date))
        if let currentKW = conversation.keywords { dates.append(currentKW.date) }
        if let allSummary = conversation.summaries?["all"] { dates.append(allSummary.updatedAt) }

        let minDate = dates.min() ?? conversation.date
        let maxDate = dates.max() ?? minDate
        self.startDate = minDate
        self.endDate = maxDate
        self.duration = max(1.0, maxDate.timeIntervalSince(minDate))

        var built: [ReplayMarker] = []
        for (i, clip) in sortedClips.enumerated() {
            built.append(ReplayMarker(id: "audio-\(clip.id)", kind: .audio, date: clip.startedAt, offset: max(0, clip.startedAt.timeIntervalSince(minDate)), title: "녹음 #\(i + 1) · \(clip.sourceSummary)"))
        }
        for (i, advice) in conversation.advice.enumerated() {
            built.append(ReplayMarker(id: "advice-\(advice.id)", kind: .advice, date: advice.date, offset: max(0, advice.date.timeIntervalSince(minDate)), title: "조언 #\(i + 1)"))
        }
        for (i, summary) in (conversation.summaryHistory ?? []).enumerated() {
            built.append(ReplayMarker(id: "summary-\(summary.id)", kind: .summary, date: summary.date, offset: max(0, summary.date.timeIntervalSince(minDate)), title: "요약 #\(i + 1)"))
        }
        for (i, kw) in (conversation.keywordHistory ?? []).enumerated() where !kw.terms.isEmpty {
            built.append(ReplayMarker(id: "kw-\(i)-\(kw.date.timeIntervalSince1970)", kind: .keyword, date: kw.date, offset: max(0, kw.date.timeIntervalSince(minDate)), title: "키워드: \(kw.terms.prefix(2).joined(separator: ", "))"))
        }
        self.markers = built.sorted { $0.offset < $1.offset }
    }

    func date(at offset: Double) -> Date {
        startDate.addingTimeInterval(min(duration, max(0, offset)))
    }

    func offset(for date: Date) -> Double {
        min(duration, max(0, date.timeIntervalSince(startDate)))
    }

    func activeClip(at offset: Double) -> (clip: AudioClipRecord, clipOffset: Double)? {
        let target = date(at: offset)
        for clip in clips {
            let local = target.timeIntervalSince(clip.startedAt)
            if local >= 0 && local < clip.duration {
                return (clip, local)
            }
        }
        return nil
    }

    func nextClipStartOffset(after offset: Double) -> Double? {
        let target = date(at: offset)
        return clips.first(where: { $0.startedAt > target }).map { self.offset(for: $0.startedAt) }
    }

    /// Reconstructs the conversation state as it appeared at `offset` seconds from start.
    func snapshot(at offset: Double) -> Conversation {
        let cutoff = date(at: offset)
        let isAtEnd = offset >= duration - 0.05
        if isAtEnd { return conversation }

        var copy = conversation
        let allSpans = conversation.transcriptSpans ?? []
        if !allSpans.isEmpty {
            let visibleSpans = allSpans.filter { $0.date <= cutoff }
            copy.transcriptSpans = visibleSpans
            if let lastVisible = visibleSpans.last {
                copy.transcript = String(conversation.transcript.prefix(lastVisible.end))
            } else {
                // Keep any legacy untimed prefix only if there were no timed spans before it.
                copy.transcript = ""
            }
        } else {
            // No span timestamps exist (legacy record): reveal full text proportionally or at end.
            let ratio = min(1, max(0, offset / max(1, duration)))
            copy.transcript = String(conversation.transcript.prefix(Int(Double(conversation.transcript.count) * ratio)))
        }

        let transcriptLength = copy.transcript.count
        copy.translations = (conversation.translations ?? []).filter { entry in
            let dateOK = (entry.date ?? startDate) <= cutoff
            let rangeOK = entry.sourceEnd.map { $0 <= transcriptLength } ?? true
            return dateOK && rangeOK
        }

        copy.advice = conversation.advice.filter { $0.date <= cutoff }

        let visibleKeywordHistory = (conversation.keywordHistory ?? []).filter { $0.date <= cutoff }
        copy.keywordHistory = visibleKeywordHistory
        if let latestKW = visibleKeywordHistory.last {
            copy.keywords = latestKW
        } else if let currentKW = conversation.keywords, currentKW.date <= cutoff {
            copy.keywords = currentKW
        } else {
            copy.keywords = nil
        }

        let visibleSummaryHistory = (conversation.summaryHistory ?? []).filter { $0.date <= cutoff }
        copy.summaryHistory = visibleSummaryHistory
        if let latestSummary = visibleSummaryHistory.last {
            var sums = copy.summaries ?? [:]
            sums["all"] = SummaryState(text: latestSummary.text, coveredSource: copy.transcript, updatedAt: latestSummary.date)
            copy.summaries = sums
            copy.title = latestSummary.title
            copy.preview = latestSummary.preview
        } else if let currentAll = conversation.summaries?["all"], currentAll.updatedAt <= cutoff {
            copy.summaries = ["all": currentAll]
        } else {
            copy.summaries = nil
        }

        return copy
    }
}

@MainActor
final class ConversationReplayController: ObservableObject {
    @Published private(set) var timeline: ReplayTimeline
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var playbackRate: Float = 1.0 {
        didSet { player?.rate = playbackRate }
    }
    @Published var muted = false {
        didSet { player?.volume = muted ? 0 : 1 }
    }
    @Published var statusNote: String?

    let recordingsRoot: URL
    private var player: AVAudioPlayer?
    private var activeClipID: UUID?
    private var ticker: Task<Void, Never>?
    private var lastTickWall = Date()

    var currentDate: Date { timeline.date(at: currentTime) }
    var currentSnapshot: Conversation { timeline.snapshot(at: currentTime) }
    var hasAudio: Bool { !timeline.clips.isEmpty }

    init(conversation: Conversation, recordingsRoot: URL) {
        self.timeline = ReplayTimeline(conversation: conversation)
        self.recordingsRoot = recordingsRoot
        self.currentTime = 0
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if currentTime >= timeline.duration - 0.05 { currentTime = 0 }
        isPlaying = true
        lastTickWall = Date()
        syncAudio(forceSeek: true)
        startTicker()
    }

    func pause() {
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        player?.pause()
    }

    func seek(to offset: Double) {
        currentTime = min(timeline.duration, max(0, offset))
        lastTickWall = Date()
        syncAudio(forceSeek: true)
    }

    func seek(to date: Date) {
        seek(to: timeline.offset(for: date))
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        pause()
        player?.stop()
        player = nil
        activeClipID = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        let wallDelta = now.timeIntervalSince(lastTickWall)
        lastTickWall = now

        if let player, player.isPlaying, let clipID = activeClipID,
           let clip = timeline.clips.first(where: { $0.id == clipID }) {
            let clipStartOffset = timeline.offset(for: clip.startedAt)
            currentTime = min(timeline.duration, clipStartOffset + player.currentTime)
        } else {
            currentTime = min(timeline.duration, currentTime + wallDelta * Double(playbackRate))
            syncAudio(forceSeek: false)
        }

        if currentTime >= timeline.duration - 0.02 {
            currentTime = timeline.duration
            pause()
        }
    }

    private func syncAudio(forceSeek: Bool) {
        guard let active = timeline.activeClip(at: currentTime) else {
            if player?.isPlaying == true { player?.pause() }
            activeClipID = nil
            return
        }
        let url = RecordingStorage.clipURL(conversationID: timeline.conversation.id, filename: active.clip.filename, root: recordingsRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusNote = "녹음 파일(\(active.clip.filename))을 찾을 수 없어 타임라인만 재생합니다."
            player?.stop()
            player = nil
            activeClipID = nil
            return
        }

        if activeClipID != active.clip.id || player == nil {
            do {
                let created = try AVAudioPlayer(contentsOf: url)
                created.enableRate = true
                created.rate = playbackRate
                created.volume = muted ? 0 : 1
                created.prepareToPlay()
                player = created
                activeClipID = active.clip.id
                statusNote = nil
            } catch {
                statusNote = "오디오 재생 오류: \(error.localizedDescription)"
                player = nil
                activeClipID = nil
                return
            }
        }

        guard let player else { return }
        if forceSeek || abs(player.currentTime - active.clipOffset) > 0.35 {
            player.currentTime = min(max(0, active.clipOffset), max(0, player.duration - 0.05))
        }
        player.rate = playbackRate
        player.volume = muted ? 0 : 1
        if isPlaying && !player.isPlaying {
            player.play()
        } else if !isPlaying && player.isPlaying {
            player.pause()
        }
    }
}
