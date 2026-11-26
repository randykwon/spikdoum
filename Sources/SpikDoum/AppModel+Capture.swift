import Foundation
import AVFoundation

extension AppModel {
    func startYouTube() async {
        stop()
        includeSystemAudio = true
        systemAudioOnly = true
        meetingTarget = .all
        UserDefaults.standard.removeObject(forKey: "systemAudioDiagnosticError")
        UserDefaults.standard.set(0, forKey: "systemAudioDiagnosticSTTCharacters")
        await start()
    }
    func handleCaptureFailure(_ error: String) {
        let recoverablePrefix = error.hasPrefix("[AUDIO_ROUTE_CHANGED]") || error.hasPrefix("[SYSTEM_AUDIO_RECONNECT]") || error.hasPrefix("[CLOUD_STT_RECONNECT]")
        if Date().timeIntervalSince(listeningStartedAt) > 30 { routeRetries = 0 }
        let reconnect = recoverablePrefix && listening && routeRetries < 5
        stop()
        if reconnect {
            routeRetries += 1
            if error.hasPrefix("[SYSTEM_AUDIO_RECONNECT]") {
                sttStatus = "Mac 재생음 스트림 재연결 중 (\(routeRetries)/5)…"
            } else if error.hasPrefix("[CLOUD_STT_RECONNECT]") {
                sttStatus = "클라우드 STT 재연결 중 (\(routeRetries)/5)…"
            } else {
                sttStatus = "오디오 경로 전환 중 · 자동 재연결 (\(routeRetries)/5)…"
            }
            let stoppedRun = captureRun
            let delay = min(4.0, Double(routeRetries))
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard let self, self.captureRun == stoppedRun, !self.listening else { return }
                await self.start()
            }
        } else {
            routeRetries = 0
            message = error
                .replacingOccurrences(of: "[AUDIO_ROUTE_CHANGED] ", with: "")
                .replacingOccurrences(of: "[SYSTEM_AUDIO_RECONNECT] ", with: "")
                .replacingOccurrences(of: "[CLOUD_STT_RECONNECT] ", with: "")
        }
    }
    func receiveDuplex(source: String, text: String, prefix: String) {
        stableCloudTranscript = nil
        let merged = duplex.update(source: source, text: text)
        if let index = conversations.firstIndex(where: { $0.id == selectedID }) { conversations[index].turns = nil }
        updateText([prefix, merged].filter { !$0.isEmpty }.joined(separator: "\n"))
        sttStatus = systemAudioOnly ? "Mac 재생음 STT 수신 중" : "마이크 + Mac 재생음 수신 중"
    }
    func pauseListening() {
        guard !finishingCapture else { return }
        guard listening && (settings.stt == .managed || settings.stt == .parakeet) else {
            capture.flushPartial()
            systemSpeech.flushPartial()
            stop()
            translateLatest()
            Task { [weak self] in await self?.finishPendingAnalysis() }
            return
        }
        finishingCapture = true
        sttStatus = "마지막 음성 묶음 인식 중…"
        let run = captureRun
        Task {
            if settings.stt == .parakeet {
                await parakeetMic.finish()
                await parakeetSystem.finish()
            } else {
                await managedMic.finish()
                await managedSystem.finish()
            }
            guard captureRun == run else { return }
            stop()
            translateLatest()
            await finishPendingAnalysis()
        }
    }
    private func finishPendingAnalysis() async {
        guard !simpleFastMode else { return }
        if showTranslationKeywords { await extractKeywords(automatic: true) }
        await refreshSummaries()
        await organizeScript(automatic: true)
    }
    func start() async {
        guard !starting, !listening, current?.archivedAt == nil else { return }
        starting = true
        message = nil
        let id = selectedID
        let prefix = current?.transcript ?? ""
        let run = UUID()
        captureRun = run
        liveSTT.clear()
        lastTranscriptChange = Date()
        translationBatchStartedAt = nil
        duplex = DuplexTranscript()
        let previousTurns = current?.turns ?? []
        let speakerOffset = previousTurns.compactMap(\.speaker).max() ?? 0
        defer { starting = false }
        do {
            // Parakeet TDT v3 supports English and 24 European languages.
            // If Korean/Japanese/Chinese is selected, fall back cleanly to Whisper (if installed) or Apple STT.
            var effectiveSTT = settings.stt
            if effectiveSTT == .parakeet {
                let primaryLang = systemAudioOnly ? language : effectiveMicWhisperLanguage
                if !SpeedQualityTier.supportsParakeet(languageCode: primaryLang, preferredAutoCodes: autoLanguagePrefs.preferredCodes) {
                    let hasWhisper = managedModels.selected(.stt).map { managedModels.installed.contains($0.id) } ?? false
                    effectiveSTT = hasWhisper ? .managed : .apple
                    presetNotice = "Parakeet ANE는 영어·유럽어 전용입니다. 현재 언어(\(languageName))에 맞춰 \(hasWhisper ? "Whisper" : "Apple STT")로 자동 인식합니다."
                }
            }
            if effectiveSTT == .parakeet {
                sttStatus = parakeetModels.isLoaded ? "Parakeet ANE 준비 완료" : "Parakeet ANE CoreML 모델 로딩 중…"
                _ = try await parakeetModels.ensureReady()
            }
            if effectiveSTT == .managed || settings.translation == .managed { sttStatus = "자체 모델 서버 준비 중…" }
            if effectiveSTT == .managed { try await managedModels.ensureReady(.stt) }
            if settings.translation == .managed { try await managedModels.ensureReady(.translation) }
            // Warm up dedicated local LLM asynchronously in the background so listening starts with zero added delay.
            if !simpleFastMode && (settings.effectiveLLM(for: .coach) == .managed || settings.effectiveLLM(for: .summary) == .managed || settings.effectiveLLM(for: .keywords) == .managed) {
                Task { [weak self] in
                    _ = try? await self?.managedModels.ensureReady(.llm)
                }
            }
            warmUpTranslationEngine()
            let recorder = audioRecorder
            let shouldRecord = recordAudioForReplay && id != nil
            if shouldRecord, let conversationID = id {
                let dual = !systemAudioOnly && includeSystemAudio
                let label = systemAudioOnly ? "Mac 재생음" : includeSystemAudio ? "마이크 + Mac 재생음" : "마이크"
                do {
                    try recorder.start(conversationID: conversationID, recordingsRoot: recordingsRoot, dualSource: dual, sourceSummary: label)
                    recordingConversationID = conversationID
                } catch {
                    recordingConversationID = nil
                }
            } else {
                recordingConversationID = nil
            }
            let micAudioSink: ((AVAudioPCMBuffer) -> Void)? = shouldRecord ? { buffer in recorder.append(buffer, source: .mic) } : nil
            if !systemAudioOnly {
                let currentInputs = (try? AudioInputDevices.list()) ?? inputDevices
                inputDevices = currentInputs
                let selection = AudioInputDevices.effectiveSelection(preferredUID: selectedInputUID, available: currentInputs)
                if selection.fellBackToDefault {
                    selectedInputUID = ""
                    deviceError = nil
                    if let defaultID = try? AudioInputDevices.resolve(uid: ""),
                       let defaultName = currentInputs.first(where: { $0.id == defaultID })?.name {
                        activeInputName = defaultName
                        presetNotice = "이전에 선택한 마이크가 연결되지 않아 기본 입력(\(defaultName))으로 자동 전환했습니다."
                    } else {
                        presetNotice = "이전에 선택한 마이크가 연결되지 않아 시스템 기본 입력으로 자동 전환했습니다."
                    }
                }
                if effectiveSTT == .parakeet {
                    try await parakeetMic.start(
                        modelManager: parakeetModels,
                        externalAudio: false,
                        inputDeviceUID: selectedInputUID,
                        interimInterval: sttTier.whisperStreamingInterval ?? 0.28,
                        onText: { [weak self] text in
                            guard let self, self.captureRun == run else { return }
                            self.liveSTT.clear(sourceTag: "마이크")
                            self.receiveDuplex(source: "마이크", text: text, prefix: prefix)
                        },
                        onInterim: { [weak self] interim in
                            guard let self, self.captureRun == run else { return }
                            self.liveSTT.update(text: interim, sourceTag: "마이크")
                        },
                        onError: { [weak self] error in
                            guard let self, self.captureRun == run else { return }; self.handleCaptureFailure(error)
                        },
                        onLatency: { _ in },
                        onAudioBuffer: micAudioSink
                    )
                    speakerStatus = "Parakeet TDT v3 · Apple Neural Engine 초저지연 스트리밍"
                } else if effectiveSTT == .managed {
                    let streamingStep = sttTier.whisperStreamingInterval
                    let allowLock = autoLanguagePrefs.mode == .singleLanguageFast
                    try await managedMic.start(language: effectiveMicWhisperLanguage, externalAudio: false, inputDeviceUID: selectedInputUID, key: managedModels.authorization(.stt), interimInterval: streamingStep, allowWarmLanguageLock: allowLock, onText: { [weak self] text in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.clear(sourceTag: "마이크")
                        self.receiveDuplex(source: "마이크", text: text, prefix: prefix)
                    }, onInterim: { [weak self] interim in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.update(text: interim, sourceTag: "마이크")
                    }, onError: { [weak self] error in
                        guard let self, self.captureRun == run else { return }; self.handleCaptureFailure(error)
                    }, onLatency: { [weak self] ms in self?.managedModels.record(.stt, latency: ms) }, onDetectedLanguage: { [weak self] detected in
                        guard let self, self.captureRun == run else { return }
                        self.recordDetectedLanguage(detected)
                    }, onAudioBuffer: micAudioSink)
                    speakerStatus = streamingStep != nil
                        ? "자체 Whisper STT · \(Int((streamingStep ?? 0.35) * 1000))ms 슬라이딩 스트리밍 · 입력 경로 구분"
                        : "자체 Whisper STT · 최고 정확도 문장 단위 인식 · 입력 경로 구분"
                } else if effectiveSTT == .deepgram {
                    try await cloudCapture.start(key: SecretStore.read("deepgram"), inputDeviceUID: selectedInputUID, language: effectiveMicWhisperLanguage, onUpdate: { [weak self] full, stable, turns in
                        guard let self, self.selectedID == id, self.captureRun == run else { return }
                        if self.includeSystemAudio {
                            self.receiveDuplex(source: "마이크", text: full, prefix: prefix)
                            return
                        }
                        self.stableCloudTranscript = [prefix, stable].filter { !$0.isEmpty }.joined(separator: "\n")
                        self.updateText([prefix, full].filter { !$0.isEmpty }.joined(separator: "\n"))
                        if let index = self.conversations.firstIndex(where: { $0.id == id }) {
                            self.conversations[index].turns = previousTurns + turns.map { turn in
                                var mapped = turn
                                mapped.speaker = turn.speaker.map { $0 + speakerOffset }
                                return mapped
                            }
                        }
                        self.sttStatus = "클라우드 STT 수신 중"
                    }, onError: { [weak self] error in
                        guard let self, self.captureRun == run else { return }
                        self.handleCaptureFailure(error)
                    }, onAudioBuffer: micAudioSink)
                    speakerStatus = "Deepgram 화자 구분 · 언어 전환 자동 인식"
                } else {
                    stableCloudTranscript = nil
                    let appleLocale = effectiveMicAppleLocale
                    let micSourceTag: String? = includeSystemAudio ? "마이크" : nil
                    try await capture.start(locale: appleLocale, inputDeviceUID: selectedInputUID, onTurns: { [weak self] turns in
                        guard let self, self.selectedID == id, self.captureRun == run, !self.includeSystemAudio,
                              let index = self.conversations.firstIndex(where: { $0.id == id }) else { return }
                        self.conversations[index].turns = previousTurns + turns.map { turn in
                            var mapped = turn
                            mapped.speaker = turn.speaker.map { $0 + speakerOffset }
                            return mapped
                        }
                        self.scheduleSave()
                    }, onSTTStatus: { [weak self] status in
                        guard let self, self.captureRun == run else { return }
                        if self.sttStatus != status { self.sttStatus = status }
                    }, onSpeakerStatus: { [weak self] status in
                        guard let self, self.captureRun == run else { return }
                        if self.speakerStatus != status { self.speakerStatus = status }
                    }, onText: { [weak self] text in
                        guard let self, self.selectedID == id, self.captureRun == run else { return }
                        self.liveSTT.clear(sourceTag: micSourceTag)
                        if self.sttStatus != "STT 수신 중" { self.sttStatus = "STT 수신 중" }
                        if self.includeSystemAudio { self.receiveDuplex(source: "마이크", text: text, prefix: prefix) }
                        else { self.updateText([prefix, text].filter { !$0.isEmpty }.joined(separator: "\n")) }
                    }, onInterim: { [weak self] interim in
                        guard let self, self.selectedID == id, self.captureRun == run else { return }
                        self.liveSTT.update(text: interim, sourceTag: micSourceTag)
                    }, onError: { [weak self] error in
                        guard let self, self.captureRun == run else { return }
                        self.stop(); self.message = error
                    }, onAudioBuffer: micAudioSink)
                }
            }
            if includeSystemAudio || systemAudioOnly {
                systemAudio.onLevel = { [weak self] level in Task { @MainActor in
                    guard let self, self.captureRun == run else { return }
                    self.audioLevelMonitor.level = level
                } }
                if effectiveSTT == .parakeet {
                    try await parakeetSystem.start(
                        modelManager: parakeetModels,
                        externalAudio: true,
                        inputDeviceUID: "",
                        interimInterval: sttTier.whisperStreamingInterval ?? 0.28,
                        onText: { [weak self] text in
                            guard let self, self.captureRun == run else { return }
                            self.liveSTT.clear(sourceTag: "Mac 재생음")
                            self.receiveDuplex(source: "Mac 재생음", text: text, prefix: prefix)
                        },
                        onInterim: { [weak self] interim in
                            guard let self, self.captureRun == run else { return }
                            self.liveSTT.update(text: interim, sourceTag: "Mac 재생음")
                        },
                        onError: { [weak self] error in
                            guard let self, self.captureRun == run else { return }; self.handleCaptureFailure(error)
                        },
                        onLatency: { _ in }
                    )
                } else if effectiveSTT == .managed {
                    let allowLock = autoLanguagePrefs.mode == .singleLanguageFast
                    try await managedSystem.start(language: language, externalAudio: true, inputDeviceUID: "", key: managedModels.authorization(.stt), interimInterval: sttTier.whisperStreamingInterval, allowWarmLanguageLock: allowLock, onText: { [weak self] text in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.clear(sourceTag: "Mac 재생음")
                        self.receiveDuplex(source: "Mac 재생음", text: text, prefix: prefix)
                    }, onInterim: { [weak self] interim in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.update(text: interim, sourceTag: "Mac 재생음")
                    }, onError: { [weak self] error in
                        guard let self, self.captureRun == run else { return }; self.handleCaptureFailure(error)
                    }, onLatency: { [weak self] ms in self?.managedModels.record(.stt, latency: ms) }, onDetectedLanguage: { [weak self] detected in
                        guard let self, self.captureRun == run else { return }
                        self.recordDetectedLanguage(detected)
                    })
                } else {
                    let appleLocale = language == LanguageCatalog.autoCode
                        ? (LanguageCatalog.language(for: lastFixedLanguage)?.code ?? "en-US")
                        : language
                    try await systemSpeech.start(locale: appleLocale, externalAudio: true, inputDeviceUID: "", onTurns: { _ in }, onSTTStatus: { [weak self] status in
                        guard let self, self.captureRun == run else { return }
                        if self.systemAudioOnly && self.sttStatus != status { self.sttStatus = status }
                    }, onSpeakerStatus: { _ in }, onText: { [weak self] text in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.clear(sourceTag: "Mac 재생음")
                        self.receiveDuplex(source: "Mac 재생음", text: text, prefix: prefix)
                    }, onInterim: { [weak self] interim in
                        guard let self, self.captureRun == run else { return }
                        self.liveSTT.update(text: interim, sourceTag: "Mac 재생음")
                    }, onError: { [weak self] error in
                        guard let self, self.captureRun == run else { return }
                        self.stop(); self.message = error
                    })
                }
                let useParakeetSystemSTT = effectiveSTT == .parakeet
                let useManagedSystemSTT = effectiveSTT == .managed
                let parakeetSystemCapture = parakeetSystem
                let managedSystemCapture = managedSystem
                let appleSystemCapture = systemSpeech
                // Deliver system audio buffers directly on ScreenCaptureKit's serial queue to keep strict FIFO ordering.
                systemAudio.onBuffer = { buffer in
                    if shouldRecord { recorder.append(buffer, source: .system) }
                    if useParakeetSystemSTT { parakeetSystemCapture.appendExternalAudio(buffer) }
                    else if useManagedSystemSTT { managedSystemCapture.appendExternalAudio(buffer) }
                    else { appleSystemCapture.appendExternalAudio(buffer) }
                }
                systemAudio.onError = { [weak self] error in Task { @MainActor in
                    guard let self, self.captureRun == run else { return }
                    UserDefaults.standard.set(error, forKey: "systemAudioDiagnosticError")
                    self.handleCaptureFailure(error)
                } }
                do { try await systemAudio.start(target: meetingTarget) }
                catch { throw CaptureError.message("상대방 재생음 수집을 시작하지 못했습니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 SpikDoum을 허용해주세요. \(error.localizedDescription)") }
                speakerStatus = effectiveSTT == .parakeet ? "Parakeet TDT v3 · Apple Neural Engine 초저지연 스트리밍" : effectiveSTT == .managed ? "자체 Whisper · 실시간 슬라이딩 스트리밍 · 입력 경로 구분" : systemAudioOnly ? "Mac 재생음 전용 · Apple 음성 인식" : "마이크 + Mac 재생음 · 대괄호는 입력 경로이며 실제 화자 구분과 다릅니다"
            }
            sttStatus = effectiveSTT == .parakeet ? "Parakeet ANE 연결됨 · 초저지연 대기" : effectiveSTT == .managed ? "자체 STT 연결됨 · 실시간 스트리밍 대기" : systemAudioOnly ? "Mac 소리 전용 · 영어/선택 언어 인식 대기" : effectiveSTT == .deepgram ? "클라우드 연결됨 · 음성 대기" : "마이크 연결됨 · 음성 대기"
            applyMicMuteState()
            if micMuted && !systemAudioOnly {
                sttStatus = includeSystemAudio ? "내 마이크 음소거 · Mac 재생음 수신 중" : "내 마이크 음소거됨"
            }
            listeningStartedAt = Date()
            listening = true
            summaryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled, let self else { return }
                    if !self.simpleFastMode { await self.refreshSummaries() }
                }
            }
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    let tickSeconds: Double = (self?.simpleFastMode ?? false) ? 0.9 : 2.0
                    try? await Task.sleep(for: .milliseconds(Int(tickSeconds * 1000)))
                    guard !Task.isCancelled, let self else { return }
                    if self.hasUnsavedChanges { self.save() }
                    self.translateLatest(automatic: true)
                    if !self.simpleFastMode && (self.autoAdvice || self.showTranslationKeywords) { await self.refreshAssistance() }
                }
            }
        } catch {
            _ = audioRecorder.stopAndFinalize(); recordingConversationID = nil
            parakeetMic.stop(); parakeetSystem.stop()
            managedMic.stop(); managedSystem.stop(); systemAudio.stop(); systemSpeech.stop(); capture.stop(); cloudCapture.stop()
            sttStatus = "시작 실패"; message = error.localizedDescription
            UserDefaults.standard.set(error.localizedDescription, forKey: "systemAudioDiagnosticError")
        }
    }
    func stop() {
        if !restartingForSettingsChange {
            liveCaptureRestartTask?.cancel()
            liveCaptureRestartTask = nil
        }
        finishingCapture = false
        parakeetMic.stop(); parakeetSystem.stop()
        managedMic.stop(); managedSystem.stop()
        keywordToken = UUID()
        captureRun = UUID()
        systemAudio.stop(); systemSpeech.stop(); cloudCapture.stop()
        liveSTT.clear()
        finalizeAudioRecording()
        stableCloudTranscript = nil
        sttStatus = "듣기 중지"
        summaryTask?.cancel(); summaryDebounce?.cancel(); summaryToken = UUID()
        scriptToken = UUID()
        translationDebounce?.cancel(); translationDebounce = nil
        translationWatchdog?.cancel(); translationBatchStartedAt = nil
        translationRetryCount = 0; translationRetryAfter = .distantPast
        translationTask?.cancel(); translationToken = UUID()
        translating = false; liveTranslation = ""; translationSource = ""; translationError = nil
        debounce?.cancel(); responseToken = UUID(); liveResponse = ""
        capture.stop(); timer?.cancel(); timer = nil
        listening = false
        if hasUnsavedChanges { save() }
    }
    private func finalizeAudioRecording() {
        let targetID = recordingConversationID
        recordingConversationID = nil
        guard let clip = audioRecorder.stopAndFinalize(),
              let targetID,
              let index = conversations.firstIndex(where: { $0.id == targetID }) else { return }
        if conversations[index].audioClips == nil { conversations[index].audioClips = [] }
        conversations[index].audioClips?.append(clip)
        hasUnsavedChanges = true
    }
}
