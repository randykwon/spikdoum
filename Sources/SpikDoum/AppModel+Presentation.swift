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
            if changed && !listening {
                presetNotice = "온라인 교육 모드 · Mac 소리 전용 · 자막 연계 뷰·키워드·복습 요약 최적화"
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
}
