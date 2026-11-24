import Foundation
import Translation

extension AppModel {
    func scheduleTranslation() {
        // Coalesce STT updates without continually postponing translation during speech.
        guard translationDebounce == nil else { return }
        translationDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.translationDebounce = nil
            self.translateLatest(automatic: true)
        }
    }
    func translateLatest(automatic: Bool = false) {
        if !automatic { translationRetryCount = 0; translationRetryAfter = .distantPast }
        if Date() < translationRetryAfter { return }
        if translationRetryCount >= 3 {
            // Cooldown elapsed: reset retry count so automatic translation resumes instead of staying dead permanently.
            translationRetryCount = 0
        }
        guard !translating, let item = current, item.archivedAt == nil else { return }
        let flush = !automatic || !listening || TranslationPolicy.shouldFlush(now: Date(), lastChange: lastTranscriptChange, batchStarted: translationBatchStartedAt)
        let work = TranslationPolicy.plan(transcript: stableCloudTranscript ?? item.transcript, entries: item.translations ?? [], flush: flush)
        if let index = conversations.firstIndex(where: { $0.id == item.id }),
           conversations[index].translations?.count != work.retained.count {
            conversations[index].translations = work.retained
            save()
        }
        if work.waitingForSentences {
            if translationBatchStartedAt == nil { translationBatchStartedAt = Date() }
            translationStatus = "2~3문장 모으는 중 · 현재 \(work.completedSentences)문장"
            scheduleTranslation()
            return
        }
        let source = work.source
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translationBatchStartedAt = nil
            return
        }
        let token = UUID()
        translationToken = token
        translating = true
        translationSource = source
        translationStatus = "새 원문 번역 중"
        liveTranslation = ""
        translationError = nil
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.translationToken == token {
                    self.translationWatchdog?.cancel()
                    self.translating = false
                    if self.translationError == nil { self.scheduleTranslation() }
                }
            }
            do {
                let started = Date()
                let detectedSpec = self.language == LanguageCatalog.autoCode ? (LanguageCatalog.detectLanguage(for: source) ?? self.detectedSTTLanguage) : self.sourceLanguageSpec
                let sourceShort = detectedSpec?.shortCode ?? LanguageCatalog.whisperLanguageParameter(for: self.language)
                let targetSpec = self.targetLanguageSpec
                let translated: String
                if self.settings.translation == .managed {
                    translated = try await self.managedModels.translate(source, source: sourceShort, target: targetSpec.shortCode, targetName: targetSpec.englishName)
                } else if self.settings.translation == .local {
                    translated = try await LocalTranslator(settings: self.settings.localTranslation, key: SecretStore.read("translation-local")).translate(source, source: sourceShort, target: targetSpec.shortCode)
                } else if self.settings.translation == .azure {
                    translated = try await AzureTranslator(key: SecretStore.read("azure"), region: self.settings.azureRegion).translate(source, target: targetSpec.azureCode)
                } else if let detectedSpec, detectedSpec.translationCode == targetSpec.translationCode {
                    translated = source
                } else {
                    let sourceCode = detectedSpec?.translationCode ?? "en"
                    let targetCode = targetSpec.translationCode
                    let cacheKey = "\(sourceCode)->\(targetCode)"
                    let session: TranslationSession
                    if let existing = self.nativeTranslationSessions[cacheKey] {
                        session = existing
                    } else {
                        // Use the installed-model API directly. Readiness checks and UI-preparation
                        // sessions can disagree about model strategies on some macOS versions.
                        if #available(macOS 26.4, *) {
                            session = TranslationSession(installedSource: Locale.Language(identifier: sourceCode), target: Locale.Language(identifier: targetCode), preferredStrategy: .highFidelity)
                        } else {
                            session = TranslationSession(installedSource: Locale.Language(identifier: sourceCode), target: Locale.Language(identifier: targetCode))
                        }
                        self.nativeTranslationSessions[cacheKey] = session
                    }
                    let result = try await session.translate(source)
                    guard self.translationToken == token, !Task.isCancelled else { return }
                    translated = result.targetText
                }
                guard !Task.isCancelled, self.translationToken == token,
                      let index = self.conversations.firstIndex(where: { $0.id == item.id }) else { return }
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure(message: "번역 결과가 비어 있습니다.") }
                self.liveTranslation = translated
                guard TranslationPolicy.isCurrent(work, transcript: self.conversations[index].transcript) else {
                    self.translationPreview = TranslationEntry(source: source, translated: self.liveTranslation)
                    self.translationStatus = "원문 수정 반영 중 · 아래 번역은 표시된 원문 기준"
                    self.liveTranslation = ""
                    self.translationSource = ""
                    return
                }
                self.translationLatency = Int(Date().timeIntervalSince(started) * 1000)
                let entry = TranslationEntry(source: source, translated: self.liveTranslation, sourceStart: work.start, sourceEnd: work.end)
                if self.conversations[index].translations == nil { self.conversations[index].translations = [] }
                self.conversations[index].translations?.append(entry)
                self.translationPreview = nil
                self.translationBatchStartedAt = nil
                self.translationRetryCount = 0
                self.translationRetryAfter = .distantPast
                self.translationStatus = "번역 완료"
                UserDefaults.standard.set("completed", forKey: "translationDiagnostic")
                self.liveTranslation = ""
                self.translationSource = ""
                self.save()
            } catch {
                guard self.translationToken == token else { return }
                self.translationStatus = "번역 오류 · 언어 모델과 연결 설정을 확인하세요"
                UserDefaults.standard.set("\(self.language): \(error)", forKey: "translationDiagnostic")
                if case TranslationError.notInstalled = error {
                    self.translationError = "기기 내 번역 언어가 준비되지 않았습니다. ‘번역 언어 준비’를 누르거나 엔진 설정에서 Azure 번역을 선택해주세요."
                } else {
                    self.translationError = "번역 실패: \(error.localizedDescription)"
                    self.retryTranslation()
                }
            }
        }
        translationWatchdog?.cancel()
        let timeout = settings.translation == .managed ? 120 : settings.translation == .local ? min(120, max(5, settings.localTranslation.timeout)) + 3 : 20
        translationWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.translationToken == token, self.translating else { return }
            self.translationToken = UUID()
            self.translationTask?.cancel()
            self.translating = false
            self.liveTranslation = ""
            self.translationSource = ""
            self.translationError = "번역 응답 시간이 초과되었습니다."
            self.retryTranslation()
        }
    }
    func retryTranslation() {
        nativeTranslationSessions.removeAll()
        translationRetryCount += 1
        let delay: Double
        if translationRetryCount >= 3 {
            translationStatus = "일시적 번역 오류 · 30초 후 자동 재시도 (또는 수동 재시도)"
            delay = 30
        } else {
            translationStatus = "일시적 번역 오류 · 자동 재시도 대기"
            delay = Double(translationRetryCount * 2)
        }
        translationRetryAfter = Date().addingTimeInterval(delay)
        translationDebounce?.cancel()
        translationDebounce = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.translationDebounce = nil
            self.translateLatest(automatic: true)
        }
    }
    func prepareTranslationLanguages() {
        let sourceCode = sourceLanguageSpec?.translationCode ?? detectedSTTLanguage?.translationCode ?? "en"
        let targetCode = targetLanguageSpec.translationCode
        guard sourceCode != targetCode, !preparingTranslation else { return }
        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)
        if translationConfiguration?.source == source && translationConfiguration?.target == target {
            translationConfiguration?.invalidate()
        } else {
            if #available(macOS 26.4, *) {
                translationConfiguration = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .highFidelity)
            } else {
                translationConfiguration = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }
    func prepareTranslation(using session: TranslationSession) async {
        preparingTranslation = true
        defer { preparingTranslation = false }
        do {
            try await session.prepareTranslation()
            translationError = nil
            nativeTranslationSessions.removeAll()
            translateLatest()
        } catch {
            translationError = "번역 언어 준비 실패: \(error.localizedDescription). ‘번역 언어 준비’를 눌러 다시 시도하세요."
        }
    }
}
