import Foundation

extension AppModel {
    var activePresentation: PresentationSession {
        current?.presentation ?? PresentationSession()
    }

    var presentationLanguageCode: String {
        if isAutoDetectLanguage {
            return detectedSTTLanguage?.code ?? lastFixedLanguage
        }
        return language
    }

    func switchPerspective(_ next: AppPerspective) {
        let changed = perspective != next
        if perspective == .presentation && next != .presentation {
            pausePresentationTimer()
            pptSlideSync.stop()
        }
        if perspective == .learning && next != .learning {
            stopLearningAutoCaptureLoop()
        }
        perspective = next
        presentationError = nil

        // Apply recommended audio routing only when NOT actively listening (never interrupt live capture).
        if !listening && !starting, let audio = next.recommendedAudio {
            if next == .presentation && activePresentation.inQAMode {
                includeSystemAudio = true
                systemAudioOnly = false
            } else {
                includeSystemAudio = audio.includeSystem
                systemAudioOnly = audio.systemOnly
            }
        }

        switch next {
        case .standard:
            break
        case .presentation:
            if simpleFastMode { simpleFastMode = false }
            ensurePresentationSession()
            if pptSlideSync.autoImportNotes && !pptSlideSync.isEnabled {
                pptSlideSync.setEnabled(true)
            }
            if changed && !listening {
                presetNotice = "프레젠테이션 모드 · 내 마이크 기준 (열려 있는 PowerPoint 메모 자동 연동)"
            }
        case .meeting:
            if simpleFastMode { simpleFastMode = false }
            autoAdvice = true
            panelLayout.setVisible(.summary, true)
            panelLayout.setVisible(.coach, true)
            if changed && !listening {
                presetNotice = "미팅 모드 · 마이크 + Mac 소리 양방향 · 요약·코치 최적화"
            }
        case .learning:
            if simpleFastMode { simpleFastMode = false }
            showTranslationKeywords = true
            panelLayout.setVisible(.summary, true)
            Task { [weak self] in
                await self?.refreshLearningWindows()
                if self?.learningCapturer.autoCaptureEnabled == true {
                    self?.startLearningAutoCaptureLoop()
                }
            }
            if changed && !listening {
                presetNotice = "온라인 교육 모드 · Mac 소리 자막 · 조용한 강의 화면 기록 지원 (⌥⌘S)"
            }
        }
    }

    func ensurePresentationSession() {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[index].archivedAt == nil else { return }
        if conversations[index].presentation == nil {
            conversations[index].presentation = PresentationSession()
            scheduleSave()
        }
    }

    func updatePresentation(saveImmediately: Bool = false, _ body: (inout PresentationSession) -> Void) {
        mutatePresentation(saveImmediately: saveImmediately, body)
    }

    func mutatePresentation(saveImmediately: Bool = false, _ body: (inout PresentationSession) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[index].archivedAt == nil else { return }
        var session = conversations[index].presentation ?? PresentationSession()
        body(&session)
        conversations[index].presentation = session
        if saveImmediately { save() } else { scheduleSave() }
    }

    // MARK: - Timer & Presentation Lifecycle

    func startPresentationTimer() {
        guard !presentationTimerRunning, current?.archivedAt == nil else { return }
        ensurePresentationSession()
        presentationTimerRunning = true
        presentationTimerTask?.cancel()
        presentationTimerTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.presentationTimerRunning else { return }
                ticks += 1
                self.tickPresentationTimer(persistNow: ticks % 10 == 0)
            }
        }
    }

    private func tickPresentationTimer(persistNow: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[index].archivedAt == nil else {
            pausePresentationTimer()
            return
        }
        var session = conversations[index].presentation ?? PresentationSession()
        session.elapsedSeconds += 1
        let cards = PresentationNotesParser.parse(session.notesMarkdown)
        if !cards.isEmpty {
            let safeIdx = min(max(0, session.activeCardIndex), cards.count - 1)
            session.sectionElapsed[cards[safeIdx].id, default: 0] += 1
        }
        conversations[index].presentation = session
        if persistNow { scheduleSave() }
    }

    func pausePresentationTimer() {
        presentationTimerTask?.cancel()
        presentationTimerTask = nil
        if presentationTimerRunning {
            presentationTimerRunning = false
            scheduleSave()
        }
    }

    func togglePresentationTimer() {
        if presentationTimerRunning { pausePresentationTimer() } else { startPresentationTimer() }
    }

    func resetPresentationTimer() {
        pausePresentationTimer()
        mutatePresentation(saveImmediately: true) {
            $0.elapsedSeconds = 0
            $0.sectionElapsed = [:]
        }
    }

    func startPresentation() {
        startPresentationTimer()
        if !listening && !starting {
            Task { [weak self] in await self?.start() }
        }
    }

    func stopPresentation() {
        pausePresentationTimer()
        if listening {
            pauseListening()
        }
    }

    func togglePresentationQAMode() {
        let enteringQA = !activePresentation.inQAMode
        mutatePresentation(saveImmediately: true) {
            $0.inQAMode = enteringQA
        }
        let targetIncludeSystem = enteringQA
        let targetSystemOnly = false
        let audioChanged = (includeSystemAudio != targetIncludeSystem) || (systemAudioOnly != targetSystemOnly)
        includeSystemAudio = targetIncludeSystem
        systemAudioOnly = targetSystemOnly
        if enteringQA {
            autoAdvice = true
            presetNotice = "Q&A 모드 전환 · 청중 질문(Mac 소리) + 내 마이크 동시 청취 및 AI 답변 코치 활성화"
        } else {
            presetNotice = "발표 모드로 복귀 · 내 마이크 중심으로 전환"
        }
        if listening && audioChanged {
            scheduleLiveCaptureRestart()
        }
    }

    func duplicatePresentationToNewConversation() {
        pausePresentationTimer()
        let baseTitle = (current?.title ?? "발표")
            .replacingOccurrences(of: " (발표)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cloned = activePresentation.clonedForNewRun()
        lastKeywordAttempt = .distantPast
        resumeReading()
        selectedLiveBlockID = nil
        stop()
        var item = Conversation(title: "\(baseTitle.isEmpty ? "새 발표" : baseTitle) (발표)")
        item.presentation = cloned
        conversations.insert(item, at: 0)
        selectedID = item.id
        lastContext = ""
        detectedSTTLanguage = nil
        translationPreview = nil
        save()
        presetNotice = "발표 세트(타이머·큐카드·체크리스트)를 새 대화로 복제했습니다."
    }

    // MARK: - Checklist & Custom Phrases

    func addChecklistItem(_ rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutatePresentation(saveImmediately: true) { session in
            var item = PresentationChecklistItem(title: trimmed)
            let transcript = current?.transcript ?? ""
            if !transcript.isEmpty {
                let checked = PresentationChecklistMatcher.apply(transcript: transcript, to: [item])
                if let first = checked.items.first { item = first }
            }
            session.checklist.append(item)
        }
    }

    func toggleChecklistItem(_ id: UUID) {
        mutatePresentation(saveImmediately: true) { session in
            guard let idx = session.checklist.firstIndex(where: { $0.id == id }) else { return }
            session.checklist[idx].isChecked.toggle()
            session.checklist[idx].manuallyOverridden = true
            session.checklist[idx].autoMatched = false
            session.checklist[idx].matchedAt = session.checklist[idx].isChecked ? Date() : nil
        }
    }

    func removeChecklistItem(_ id: UUID) {
        mutatePresentation(saveImmediately: true) { session in
            session.checklist.removeAll { $0.id == id }
        }
    }

    func resetChecklist() {
        mutatePresentation(saveImmediately: true) { session in
            for idx in session.checklist.indices {
                session.checklist[idx].isChecked = false
                session.checklist[idx].autoMatched = false
                session.checklist[idx].manuallyOverridden = false
                session.checklist[idx].matchedAt = nil
            }
        }
    }

    func addCustomPhrase(category: SignpostingCategory, text: String, meaning: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        mutatePresentation(saveImmediately: true) { session in
            session.customPhrases.insert(
                PresentationPhrase(
                    category: category,
                    text: trimmedText,
                    meaning: trimmedMeaning,
                    isCustom: true
                ),
                at: 0
            )
        }
    }

    func removeCustomPhrase(_ id: UUID) {
        mutatePresentation(saveImmediately: true) { session in
            session.customPhrases.removeAll { $0.id == id }
        }
    }

    func applyDurationStarterChecklist() {
        let starters = PresentationAdvisor.starterChecklist(for: activePresentation.targetMinutes)
        mutatePresentation(saveImmediately: true) { session in
            let existing = Set(session.checklist.map { PresentationChecklistMatcher.normalize($0.displayLabel) })
            let transcript = current?.transcript ?? ""
            for var item in starters {
                let norm = PresentationChecklistMatcher.normalize(item.displayLabel)
                guard !existing.contains(norm) else { continue }
                if !transcript.isEmpty {
                    let matched = PresentationChecklistMatcher.apply(transcript: transcript, to: [item])
                    if let first = matched.items.first { item = first }
                }
                session.checklist.append(item)
            }
        }
    }

    func acceptRecommendedChecklistItem(_ item: PresentationChecklistItem) {
        mutatePresentation(saveImmediately: true) { session in
            let norm = PresentationChecklistMatcher.normalize(item.displayLabel)
            guard !session.checklist.contains(where: { PresentationChecklistMatcher.normalize($0.displayLabel) == norm }) else { return }
            var copy = item
            copy.id = UUID()
            let transcript = current?.transcript ?? ""
            if !transcript.isEmpty {
                let checked = PresentationChecklistMatcher.apply(transcript: transcript, to: [copy])
                if let first = checked.items.first { copy = first }
            }
            session.checklist.append(copy)
        }
        presentationRecommendation?.checklist.removeAll { $0.id == item.id }
        if (presentationRecommendation?.checklist.isEmpty ?? true) && (presentationRecommendation?.phrases.isEmpty ?? true) {
            presentationRecommendation = nil
        }
    }

    func acceptRecommendedPhrase(_ phrase: PresentationPhrase) {
        mutatePresentation(saveImmediately: true) { session in
            let norm = phrase.phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.customPhrases.contains(where: { $0.phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == norm }) else { return }
            var copy = phrase
            copy.id = UUID()
            copy.isCustom = true
            session.customPhrases.insert(copy, at: 0)
        }
        presentationRecommendation?.phrases.removeAll { $0.id == phrase.id }
        if (presentationRecommendation?.checklist.isEmpty ?? true) && (presentationRecommendation?.phrases.isEmpty ?? true) {
            presentationRecommendation = nil
        }
    }

    func acceptAllPresentationRecommendations() {
        guard let rec = presentationRecommendation else { return }
        for item in rec.checklist {
            acceptRecommendedChecklistItem(item)
        }
        for phrase in rec.phrases {
            acceptRecommendedPhrase(phrase)
        }
        presentationRecommendation = nil
        presetNotice = "추천 체크리스트와 맞춤 전환구를 모두 적용했습니다."
    }

    func dismissPresentationRecommendations() {
        presentationRecommendation = nil
    }

    /// One-click Google Meet + PPT sharing setup:
    /// captures Chrome/Meet audience audio + presenter mic, hides SpikDoum from screen sharing,
    /// and enables live PowerPoint/Keynote slide synchronization.
    func prepareGoogleMeetPresentation(browser: MeetingAudioTarget = .chrome) {
        ensurePresentationSession()
        let browsers: [MeetingAudioTarget] = [.chrome, .safari, .edge, .firefox, .all]
        let chosenTarget = browsers.contains(browser) ? browser : .chrome
        let audioChanged = (meetingTarget != chosenTarget) || !includeSystemAudio || systemAudioOnly
        meetingTarget = chosenTarget
        includeSystemAudio = true
        systemAudioOnly = false
        autoAdvice = true
        hideFromScreenShare = true
        pptSlideSync.setEnabled(true)
        if listening && audioChanged {
            scheduleLiveCaptureRestart(notice: "Google Meet PPT 발표 설정 적용 · Chrome 청중 소리 + 마이크 동시 청취 · 화면 공유 숨김 ON")
        } else {
            presetNotice = "Google Meet PPT 발표 준비 완료 · 화면 공유 숨김 ON · \(chosenTarget.title) 소리 + 마이크 · PPT 슬라이드 자동 연동 ON"
        }
    }

    func importPPTXPresentation() {
        guard let url = PPTXSlideImporter.pickPPTXFile() else { return }
        do {
            let slides = try PPTXSlideImporter.importPPTX(from: url)
            let targetMins = activePresentation.targetMinutes
            let markdown = PPTXSlideImporter.formatAsCueCardMarkdown(slides: slides, totalMinutes: targetMins)
            let notesCount = slides.filter { !$0.speakerNotes.isEmpty }.count
            let notesHash = Self.stablePresentationNotesHash(markdown)
            let deckName = url.lastPathComponent
            mutatePresentation(saveImmediately: true) { session in
                session.notesMarkdown = markdown
                session.activeCardIndex = 0
                session.sectionElapsed = [:]
                session.linkedDeckName = deckName
                session.linkedDeckPath = url.path
                session.linkedDeckNotesHash = notesHash
                session.linkedDeckSyncedAt = Date()
            }
            linkedPPTNotesPendingUpdate = nil
            if let index = conversations.firstIndex(where: { $0.id == selectedID }),
               conversations[index].title == "새 대화" {
                let filename = url.deletingPathExtension().lastPathComponent
                if !filename.isEmpty {
                    conversations[index].title = String(filename.prefix(30))
                    save()
                }
            }
            presetNotice = "PPTX 슬라이드 \(slides.count)장 불러옴 (발표자 노트 \(notesCount)장 포함) · 맞춤 체크리스트를 생성합니다."
            Task { [weak self] in
                await self?.recommendPresentationAids()
            }
        } catch {
            presentationError = error.localizedDescription
        }
    }

    // MARK: - Automatic Linked PowerPoint / Keynote Presenter Notes Sync

    static func stablePresentationNotesHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func canAutoReplacePresentationNotes(for session: PresentationSession) -> Bool {
        let trimmed = session.notesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == PresentationSession.starterTemplate.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        if let savedHash = session.linkedDeckNotesHash,
           Self.stablePresentationNotesHash(session.notesMarkdown) == savedHash {
            return true
        }
        return false
    }

    func handleLinkedPPTDeckEvent(snapshot: PPTSlideSnapshot, becameSlideShow: Bool, deckChanged: Bool) {
        guard perspective == .presentation,
              pptSlideSync.autoImportNotes,
              current?.archivedAt == nil,
              !pptSlideSync.isImportingNotes else { return }

        let session = activePresentation
        let sameDeck = (session.linkedDeckName == snapshot.presentationName && !snapshot.presentationName.isEmpty)
            || (!snapshot.presentationPath.isEmpty && session.linkedDeckPath == snapshot.presentationPath)

        // When entering slide show mode OR detecting a new/updated linked presentation:
        if canAutoReplacePresentationNotes(for: session) {
            Task { [weak self] in
                await self?.syncLinkedPPTNotes(
                    snapshot: snapshot,
                    force: false,
                    silentIfUnchanged: sameDeck && !becameSlideShow
                )
            }
        } else if deckChanged || becameSlideShow {
            // User manually customized notes in SpikDoum — never overwrite silently; offer one-click sync banner.
            let label = snapshot.presentationName.isEmpty ? snapshot.appName : snapshot.presentationName
            linkedPPTNotesPendingUpdate = label
        }
    }

    func syncLinkedPPTNotes(
        snapshot: PPTSlideSnapshot? = nil,
        force: Bool = true,
        silentIfUnchanged: Bool = false
    ) async {
        guard current?.archivedAt == nil, !pptSlideSync.isImportingNotes else { return }
        pptSlideSync.isImportingNotes = true
        presentationError = nil
        defer { pptSlideSync.isImportingNotes = false }

        let outcome = await PPTSlideSyncMonitor.fetchActivePresentationSlides(preferredSnapshot: snapshot)
        switch outcome {
        case .success(let fetched):
            let session = activePresentation
            let markdown = PPTXSlideImporter.formatAsCueCardMarkdown(
                slides: fetched.slides,
                totalMinutes: session.targetMinutes
            )
            let newHash = Self.stablePresentationNotesHash(markdown)
            let deckName = fetched.snapshot.presentationName.isEmpty
                ? "\(fetched.snapshot.appName) 발표"
                : fetched.snapshot.presentationName
            let deckPath = fetched.snapshot.presentationPath.isEmpty ? nil : fetched.snapshot.presentationPath
            let sameDeck = (session.linkedDeckName == deckName)
                || (deckPath != nil && session.linkedDeckPath == deckPath)
            let notesChanged = (session.linkedDeckNotesHash != newHash) || (session.notesMarkdown != markdown)
            let targetCardIndex = min(max(0, fetched.snapshot.currentSlide - 1), max(0, fetched.slides.count - 1))

            if !force && sameDeck && !notesChanged {
                if session.activeCardIndex != targetCardIndex {
                    mutatePresentation { $0.activeCardIndex = targetCardIndex }
                }
                if !silentIfUnchanged {
                    let notesCount = fetched.slides.filter { !$0.speakerNotes.isEmpty }.count
                    presetNotice = "\(fetched.snapshot.appName) ‘\(deckName)’ 최신 메모 확인됨 (\(fetched.slides.count)장 · 메모 \(notesCount)장)"
                }
                return
            }

            let notesCount = fetched.slides.filter { !$0.speakerNotes.isEmpty }.count
            mutatePresentation(saveImmediately: true) { pres in
                pres.notesMarkdown = markdown
                pres.activeCardIndex = targetCardIndex
                if !sameDeck {
                    pres.sectionElapsed = [:]
                }
                pres.linkedDeckName = deckName
                pres.linkedDeckPath = deckPath
                pres.linkedDeckNotesHash = newHash
                pres.linkedDeckSyncedAt = Date()
            }
            linkedPPTNotesPendingUpdate = nil

            if let index = conversations.firstIndex(where: { $0.id == selectedID }),
               conversations[index].title == "새 대화" {
                let stem = URL(fileURLWithPath: deckName).deletingPathExtension().lastPathComponent
                if !stem.isEmpty {
                    conversations[index].title = String(stem.prefix(30))
                    save()
                }
            }

            let sourceTag = fetched.usedLiveMemoryNotes ? "실시간 PPT 메모" : "PPTX 파일"
            presetNotice = "\(fetched.snapshot.appName) ‘\(deckName)’ \(sourceTag) \(fetched.slides.count)장 자동 동기화 완료 (발표자 메모 \(notesCount)장)"

            if activePresentation.checklist.isEmpty && !fetched.slides.isEmpty {
                Task { [weak self] in
                    await self?.recommendPresentationAids()
                }
            }

        case .failure(let error):
            if force {
                presentationError = error.localizedDescription
            }
        }
    }

    func syncPresentationChecklist(with transcript: String, at index: Int) {
        guard conversations.indices.contains(index),
              var pres = conversations[index].presentation,
              !pres.checklist.isEmpty else { return }
        let result = PresentationChecklistMatcher.apply(transcript: transcript, to: pres.checklist)
        if result.changed {
            pres.checklist = result.items
            conversations[index].presentation = pres
        }
    }

    // MARK: - Presentation Question Post-it Notes (Per-Question Audio + Text Memo)

    private func currentSlideContext() -> (number: Int?, title: String?) {
        let cards = PresentationNotesParser.parse(activePresentation.notesMarkdown)
        if let pptSlide = pptSlideSync.currentSlideNumber {
            let idx = pptSlide - 1
            let title = cards.indices.contains(idx) ? cards[idx].title : nil
            return (pptSlide, title)
        }
        guard !cards.isEmpty else { return (nil, nil) }
        let idx = min(max(0, activePresentation.activeCardIndex), cards.count - 1)
        return (idx + 1, cards[idx].title)
    }

    func startQuestionNoteRecording() {
        guard !recordingQuestionNote, current?.archivedAt == nil else { return }
        ensurePresentationSession()
        do {
            try questionAudioRecorder.startManualRecording(
                preRollSeconds: 2.0,
                useStandaloneMic: !listening
            )
            recordingQuestionNote = true
            recordingQuestionSeconds = 0
            questionRecordStartedAt = Date()
            questionRecordBaselineSpanCount = current?.transcriptSpans?.count ?? 0
            questionRecordTimerTask?.cancel()
            questionRecordTimerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.recordingQuestionNote else { return }
                    self.recordingQuestionSeconds += 1
                }
            }
            presetNotice = "질문기록 녹음 시작 · 질문이 끝나면 ‘질문 저장’을 누르세요 (직전 2초 음성 자동 포함)"
        } catch {
            presentationError = "질문 녹음을 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func cancelQuestionNoteRecording() {
        questionRecordTimerTask?.cancel()
        questionRecordTimerTask = nil
        recordingQuestionNote = false
        recordingQuestionSeconds = 0
        questionRecordStartedAt = nil
        questionAudioRecorder.cancelManualRecording()
    }

    func stopAndSaveQuestionNoteRecording() {
        guard recordingQuestionNote else { return }
        questionRecordTimerTask?.cancel()
        questionRecordTimerTask = nil
        recordingQuestionNote = false
        let startedAt = questionRecordStartedAt ?? Date().addingTimeInterval(-Double(max(2, recordingQuestionSeconds)))
        let baselineCount = questionRecordBaselineSpanCount
        recordingQuestionSeconds = 0
        questionRecordStartedAt = nil

        guard let conversationID = selectedID else {
            questionAudioRecorder.cancelManualRecording()
            return
        }

        let sourceSummary = listening
            ? (systemAudioOnly ? "Mac 재생음" : includeSystemAudio ? "마이크 + Mac 재생음" : "마이크")
            : "마이크 (질문 녹음)"
        let clip = questionAudioRecorder.stopManualRecordingAndExport(
            conversationID: conversationID,
            recordingsRoot: recordingsRoot,
            sourceSummary: sourceSummary
        )

        // Collect STT spans spoken during the question recording window (plus live partial if any).
        let spans = current?.transcriptSpans ?? []
        let newSpans = spans.enumerated().compactMap { idx, span -> TranscriptSpan? in
            if idx >= baselineCount || span.date >= startedAt.addingTimeInterval(-2.0) { return span }
            return nil
        }
        var questionLines = newSpans.map {
            TranslationPolicy.displayText(strippingSourceTag: $0.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let livePartial = liveSTT.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !livePartial.isEmpty && !(questionLines.last?.contains(livePartial) ?? false) {
            questionLines.append(livePartial)
        }
        let questionText = questionLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // Gather matching translations if already produced.
        let matchingTranslations = (current?.translations ?? []).filter { entry in
            let cleanedSrc = TranslationPolicy.displayText(strippingSourceTag: entry.source).trimmingCharacters(in: .whitespacesAndNewlines)
            return !cleanedSrc.isEmpty && questionText.localizedCaseInsensitiveContains(cleanedSrc)
        }.map { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let slide = currentSlideContext()
        let detectedSource: String = {
            if let last = newSpans.last, let tag = TranslationPolicy.sourceTag(of: last.text) {
                return tag == "Mac 재생음" ? "Meet 청중" : "마이크"
            }
            return listening && (includeSystemAudio || systemAudioOnly) ? "청중/마이크" : "마이크 녹음"
        }()

        let note = PresentationQuestionNote(
            createdAt: startedAt,
            slideNumber: slide.number,
            slideTitle: slide.title,
            sourceLabel: detectedSource,
            questionText: questionText,
            translatedText: matchingTranslations.isEmpty ? nil : matchingTranslations.joined(separator: " "),
            color: .yellow,
            autoCaptured: false,
            audioClip: clip,
            sourceSpanID: newSpans.last?.id
        )

        mutatePresentation(saveImmediately: true) { session in
            if session.questionNotes == nil { session.questionNotes = [] }
            session.questionNotes?.insert(note, at: 0)
        }
        let durText = clip.map { String(format: "음성 %.1f초 포함", $0.duration) } ?? "텍스트 저장"
        presetNotice = "질문기록 저장 완료 (\(durText))"

        if clip != nil && (questionText.isEmpty || (questionText.count < 8 && (clip?.duration ?? 0) >= 1.2)) {
            Task { [weak self] in
                await self?.transcribeQuestionNote(note.id, thenTranslate: true)
            }
        } else if !questionText.isEmpty && (note.translatedText?.isEmpty ?? true) {
            Task { [weak self] in
                await self?.translateQuestionNote(note.id)
            }
        }
    }

    /// Retroactively captures the most recent question (preferring audience `[Mac 재생음]` if present)
    /// along with its audio slice from the 45-second rolling ring buffer into a standalone Post-it card.
    func captureRecentQuestionAsPostIt() {
        guard current?.archivedAt == nil, let conversationID = selectedID else { return }
        ensurePresentationSession()

        let spans = current?.transcriptSpans ?? []
        let now = Date()
        let recentWindow = now.addingTimeInterval(-40)
        let recentSpans = spans.filter { $0.date >= recentWindow }
        let audienceSpans = recentSpans.filter { TranslationPolicy.sourceTag(of: $0.text) == "Mac 재생음" }

        let targetSpans: [TranscriptSpan]
        if !audienceSpans.isEmpty {
            targetSpans = Array(audienceSpans.suffix(3))
        } else if !recentSpans.isEmpty {
            targetSpans = Array(recentSpans.suffix(2))
        } else if let last = spans.last {
            targetSpans = [last]
        } else {
            targetSpans = []
        }

        var parts = targetSpans.map {
            TranslationPolicy.displayText(strippingSourceTag: $0.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let livePartial = liveSTT.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !livePartial.isEmpty && !(parts.last?.contains(livePartial) ?? false) {
            parts.append(livePartial)
        }
        let questionText = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let startDate = targetSpans.first?.date
        let endDate = targetSpans.last?.date ?? now
        let sourceLabel: String = {
            if let last = targetSpans.last, let tag = TranslationPolicy.sourceTag(of: last.text) {
                return tag == "Mac 재생음" ? "Meet 청중" : "마이크"
            }
            return "청중 질문"
        }()

        let clip = questionAudioRecorder.exportRecentClip(
            conversationID: conversationID,
            recordingsRoot: recordingsRoot,
            from: startDate,
            to: endDate,
            fallbackSeconds: 14.0,
            sourceSummary: sourceLabel
        )

        // Match latest translation for those spans if available.
        let matchedTranslation: String? = {
            let entries = current?.translations ?? []
            let matched = entries.filter { entry in
                let src = TranslationPolicy.displayText(strippingSourceTag: entry.source).trimmingCharacters(in: .whitespacesAndNewlines)
                return !src.isEmpty && (questionText.localizedCaseInsensitiveContains(src) || src.localizedCaseInsensitiveContains(questionText))
            }.suffix(2).map { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return matched.isEmpty ? nil : matched.joined(separator: " ")
        }()

        let slide = currentSlideContext()
        let note = PresentationQuestionNote(
            createdAt: startDate ?? now,
            slideNumber: slide.number,
            slideTitle: slide.title,
            sourceLabel: sourceLabel,
            questionText: questionText,
            translatedText: matchedTranslation,
            color: audienceSpans.isEmpty ? .yellow : .sky,
            autoCaptured: false,
            audioClip: clip,
            sourceSpanID: targetSpans.last?.id
        )

        mutatePresentation(saveImmediately: true) { session in
            if session.questionNotes == nil { session.questionNotes = [] }
            session.questionNotes?.insert(note, at: 0)
        }

        let audioLabel = clip.map { String(format: "음성 %.1f초 포함", $0.duration) } ?? "텍스트만 저장"
        presetNotice = "📌 방금 질문을 질문기록에 저장했습니다 (\(audioLabel))"

        if clip != nil && (questionText.isEmpty || (questionText.count < 8 && (clip?.duration ?? 0) >= 1.2)) {
            Task { [weak self] in
                await self?.transcribeQuestionNote(note.id, thenTranslate: true)
            }
        } else if !questionText.isEmpty && (note.translatedText?.isEmpty ?? true) {
            Task { [weak self] in
                await self?.translateQuestionNote(note.id)
            }
        }
    }

    /// Automatically processes any saved Question Records that still need STT or translation
    /// (e.g., older audio-only notes or notes saved right before translation completed).
    func ensureQuestionNotesProcessed() {
        let notes = activePresentation.resolvedQuestionNotes
        guard !notes.isEmpty else { return }
        for note in notes.prefix(8) {
            let trimmed = note.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && note.audioClip != nil && !transcribingQuestionIDs.contains(note.id) {
                Task { [weak self] in
                    await self?.transcribeQuestionNote(note.id, thenTranslate: true)
                }
            } else if !trimmed.isEmpty && (note.translatedText?.isEmpty ?? true) && !translatingQuestionIDs.contains(note.id) {
                Task { [weak self] in
                    await self?.translateQuestionNote(note.id)
                }
            }
        }
    }

    func addManualQuestionNote(_ rawText: String, color: PostItColor = .yellow) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ensurePresentationSession()
        let slide = currentSlideContext()
        let note = PresentationQuestionNote(
            createdAt: Date(),
            slideNumber: slide.number,
            slideTitle: slide.title,
            sourceLabel: "직접 메모",
            questionText: trimmed,
            color: color,
            autoCaptured: false
        )
        mutatePresentation(saveImmediately: true) { session in
            if session.questionNotes == nil { session.questionNotes = [] }
            session.questionNotes?.insert(note, at: 0)
        }
        Task { [weak self] in
            await self?.translateQuestionNote(note.id)
        }
    }

    func updateQuestionNote(_ id: UUID, _ mutate: (inout PresentationQuestionNote) -> Void) {
        mutatePresentation(saveImmediately: false) { session in
            guard var list = session.questionNotes,
                  let idx = list.firstIndex(where: { $0.id == id }) else { return }
            mutate(&list[idx])
            session.questionNotes = list
        }
    }

    func deleteQuestionNote(_ id: UUID) {
        var removedFilename: String? = nil
        mutatePresentation(saveImmediately: true) { session in
            guard var list = session.questionNotes,
                  let idx = list.firstIndex(where: { $0.id == id }) else { return }
            removedFilename = list[idx].audioClip?.filename
            list.remove(at: idx)
            session.questionNotes = list
        }
        if let filename = removedFilename, let conversationID = selectedID {
            let url = RecordingStorage.clipURL(conversationID: conversationID, filename: filename, root: recordingsRoot)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Automatically creates/updates a Question Post-it (with its audio slice) when a live audience question
    /// is spoken in Presentation Mode (e.g., Google Meet `[Mac 재생음]` or Q&A interrogative utterance).
    func detectAndAutoCapturePresentationQuestion(at index: Int) {
        guard autoCaptureQuestions,
              !recordingQuestionNote,
              conversations.indices.contains(index),
              let pres = conversations[index].presentation,
              let latestSpan = conversations[index].transcriptSpans?.last else { return }

        let sourceTag = TranslationPolicy.sourceTag(of: latestSpan.text)
        let cleanText = TranslationPolicy.displayText(strippingSourceTag: latestSpan.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuestionAudioClipRecorder.isLikelyQuestion(latestSpan.text, sourceTag: sourceTag, inQAMode: pres.inQAMode) else {
            return
        }

        let existingNotes = pres.resolvedQuestionNotes
        // If we already auto-captured this exact span (e.g. STT revised it slightly), update its text in place.
        if let existingIdx = existingNotes.firstIndex(where: { $0.sourceSpanID == latestSpan.id }) {
            if existingNotes[existingIdx].questionText != cleanText {
                var updated = existingNotes
                updated[existingIdx].questionText = cleanText
                conversations[index].presentation?.questionNotes = updated
            }
            return
        }

        // Coalesce consecutive auto-captured audience spans within 8 seconds into the same Post-it instead of spamming.
        if let recentIdx = existingNotes.firstIndex(where: {
            $0.autoCaptured && abs(latestSpan.date.timeIntervalSince($0.createdAt)) <= 8.0
                && ($0.sourceLabel == (sourceTag == "Mac 재생음" ? "Meet 청중" : "질문 감지"))
        }) {
            var updated = existingNotes
            if !updated[recentIdx].questionText.contains(cleanText) {
                updated[recentIdx].questionText = [updated[recentIdx].questionText, cleanText]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                updated[recentIdx].sourceSpanID = latestSpan.id
                // Re-export audio clip covering the extended question window
                if let newClip = questionAudioRecorder.exportRecentClip(
                    conversationID: conversations[index].id,
                    recordingsRoot: recordingsRoot,
                    from: updated[recentIdx].createdAt,
                    to: latestSpan.date,
                    fallbackSeconds: 12.0,
                    sourceSummary: updated[recentIdx].sourceLabel
                ) {
                    if let oldFilename = updated[recentIdx].audioClip?.filename {
                        let oldURL = RecordingStorage.clipURL(conversationID: conversations[index].id, filename: oldFilename, root: recordingsRoot)
                        try? FileManager.default.removeItem(at: oldURL)
                    }
                    updated[recentIdx].audioClip = newClip
                }
                conversations[index].presentation?.questionNotes = updated
            }
            return
        }

        let sourceLabel = sourceTag == "Mac 재생음" ? "Meet 청중" : "질문 감지"
        let clip = questionAudioRecorder.exportRecentClip(
            conversationID: conversations[index].id,
            recordingsRoot: recordingsRoot,
            from: latestSpan.date.addingTimeInterval(-3.5),
            to: latestSpan.date,
            fallbackSeconds: 10.0,
            sourceSummary: sourceLabel
        )
        let slide = currentSlideContext()
        let note = PresentationQuestionNote(
            createdAt: latestSpan.date,
            slideNumber: slide.number,
            slideTitle: slide.title,
            sourceLabel: sourceLabel,
            questionText: cleanText,
            color: sourceTag == "Mac 재생음" ? .sky : .yellow,
            autoCaptured: true,
            audioClip: clip,
            sourceSpanID: latestSpan.id
        )
        var list = existingNotes
        list.insert(note, at: 0)
        conversations[index].presentation?.questionNotes = list

        // If main translation pipeline hasn't backfilled this question's translation within 1.2s, translate directly.
        let noteID = note.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self,
                  let currentNote = self.activePresentation.resolvedQuestionNotes.first(where: { $0.id == noteID }),
                  (currentNote.translatedText?.isEmpty ?? true) else { return }
            await self.translateQuestionNote(noteID)
        }
    }

    /// Runs STT on a saved question record's `.m4a` audio clip using the best available engine:
    /// 1. Installed Managed Whisper (auto-starts local server & detects Korean/English/multilingual automatically)
    /// 2. Parakeet ANE (if selected/cached & English/EU)
    /// 3. Apple Speech (`SFSpeechURLRecognitionRequest`) with multi-locale fallback
    /// Then automatically translates the transcribed text.
    func transcribeQuestionNote(_ noteID: UUID, thenTranslate: Bool = true) async {
        guard let conversationID = selectedID,
              let note = activePresentation.resolvedQuestionNotes.first(where: { $0.id == noteID }),
              let clip = note.audioClip,
              !transcribingQuestionIDs.contains(noteID) else { return }

        let clipURL = RecordingStorage.clipURL(
            conversationID: conversationID,
            filename: clip.filename,
            root: recordingsRoot
        )
        guard FileManager.default.fileExists(atPath: clipURL.path) else {
            presentationError = "녹음된 질문 음성 파일을 찾지 못했습니다."
            return
        }

        transcribingQuestionIDs.insert(noteID)
        presentationError = nil
        defer { transcribingQuestionIDs.remove(noteID) }

        let hasInstalledWhisper = managedModels.selected(.stt).map { managedModels.installed.contains($0.id) } ?? false
        let hasParakeet = parakeetModels.isLoaded || parakeetModels.isCachedOnDisk
        let pcm16 = (try? QuestionAudioTranscriber.decodeTo16kMonoPCM16(url: clipURL)) ?? Data()

        var transcribed = ""
        var lastError: Error?

        // 1. Prefer Managed Whisper when selected OR installed (handles Korean + English + multilingual auto-detect cleanly!).
        if hasInstalledWhisper && !pcm16.isEmpty && (settings.stt == .managed || settings.stt == .apple || isAutoDetectLanguage) {
            do {
                try await managedModels.ensureReady(.stt)
                let key = managedModels.authorization(.stt)
                transcribed = try await QuestionAudioTranscriber.transcribeWithManagedWhisper(
                    pcm16: pcm16,
                    key: key,
                    languageHint: LanguageCatalog.autoCode
                )
            } catch {
                lastError = error
            }
        }

        // 2. Try Parakeet ANE when configured (fast on-device CoreML for English/European questions).
        if transcribed.isEmpty && settings.stt == .parakeet && hasParakeet && !pcm16.isEmpty {
            do {
                let parakeetText = try await parakeetModels.transcribe(pcm16Data: pcm16)
                let cleaned = parakeetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    transcribed = cleaned
                }
            } catch {
                lastError = error
            }
        }

        // 3. Fallback to installed Whisper even if Parakeet was primary (e.g. Korean question spoken while Parakeet was active!).
        if transcribed.isEmpty && hasInstalledWhisper && !pcm16.isEmpty {
            do {
                try await managedModels.ensureReady(.stt)
                let key = managedModels.authorization(.stt)
                transcribed = try await QuestionAudioTranscriber.transcribeWithManagedWhisper(
                    pcm16: pcm16,
                    key: key,
                    languageHint: LanguageCatalog.autoCode
                )
            } catch {
                lastError = error
            }
        }

        // 4. Final fallback: Apple Speech URL recognizer with presentation locale + user target locale.
        if transcribed.isEmpty {
            let locales = [
                isAutoDetectLanguage ? lastFixedLanguage : language,
                targetLanguage,
                "en-US",
                "ko-KR"
            ]
            do {
                transcribed = try await QuestionAudioTranscriber.transcribeWithAppleSpeech(
                    url: clipURL,
                    localeIdentifiers: locales
                )
            } catch {
                lastError = error
            }
        }

        let cleaned = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            if let lastError {
                presentationError = "질문 음성 STT 변환 실패: \(lastError.localizedDescription)"
            }
            return
        }

        updateQuestionNote(noteID) { item in
            item.questionText = cleaned
        }
        save()
        if thenTranslate {
            await translateQuestionNote(noteID)
        }
    }

    /// Translates a saved question record's STT text automatically (two-way):
    /// - Foreign question -> user's target language (e.g., English -> Korean)
    /// - Question in user's target language -> presentation/STT language (e.g., Korean -> English)
    func translateQuestionNote(_ noteID: UUID, force: Bool = false) async {
        guard let note = activePresentation.resolvedQuestionNotes.first(where: { $0.id == noteID }),
              !translatingQuestionIDs.contains(noteID) else { return }
        let source = note.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        let presentationLang = sourceLanguageSpec
            ?? LanguageCatalog.language(for: lastFixedLanguage)
            ?? LanguageCatalog.language(for: "en-US")

        let chosenTarget: SupportedLanguage
        if force {
            chosenTarget = QuestionTranslationLanguageResolver.targetLanguage(
                for: source,
                userTarget: targetLanguageSpec,
                presentationLanguage: presentationLang
            ) ?? targetLanguageSpec
        } else if let resolved = QuestionTranslationLanguageResolver.targetLanguage(
            for: source,
            userTarget: targetLanguageSpec,
            presentationLanguage: presentationLang
        ) {
            chosenTarget = resolved
        } else {
            return
        }

        let detectedSource = LanguageCatalog.detectLanguage(for: source)
        translatingQuestionIDs.insert(noteID)
        defer { translatingQuestionIDs.remove(noteID) }

        do {
            if settings.translation == .managed {
                try await managedModels.ensureReady(.translation)
            }
            let translated = try await translateTextWithConfiguredEngine(
                source,
                sourceHint: detectedSource,
                into: chosenTarget
            )
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != source else { return }
            updateQuestionNote(noteID) { item in
                item.translatedText = cleaned
            }
            save()
        } catch {
            if force {
                presentationError = "질문 번역 실패: \(error.localizedDescription)"
            }
        }
    }

    func backfillQuestionNoteTranslation(_ entry: TranslationEntry, at index: Int) {
        guard conversations.indices.contains(index),
              var list = conversations[index].presentation?.questionNotes,
              !list.isEmpty else { return }
        let cleanedSource = TranslationPolicy.displayText(strippingSourceTag: entry.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslated = entry.translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTranslated.isEmpty else { return }

        var changed = false
        for i in list.indices.prefix(6) {
            let q = list[i].questionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { continue }
            if q.localizedCaseInsensitiveContains(cleanedSource) || cleanedSource.localizedCaseInsensitiveContains(q) {
                if list[i].translatedText != cleanedTranslated {
                    list[i].translatedText = cleanedTranslated
                    changed = true
                }
            }
        }
        if changed {
            conversations[index].presentation?.questionNotes = list
        }
    }

    func exportQuestionNotesMarkdown() -> String {
        let notes = activePresentation.resolvedQuestionNotes.sorted { $0.createdAt < $1.createdAt }
        guard !notes.isEmpty else { return "" }
        let title = current?.title ?? "발표"
        var lines: [String] = ["# \(title) — 발표 질문기록 (\(notes.count)건)", ""]
        for (idx, note) in notes.enumerated() {
            let slidePart = note.slideNumber.map { "슬라이드 #\($0)" } ?? "슬라이드 미지정"
            let timePart = note.createdAt.formatted(.dateTime.hour().minute().second())
            let statusPart = note.isResolved ? "✅ 답변 완료" : "🟡 미답변"
            lines.append("## Q\(idx + 1). [\(slidePart) · \(timePart) · \(statusPart)]")
            lines.append("- STT 원문: \(note.questionText.isEmpty ? "(음성 녹음)" : note.questionText)")
            if let trans = note.translatedText, !trans.isEmpty {
                lines.append("- 번역: \(trans)")
            }
            if let rec = note.recommendedAnswer, !rec.isEmpty {
                lines.append("- AI 답변 추천: \(rec)")
            }
            if let recLocal = note.recommendedAnswerLocal, !recLocal.isEmpty {
                lines.append("- 답변 해설/팁: \(recLocal)")
            }
            if !note.answerMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("- 답변/후속 메모: \(note.answerMemo)")
            }
            if let clip = note.audioClip {
                lines.append("- 저장된 음성: `\(clip.filename)` (\(String(format: "%.1f초", clip.duration)))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Online Learning Silent Window Screen Capture

    func refreshLearningWindows() async {
        await learningCapturer.refreshWindows()
    }

    func setLearningAutoCapture(_ enabled: Bool) {
        learningCapturer.autoCaptureEnabled = enabled
        if enabled {
            learningCapturer.resetChangeFingerprint()
            startLearningAutoCaptureLoop()
            presetNotice = learningCapturer.changeDetectionOnly
                ? "조용한 자동 화면 기록 ON · \(learningCapturer.intervalSeconds)초마다 확인해 화면이 바뀔 때만 기록합니다."
                : "조용한 자동 화면 기록 ON · \(learningCapturer.intervalSeconds)초마다 선택한 교육 창을 기록합니다."
        } else {
            stopLearningAutoCaptureLoop()
            presetNotice = "자동 화면 기록을 중지했습니다."
        }
    }

    func startLearningAutoCaptureLoop() {
        stopLearningAutoCaptureLoop()
        guard learningCapturer.autoCaptureEnabled else { return }
        learningAutoCaptureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.perspective == .learning, self.learningCapturer.autoCaptureEnabled else { return }
                _ = await self.captureLearningScreenNow(automatic: true)
                let interval = max(3, self.learningCapturer.intervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopLearningAutoCaptureLoop() {
        learningAutoCaptureTask?.cancel()
        learningAutoCaptureTask = nil
    }

    @discardableResult
    func captureLearningScreenNow(automatic: Bool = false) async -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }),
              conversations[index].archivedAt == nil else { return false }

        let conversationID = conversations[index].id
        let onlyIfChanged = automatic && learningCapturer.changeDetectionOnly
        let result = await learningCapturer.captureSilently(
            conversationID: conversationID,
            recordingsRoot: recordingsRoot,
            onlyIfChanged: onlyIfChanged
        )

        switch result {
        case .success(let outcome):
            guard let outcome else { return false } // Unchanged screen skipped quietly

            // Pair with the exact explanation currently being spoken (last 1–2 recent spans + live partial + translation).
            guard let liveIdx = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
            let now = Date()
            let spans = conversations[liveIdx].transcriptSpans ?? []
            let recentSpans = spans.filter { now.timeIntervalSince($0.date) <= 25 }
            let chosenSpans = recentSpans.isEmpty ? Array(spans.suffix(1)) : Array(recentSpans.suffix(2))
            var excerptParts = chosenSpans.map {
                TranslationPolicy.displayText(strippingSourceTag: $0.text).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let livePartial = liveSTT.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !livePartial.isEmpty && !(excerptParts.last?.contains(livePartial) ?? false) {
                excerptParts.append(livePartial)
            }
            let transcriptExcerpt = excerptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            let translationExcerpt: String? = {
                guard !transcriptExcerpt.isEmpty else { return nil }
                let entries = conversations[liveIdx].translations ?? []
                let matched = entries.filter { entry in
                    let src = TranslationPolicy.displayText(strippingSourceTag: entry.source).trimmingCharacters(in: .whitespacesAndNewlines)
                    return !src.isEmpty && (transcriptExcerpt.localizedCaseInsensitiveContains(src) || src.localizedCaseInsensitiveContains(transcriptExcerpt))
                }.suffix(2).map { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return matched.isEmpty ? nil : matched.joined(separator: " ")
            }()

            let record = LearningScreenCapture(
                filename: outcome.filename,
                capturedAt: now,
                windowTitle: outcome.windowTitle,
                appName: outcome.appName,
                transcriptExcerpt: transcriptExcerpt,
                translationExcerpt: translationExcerpt,
                autoCaptured: automatic,
                sourceSpanID: chosenSpans.last?.id,
                pixelWidth: outcome.pixelWidth,
                pixelHeight: outcome.pixelHeight
            )
            if conversations[liveIdx].screenCaptures == nil {
                conversations[liveIdx].screenCaptures = []
            }
            conversations[liveIdx].screenCaptures?.append(record)
            save()
            return true

        case .failure:
            return false
        }
    }

    func updateLearningCapture(_ id: UUID, _ mutate: (inout LearningScreenCapture) -> Void) {
        guard let convoIdx = conversations.firstIndex(where: { $0.id == selectedID }),
              var list = conversations[convoIdx].screenCaptures,
              let itemIdx = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[itemIdx])
        conversations[convoIdx].screenCaptures = list
        scheduleSave()
    }

    func deleteLearningCapture(_ id: UUID) {
        guard let convoIdx = conversations.firstIndex(where: { $0.id == selectedID }),
              var list = conversations[convoIdx].screenCaptures,
              let itemIdx = list.firstIndex(where: { $0.id == id }) else { return }
        let filename = list[itemIdx].filename
        let convoID = conversations[convoIdx].id
        list.remove(at: itemIdx)
        conversations[convoIdx].screenCaptures = list
        save()
        let url = RecordingStorage.clipURL(conversationID: convoID, filename: filename, root: recordingsRoot)
        try? FileManager.default.removeItem(at: url)
    }

    func backfillLearningCaptureTranslation(_ entry: TranslationEntry, at index: Int) {
        guard conversations.indices.contains(index),
              var list = conversations[index].screenCaptures,
              !list.isEmpty else { return }
        let cleanedSource = TranslationPolicy.displayText(strippingSourceTag: entry.source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTranslated = entry.translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTranslated.isEmpty else { return }

        var changed = false
        for i in list.indices.suffix(5) {
            let excerpt = list[i].transcriptExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerpt.isEmpty else { continue }
            if excerpt.localizedCaseInsensitiveContains(cleanedSource) || cleanedSource.localizedCaseInsensitiveContains(excerpt) {
                if list[i].translationExcerpt == nil || list[i].translationExcerpt?.isEmpty == true {
                    list[i].translationExcerpt = cleanedTranslated
                    changed = true
                }
            }
        }
        if changed {
            conversations[index].screenCaptures = list
        }
    }

    func exportLearningCapturesMarkdown() -> String {
        let list = (displayConversation?.screenCaptures ?? []).sorted { $0.capturedAt < $1.capturedAt }
        guard !list.isEmpty else { return "" }
        let title = displayConversation?.title ?? "온라인 교육"
        var lines: [String] = ["# \(title) — 강의 화면 기록 (\(list.count)장)", ""]
        for (idx, cap) in list.enumerated() {
            let timeText = cap.capturedAt.formatted(.dateTime.hour().minute().second())
            lines.append("## 화면 \(idx + 1) · \(timeText) (\(cap.appName) — \(cap.windowTitle))")
            lines.append("- 캡처 파일: `\(cap.filename)`")
            if !cap.transcriptExcerpt.isEmpty {
                lines.append("- 설명 원문: \(cap.transcriptExcerpt)")
            }
            if let trans = cap.translationExcerpt, !trans.isEmpty {
                lines.append("- 번역: \(trans)")
            }
            if !cap.userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("- 학습 메모: \(cap.userNote)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
