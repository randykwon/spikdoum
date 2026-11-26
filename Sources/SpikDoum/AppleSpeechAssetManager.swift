import Foundation
import Speech

/// Manages macOS 26 on-device `SpeechAnalyzer` / `SpeechTranscriber` streaming language assets
/// so Apple STT runs with true 150–300ms volatile streaming instead of falling back to legacy `SFSpeechRecognizer`.
@MainActor
final class AppleSpeechAssetManager: ObservableObject {
    static let trackedLocales = ["en-US", "ko-KR", "ja-JP", "zh-CN"]

    @Published private(set) var installedLocales: Set<String> = []
    @Published private(set) var supportedLocales: Set<String> = []
    @Published private(set) var installingLocale: String? = nil
    @Published private(set) var installProgress: Double = 0
    @Published var lastError: String? = nil

    func isInstalled(for localeCode: String) -> Bool {
        installedLocales.contains(localeCode)
    }

    func isSupported(for localeCode: String) -> Bool {
        supportedLocales.contains(localeCode)
    }

    func refreshStatuses(extraLocale: String? = nil) async {
        guard SpeechTranscriber.isAvailable else { return }
        var targets = Self.trackedLocales
        if let extraLocale, extraLocale != LanguageCatalog.autoCode, !targets.contains(extraLocale) {
            targets.append(extraLocale)
        }
        var installed: Set<String> = []
        var supported: Set<String> = []
        for code in targets {
            guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)) else { continue }
            let module = SpeechTranscriber(
                locale: matched,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
            let status = await AssetInventory.status(forModules: [module])
            switch status {
            case .installed:
                installed.insert(code)
                supported.insert(code)
            case .supported, .downloading:
                supported.insert(code)
            case .unsupported:
                break
            @unknown default:
                break
            }
        }
        installedLocales = installed
        supportedLocales = supported
    }

    func installAsset(for localeCode: String) async {
        guard installingLocale == nil else { return }
        guard SpeechTranscriber.isAvailable else {
            lastError = "이 Mac에서는 macOS 26 실시간 SpeechTranscriber를 사용할 수 없습니다."
            return
        }
        let targetCode = localeCode == LanguageCatalog.autoCode ? "en-US" : localeCode
        guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: targetCode)) else {
            lastError = "\(targetCode) 언어는 실시간 스트리밍 에셋을 지원하지 않습니다."
            return
        }
        let module = SpeechTranscriber(
            locale: matched,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let currentStatus = await AssetInventory.status(forModules: [module])
        if currentStatus == .installed {
            installedLocales.insert(targetCode)
            supportedLocales.insert(targetCode)
            return
        }

        installingLocale = targetCode
        installProgress = 0.05
        lastError = nil
        defer {
            installingLocale = nil
            installProgress = 0
        }

        do {
            _ = try? await AssetInventory.reserve(locale: matched)
            guard let installer = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                await refreshStatuses(extraLocale: targetCode)
                return
            }
            let progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    let frac = installer.progress.fractionCompleted
                    await MainActor.run {
                        self?.installProgress = max(0.05, min(0.99, frac))
                    }
                }
            }
            defer { progressTask.cancel() }
            try await installer.downloadAndInstall()
            installProgress = 1.0
            await refreshStatuses(extraLocale: targetCode)
        } catch {
            lastError = "Apple 스트리밍 에셋 설치 실패: \(error.localizedDescription)"
        }
    }
}
