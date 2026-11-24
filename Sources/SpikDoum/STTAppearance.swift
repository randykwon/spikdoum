import SwiftUI
import AppKit

struct DisplayColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
}
struct STTAppearance: Codable, Equatable {
    var fontSize: Double = 20
    var text = DisplayColor(0.94, 0.96, 1)
    var background = DisplayColor(0.06, 0.10, 0.18)
    var latestText = DisplayColor(1, 1, 1)
    var latestBackground = DisplayColor(0.08, 0.25, 0.60)
    static let minFontSize: Double = 10
    static let maxFontSize: Double = 40
    var latestFontSize: Double { fontSize + (fontSize <= 13 ? 1 : 3) }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "sttAppearance"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.fontSize = min(maxFontSize, max(minFontSize, value.fontSize))
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "sttAppearance") } }
}
struct STTAppearanceControls: View {
    @ObservedObject var model: AppModel
    private func binding(_ path: WritableKeyPath<STTAppearance, DisplayColor>) -> Binding<Color> {
        Binding(get: { model.sttAppearance[keyPath: path].color }, set: { model.sttAppearance[keyPath: path] = DisplayColor(color: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("글자 크기")
                Slider(value: $model.sttAppearance.fontSize, in: STTAppearance.minFontSize...STTAppearance.maxFontSize, step: 1)
                Text("\(Int(model.sttAppearance.fontSize))pt").monospacedDigit().frame(width: 44)
            }
            ColorPicker("기본 글자색", selection: binding(\.text), supportsOpacity: false)
            ColorPicker("패널 배경색", selection: binding(\.background), supportsOpacity: false)
            ColorPicker("최신 발언 글자색", selection: binding(\.latestText), supportsOpacity: false)
            ColorPicker("최신 발언 배경색", selection: binding(\.latestBackground), supportsOpacity: false)
            VStack(alignment: .leading, spacing: 8) {
                Text("이전 대화 · 미리보기").font(.system(size: model.sttAppearance.fontSize)).foregroundStyle(model.sttAppearance.text.color)
                Text("지금 들어오는 최신 발언입니다.")
                    .font(.system(size: model.sttAppearance.latestFontSize, weight: .semibold))
                    .foregroundStyle(model.sttAppearance.latestText.color).padding(10)
                    .background(model.sttAppearance.latestBackground.color, in: RoundedRectangle(cornerRadius: 10))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(model.sttAppearance.background.color, in: RoundedRectangle(cornerRadius: 12))
            Button("기본 스타일로 복원") { model.sttAppearance = STTAppearance() }
        }
    }
}
