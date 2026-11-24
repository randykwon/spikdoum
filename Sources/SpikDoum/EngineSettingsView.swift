import SwiftUI

struct EngineSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deepgramKey = ""
    @State private var azureKey = ""
    @State private var openAIKey = ""
    @State private var localKey = ""
    @State private var localTranslationKey = ""
    @State private var showingModels = false
    @State private var status: String?
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.t("settings.title")).font(.title2.bold()); Spacer(); Button(model.t("action.done")) { dismiss() } }
            Form {
                Section(model.t("settings.uiLanguage")) {
                    Picker(model.t("settings.uiLanguage"), selection: $model.interfaceLanguage) {
                        ForEach(AppInterfaceLanguage.allCases) { option in
                            Text(option.displayName(in: model.uiLanguage)).tag(option)
                        }
                    }
                    Picker(model.t("settings.sttMode"), selection: Binding(
                        get: { model.isAutoDetectLanguage },
                        set: { model.setAutoDetectSTT($0) }
                    )) {
                        Text(model.t("stt.mode.auto")).tag(true)
                        Text(model.t("stt.mode.fixed")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !model.isAutoDetectLanguage {
                        Picker(model.t("settings.sourceLanguage"), selection: Binding(
                            get: { model.language },
                            set: { model.selectSTTLanguage($0) }
                        )) {
                            ForEach(LanguageCatalog.all) { lang in
                                Text(lang.displayName(in: model.uiLanguage)).tag(lang.code)
                            }
                        }
                    }
                    Picker(model.t("settings.targetLanguage"), selection: Binding(
                        get: { model.targetLanguage },
                        set: { model.selectTargetLanguage($0) }
                    )) {
                        ForEach(model.targetLanguages, id: \.0) { code, name in Text(name).tag(code) }
                    }
                }
                Section("자체 모델 · 서버") {
                    Button("STT · 번역 모델 관리 및 서버 모니터") { showingModels = true }
                    Text("모델 다운로드 후 적용하면 별도 설치 없이 이 Mac에서 서버를 실행합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("듣기 · 장치 · 추천 설정") { CaptureOptionsView(model: model) }
                Section("번역 옆 키워드") {
                    Toggle("키워드를 번역 패널에 함께 표시", isOn: $model.showTranslationKeywords)
                    Toggle("자동 답변 · 조언", isOn: $model.autoAdvice)
                }
                Section("패널 글자 크기") { PanelFontControls(model: model) }
                Section("STT 보기 스타일") { STTAppearanceControls(model: model) }
                Section("대화 삭제") {
                    Picker("삭제 버튼 동작", selection: $model.deletionMode) {
                        Text("아카이빙 · 나중에 복원 가능").tag(DeletionMode.archive)
                        Text("완전 삭제 · 확인 후 복원 불가").tag(DeletionMode.permanent)
                    }
                    Text("아카이빙은 대화를 별도 목록에 보관합니다. 완전 삭제는 원문·번역·조언·요약 이력과 앱이 관리하는 재시작 백업에서 해당 대화를 제거합니다. OS 백업과 외부 AI 서비스의 보관 데이터는 별도입니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("음성 인식 · 화자 구분") {
                    Picker("STT", selection: $model.settings.stt) {
                        Text("Apple 음성 인식").tag(STTEngine.apple)
                        Text("Deepgram Nova-3 · 다국어 · 화자 구분").tag(STTEngine.deepgram)
                        Text("자체 모델 · Whisper 서버").tag(STTEngine.managed)
                    }
                    SecureField("Deepgram API 키", text: $deepgramKey)
                    Text("클라우드 STT를 선택하면 듣기 중 음성을 Deepgram으로 전송합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("번역") {
                    Picker("번역 엔진", selection: $model.settings.translation) {
                        Text("Apple 전용 번역 · 기기 내").tag(TranslationEngine.apple)
                        Text("Azure Translator · 언어 자동 감지").tag(TranslationEngine.azure)
                        Text("로컬 LLM · 번역 API").tag(TranslationEngine.local)
                        Text("자체 모델 · 기기 내 번역 서버").tag(TranslationEngine.managed)
                    }
                    if model.settings.translation == .azure {
                        SecureField("Azure Translator 키", text: $azureKey)
                        TextField("Azure 리전 (예: koreacentral)", text: $model.settings.azureRegion)
                    }
                    if model.settings.translation == .local { LocalTranslationControls(model: model, key: $localTranslationKey) }
                }
                Section("답변 · 조언 · 전체/화자별 요약") {
                    Picker("LLM", selection: $model.settings.llm) {
                        Text("Apple Intelligence · 기기 내").tag(LLMEngine.apple)
                        Text("OpenAI API").tag(LLMEngine.openAI)
                        Text("로컬 / 내부망 · OpenAI 호환 서버").tag(LLMEngine.compatible)
                    }
                    if model.settings.llm == .openAI {
                        SecureField("OpenAI API 키", text: $openAIKey)
                        TextField("모델", text: $model.settings.cloudModel)
                    }
                    if model.settings.llm == .compatible {
                        HStack {
                            Button("Ollama") { model.settings.serverURL = "http://localhost:11434/v1" }
                            Button("LM Studio") { model.settings.serverURL = "http://localhost:1234/v1" }
                            Button("vLLM") { model.settings.serverURL = "http://localhost:8000/v1" }
                        }
                        TextField("서버 주소 · http://192.168.0.10:8000/v1", text: $model.settings.serverURL)
                        TextField("서버에서 제공하는 모델명", text: $model.settings.serverModel)
                        SecureField("서버 API 키 (인증 없는 서버는 비워두세요)", text: $localKey)
                        Text("OpenAI 호환 /chat/completions 스트리밍을 지원해야 합니다. 내부망 서버에서는 수신 주소와 방화벽도 확인하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("선택한 서버로 대화 텍스트와 대화 목표를 전송합니다. 모델명은 해당 서버에서 제공하는 이름을 입력하세요.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let status { Text(status).font(.caption).textSelection(.enabled) }
            HStack {
                Text("설정은 자동 저장됩니다. 키는 ‘API 키 저장’으로 키체인에 보관합니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("API 키 저장") { saveKeys() }
                Button(testing ? "연결 확인 중…" : "LLM 연결 테스트") { Task { await test() } }.disabled(testing || model.settings.llm == .apple)
            }
        }.padding(24).frame(width: 680, height: 760)
            .sheet(isPresented: $showingModels) { ManagedModelsView(model: model, manager: model.managedModels) }
            .disabled(model.listening || model.starting)
            .onAppear {
                deepgramKey = SecretStore.read("deepgram"); azureKey = SecretStore.read("azure")
                openAIKey = SecretStore.read("openai"); localKey = SecretStore.read("local")
                localTranslationKey = SecretStore.read("translation-local")
            }
    }
    private func saveKeys() {
        do {
            for (name, value) in [("deepgram", deepgramKey), ("azure", azureKey), ("openai", openAIKey), ("local", localKey), ("translation-local", localTranslationKey)] { try SecretStore.write(value, name: name) }
            status = "API 키를 키체인에 저장했습니다."
        } catch { status = error.localizedDescription }
    }
    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let started = Date()
            let client = LLMClient(settings: model.settings, key: model.settings.llm == .openAI ? openAIKey : localKey)
            let response = try await client.generate(instructions: "Reply with OK only.", input: "Connection test")
            status = "연결 성공 · \(Int(Date().timeIntervalSince(started) * 1000))ms · \(response.prefix(80))"
        } catch { status = error.localizedDescription }
    }
}
