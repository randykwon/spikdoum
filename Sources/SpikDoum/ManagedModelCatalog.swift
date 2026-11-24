import Foundation

enum ManagedRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case stt, translation
    var id: String { rawValue }
    var title: String { self == .stt ? "STT" : "번역" }
    var port: Int { self == .stt ? 18880 : 18881 }
    var executable: String { self == .stt ? "whisper-server" : "llama-server" }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}
struct ManagedModel: Identifiable, Sendable {
    let id: String
    let name: String
    let role: ManagedRole
    let repository: String
    let revision: String
    let filename: String
    let bytes: Int64
    let sha256: String
    let note: String
    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
}
enum ManagedModelCatalog {
    static let all: [ManagedModel] = [
        ManagedModel(id: "whisper-tiny", name: "Whisper Tiny · 다국어", role: .stt, repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1", filename: "ggml-tiny.bin", bytes: 77691713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", note: "가벼운 모델 · 속도 우선"),
        ManagedModel(id: "whisper-base", name: "Whisper Base · 다국어", role: .stt, repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1", filename: "ggml-base.bin", bytes: 147951465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", note: "기본 권장 · 속도와 인식률의 균형"),
        ManagedModel(id: "whisper-small", name: "Whisper Small · 다국어", role: .stt, repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1", filename: "ggml-small.bin", bytes: 487601967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", note: "인식률 우선 · 더 많은 처리 시간 필요"),
        ManagedModel(id: "qwen25-15b-q4", name: "Qwen2.5 1.5B Instruct · Q4", role: .translation, repository: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", revision: "91cad51170dc346986eccefdc2dd33a9da36ead9", filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf", bytes: 1117320736, sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e", note: "다국어 번역 · 기기 내 실행 · Apache-2.0")
    ]
    static func model(_ id: String) -> ManagedModel? { all.first { $0.id == id } }
}
