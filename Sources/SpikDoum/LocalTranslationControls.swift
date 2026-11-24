import SwiftUI

struct LocalTranslationControls: View {
    @ObservedObject var model: AppModel
    @Binding var key: String
    @State private var testing = false
    @State private var testText = "Hello. How are you?"
    @State private var testResult: String?
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("번역 API 주소", text: $model.settings.localTranslation.endpoint)
            SecureField("번역 서버 Bearer API 키 (선택)", text: $key)
            Stepper("응답 대기: \(Int(model.settings.localTranslation.timeout))초", value: $model.settings.localTranslation.timeout, in: 5...120, step: 5)
            Text("원문 묶음을 이 주소로 POST하여 한국어 번역을 받습니다. 조언·요약의 LLM 설정과 별도로 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("API 요청 · 응답 형식") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("서버 API에 맞춰 요청 JSON을 수정하세요. {{text}}는 원문, {{source}}는 인식 언어 코드, {{target}}은 ko로 치환합니다.").font(.caption)
                    TextEditor(text: $model.settings.localTranslation.requestJSON).font(.system(.caption, design: .monospaced)).frame(height: 100)
                    TextField("응답 경로 · 비우면 자동 감지", text: $model.settings.localTranslation.responsePath)
                    Text("예: translation, translated_text, data.translation, translations.0.text. API에 맞춰 언어를 English / Korean 등으로 직접 입력할 수도 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }
            TextField("연결 테스트 원문", text: $testText)
            HStack {
                Button(testing ? "번역 확인 중…" : "로컬 번역 테스트") {
                    testTask = Task { await testTranslation() }
                }.disabled(testing || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testing { Button("취소") { testTask?.cancel() }; ProgressView().controlSize(.small) }
            }
            if let testResult { Text(testResult).font(.caption).lineLimit(6).textSelection(.enabled) }
        }.onDisappear { testTask?.cancel() }
    }
    @MainActor private func testTranslation() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let start = Date()
            let result = try await LocalTranslator(settings: model.settings.localTranslation, key: key).translate(testText, source: String(model.language.prefix(2)))
            testResult = "번역 성공 · \(Int(Date().timeIntervalSince(start) * 1000))ms\n\(result)"
        } catch {
            testResult = Task.isCancelled ? "테스트를 취소했습니다." : "연결/번역 확인 실패: \(error.localizedDescription)"
        }
    }
}
