import Foundation

enum AppStorageMigration {
    static let appSupportFolderName = "SpikDoum"
    private static let legacyAppSupportFolderName = "SpeakHelper"
    private static let legacyDefaultsSuiteName = "dev.speakhelper.app"
    private static let defaultsMigrationFlag = "spikdoumMigratedLegacyDefaultsV1"

    static func appSupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateSupportDirectoryIfNeeded(in: base, fileManager: fileManager)
        return base.appendingPathComponent(appSupportFolderName)
    }

    static func migrateSupportDirectoryIfNeeded(in baseDirectory: URL, fileManager: FileManager = .default) {
        let target = baseDirectory.appendingPathComponent(appSupportFolderName)
        let legacy = baseDirectory.appendingPathComponent(legacyAppSupportFolderName)
        guard !fileManager.fileExists(atPath: target.path),
              fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.copyItem(at: legacy, to: target)
    }

    static func migrateDefaultsIfNeeded(target: UserDefaults = .standard) {
        guard !target.bool(forKey: defaultsMigrationFlag) else { return }
        target.set(true, forKey: defaultsMigrationFlag)
        guard Bundle.main.bundleIdentifier == "dev.spikdoum.app",
              let legacy = UserDefaults(suiteName: legacyDefaultsSuiteName) else { return }
        let appKeys = [
            "conversationDeletionMode",
            "panelTypography",
            "panelLayoutOrderV1",
            "sttAppearance",
            "engineSettings",
            "meetingAudioTarget",
            "systemAudioOnly",
            "includeSystemAudio",
            "recordAudioForReplay",
            "autoStartListeningOnNewConversation",
            "recentActivitySeconds",
            "automaticAdvice",
            "bilingualCoach",
            "summaryLanguagePreferencesV1",
            "inputDeviceUID",
            "interfaceLanguage",
            "recognitionLanguage",
            "targetLanguage",
            "showTranslationKeywords",
            "keywordPanelHeight",
            "managedSTTModel",
            "managedTranslationModel",
            "coachKeywordsOnly",
            "linkedConversationView",
            "showSummaryScriptPanel",
            "scriptDisplayMode",
            "compactReadingLayoutV1",
            "alignedSentenceBlocksV1"
        ]
        for key in appKeys where target.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                target.set(value, forKey: key)
            }
        }
    }
}
