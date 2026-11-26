import Foundation

enum ManagedRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case stt, translation, llm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stt: return "STT"
        case .translation: return "번역"
        case .llm: return "코치·요약 LLM"
        }
    }
    /// Ports: 18880 = whisper-server (STT), 18881 = llama-server (Translation), 18884 = llama-server (Coach/Summary/Keywords LLM).
    var port: Int {
        switch self {
        case .stt: return 18880
        case .translation: return 18881
        case .llm: return 18884
        }
    }
    var executable: String { self == .stt ? "whisper-server" : "llama-server" }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var customFileExtension: String { self == .stt ? "bin" : "gguf" }
}

struct ManagedModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let role: ManagedRole
    let repository: String
    let revision: String
    let filename: String
    let bytes: Int64
    let sha256: String
    let note: String
    var badge: String? = nil
    var isCustom: Bool = false

    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var sourceURL: URL? { repository.isEmpty ? nil : URL(string: "https://huggingface.co/\(repository)") }
}

struct CustomManagedModel: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var role: ManagedRole
    var filename: String
    var bytes: Int64

    var asManagedModel: ManagedModel {
        ManagedModel(
            id: id,
            name: name,
            role: role,
            repository: "",
            revision: "",
            filename: "custom/\(filename)",
            bytes: bytes,
            sha256: "",
            note: "사용자가 직접 추가한 로컬 .\(role.customFileExtension) 모델",
            badge: "로컬 추가",
            isCustom: true
        )
    }
}

enum ManagedModelCatalog {
    private static let whisperRepo = "ggerganov/whisper.cpp"
    private static let whisperRev = "5359861c739e955e79d9a303bcbc70fb988958b1"

    static let all: [ManagedModel] = [
        // MARK: - STT Models (Whisper.cpp GGML — Multilingual)
        ManagedModel(
            id: "whisper-tiny",
            name: "Whisper Tiny · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-tiny.bin",
            bytes: 77691713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            note: "초경량 · 최저 지연 · 저사양/배터리 절약"
        ),
        ManagedModel(
            id: "whisper-base",
            name: "Whisper Base · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-base.bin",
            bytes: 147951465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            note: "기본 권장 · 가볍고 빠른 실시간 인식"
        ),
        ManagedModel(
            id: "whisper-small",
            name: "Whisper Small · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-small.bin",
            bytes: 487601967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            note: "균형 잡힌 다국어 정확도"
        ),
        ManagedModel(
            id: "whisper-medium-q5",
            name: "Whisper Medium Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-medium-q5_0.bin",
            bytes: 539212467,
            sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            note: "Small 크기에서 Medium급 정확도 · 양자화"
        ),
        ManagedModel(
            id: "whisper-large-v3-turbo-q5",
            name: "Whisper Large v3 Turbo Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo-q5_0.bin",
            bytes: 574041195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            note: "한국어·일본어·영어 매우 우수 · 빠른 추론 속도",
            badge: "추천"
        ),
        ManagedModel(
            id: "whisper-large-v3-turbo-q8",
            name: "Whisper Large v3 Turbo Q8 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo-q8_0.bin",
            bytes: 874188075,
            sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            note: "Large v3 Turbo 고정밀 양자화 · 높은 정확도와 속도"
        ),
        ManagedModel(
            id: "whisper-large-v3-q5",
            name: "Whisper Large v3 Q5 · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-q5_0.bin",
            bytes: 1081140203,
            sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
            note: "최고 정확도 · 억양·잡음·일본어/다국어 강점"
        ),
        ManagedModel(
            id: "whisper-medium",
            name: "Whisper Medium · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-medium.bin",
            bytes: 1533763059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            note: "비양자화 Medium · 정밀 인식"
        ),
        ManagedModel(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo · 다국어",
            role: .stt,
            repository: whisperRepo,
            revision: whisperRev,
            filename: "ggml-large-v3-turbo.bin",
            bytes: 1624555275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            note: "비양자화 Large v3 Turbo · 최고 품질 + 고속"
        ),

        // MARK: - Translation Models (llama.cpp GGUF — Metal GPU)
        ManagedModel(
            id: "qwen25-05b-q4",
            name: "Qwen2.5 0.5B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
            revision: "9217f5db79a29953eb74d5343926648285ec7e67",
            filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            bytes: 491400032,
            sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            note: "초경량 · 최저 메모리/초고속 번역 · Apache-2.0"
        ),
        ManagedModel(
            id: "qwen25-15b-q4",
            name: "Qwen2.5 1.5B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            revision: "91cad51170dc346986eccefdc2dd33a9da36ead9",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            bytes: 1117320736,
            sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
            note: "기본 권장 · 가볍고 빠른 다국어 번역 · Apache-2.0"
        ),
        ManagedModel(
            id: "gemma2-2b-q4",
            name: "Gemma 2 2B Instruct · Q4",
            role: .translation,
            repository: "bartowski/gemma-2-2b-it-GGUF",
            revision: "855f67caed130e1befc571b52bd181be2e858883",
            filename: "gemma-2-2b-it-Q4_K_M.gguf",
            bytes: 1708582752,
            sha256: "e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787",
            note: "Google Gemma 2 · 자연스러운 경량 한/영/일 번역"
        ),
        ManagedModel(
            id: "qwen3-17b-q8",
            name: "Qwen3 1.7B · Q8",
            role: .translation,
            repository: "Qwen/Qwen3-1.7B-GGUF",
            revision: "90862c4b9d2787eaed51d12237eafdfe7c5f6077",
            filename: "Qwen3-1.7B-Q8_0.gguf",
            bytes: 1834426016,
            sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
            note: "차세대 Qwen3 고정밀 경량 다국어 번역 · Apache-2.0"
        ),
        ManagedModel(
            id: "llama32-3b-q4",
            name: "Llama 3.2 3B Instruct · Q4",
            role: .translation,
            repository: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            revision: "5ab33fa94d1d04e903623ae72c95d1696f09f9e8",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            bytes: 2019377696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            note: "Meta Llama 3.2 · 영어·유럽어 회화 번역 강점"
        ),
        ManagedModel(
            id: "qwen25-3b-q4",
            name: "Qwen2.5 3B Instruct · Q4",
            role: .translation,
            repository: "Qwen/Qwen2.5-3B-Instruct-GGUF",
            revision: "7dabda4d13d513e3e842b20f0d435c732f172cbe",
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
            bytes: 2104932768,
            sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d",
            note: "한·영·일·중 유창한 번역과 빠른 속도의 균형 · Apache-2.0",
            badge: "균형 추천"
        ),
        ManagedModel(
            id: "gemma3-4b-q4",
            name: "Gemma 3 4B Instruct · Q4",
            role: .translation,
            repository: "unsloth/gemma-3-4b-it-GGUF",
            revision: "5a3566e716d80f709ed7b79817eaf7733d2a1fce",
            filename: "gemma-3-4b-it-Q4_K_M.gguf",
            bytes: 2489894016,
            sha256: "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19",
            note: "Google 최신 Gemma 3 · 한국어·일본어·영어 고품질 번역",
            badge: "추천"
        ),
        ManagedModel(
            id: "qwen3-4b-q4",
            name: "Qwen3 4B · Q4",
            role: .translation,
            repository: "Qwen/Qwen3-4B-GGUF",
            revision: "bc640142c66e1fdd12af0bd68f40445458f3869b",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            bytes: 2497280256,
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            note: "차세대 Qwen3 4B · 뛰어난 문맥 이해·다국어 번역 · Apache-2.0"
        ),
        ManagedModel(
            id: "qwen25-7b-q4",
            name: "Qwen2.5 7B Instruct · Q4",
            role: .translation,
            repository: "bartowski/Qwen2.5-7B-Instruct-GGUF",
            revision: "8911e8a47f92bac19d6f5c64a2e2095bd2f7d031",
            filename: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            bytes: 4683074240,
            sha256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
            note: "고품질 대형 번역 모델 · 16GB+ Mac 권장 · Apache-2.0"
        ),
        ManagedModel(
            id: "gemma3-12b-q4",
            name: "Gemma 3 12B Instruct · Q4",
            role: .translation,
            repository: "unsloth/gemma-3-12b-it-GGUF",
            revision: "d15e4c7dc21dc55d56bf8549db57a71ad8a2a35d",
            filename: "gemma-3-12b-it-Q4_K_M.gguf",
            bytes: 7300778336,
            sha256: "15b8fd9d8672cd4240c178c217ca781409291f34e353d2e913b29c7602ceb3ff",
            note: "최고 품질 번역 · 24GB+ Mac 권장 · Google Gemma 3"
        )
    ]

    static func model(_ id: String) -> ManagedModel? { all.first { $0.id == id } }
}
