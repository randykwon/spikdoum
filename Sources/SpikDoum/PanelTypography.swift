import SwiftUI

struct PanelTypography: Codable, Equatable {
    var translation: Double = 19
    var advice: Double = 18
    var keywords: Double = 18
    var summary: Double = 16
    var sidebar: Double = 14
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "panelTypography"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        for path in paths { value[keyPath: path] = min(40, max(12, value[keyPath: path])) }
        return value
    }
    static let paths: [WritableKeyPath<Self, Double>] = [\.translation, \.advice, \.keywords, \.summary, \.sidebar]
    mutating func adjust(by delta: Double) {
        for path in Self.paths { self[keyPath: path] = min(40, max(12, self[keyPath: path] + delta)) }
    }
    func save(defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "panelTypography") } }
}

struct PanelFontControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("패널 글자 크기").font(.headline)
            HStack {
                Button("전체 작게 A−") { adjust(-2) }
                Button("전체 크게 A+") { adjust(2) }
                Spacer()
                Button("기본값") { model.panelTypography = PanelTypography(); model.sttAppearance.fontSize = 20 }
            }
            sizeRow("STT 원문", value: $model.sttAppearance.fontSize, minimum: STTAppearance.minFontSize)
            sizeRow("번역", value: $model.panelTypography.translation)
            sizeRow("답변 · 조언", value: $model.panelTypography.advice)
            sizeRow("키워드", value: $model.panelTypography.keywords)
            sizeRow("전체 · 화자별 요약", value: $model.panelTypography.summary)
            sizeRow("대화 목록", value: $model.panelTypography.sidebar)
            Text("슬라이더를 움직이면 즉시 반영되고 다음 실행에도 유지됩니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func adjust(_ delta: Double) {
        model.panelTypography.adjust(by: delta)
        model.sttAppearance.fontSize = min(STTAppearance.maxFontSize, max(STTAppearance.minFontSize, model.sttAppearance.fontSize + delta))
    }
    private func sizeRow(_ title: String, value: Binding<Double>, minimum: Double = 12) -> some View {
        HStack {
            Text(title).frame(width: 115, alignment: .leading)
            Slider(value: value, in: minimum...40, step: 1).accessibilityLabel(title + " 글자 크기")
            Text("\(Int(value.wrappedValue))pt").monospacedDigit().frame(width: 42)
        }
    }
}
