import CoreGraphics
import XCTest
@testable import parrot

final class DictationSettingsTests: XCTestCase {
    func testDefaultsToFnAndHold() {
        withSettings { settings in
            XCTAssertEqual(settings.shortcut, .fn)
            XCTAssertEqual(settings.learningShortcut, .learnCorrection)
            XCTAssertEqual(settings.activationMode, .hold)
            XCTAssertEqual(settings.transcriptionLanguage, .automatic)
            XCTAssertEqual(settings.transcriptionModelPreference, .small)
        }
    }

    func testPersistsShortcutAndActivationMode() {
        withSettings { settings in
            let shortcut = HotkeyShortcut(
                keyCode: 49,
                modifiersRawValue: (
                    CGEventFlags.maskCommand.union(.maskShift)
                ).rawValue,
                isModifierOnly: false
            )
            let learningShortcut = HotkeyShortcut(
                keyCode: 3,
                modifiersRawValue: (
                    CGEventFlags.maskCommand.union(.maskShift)
                ).rawValue,
                isModifierOnly: false
            )

            settings.shortcut = shortcut
            settings.learningShortcut = learningShortcut
            settings.activationMode = .toggle
            settings.transcriptionLanguage = .german
            settings.transcriptionModelPreference = .largeTurbo

            XCTAssertEqual(settings.shortcut, shortcut)
            XCTAssertEqual(settings.learningShortcut, learningShortcut)
            XCTAssertEqual(settings.shortcut.displayName, "⇧⌘Space")
            XCTAssertEqual(settings.activationMode, .toggle)
            XCTAssertEqual(settings.transcriptionLanguage, .german)
            XCTAssertEqual(settings.transcriptionModelPreference, .largeTurbo)
        }
    }

    func testLanguageSelectsCompatibleModelAndDecodeOptions() {
        let small = ModelRegistry.preferred(for: .english)
        XCTAssertEqual(small?.id, ModelRegistry.preferred(for: .automatic)?.id)
        XCTAssertEqual(small?.engine, .whisperKit)
        XCTAssertTrue(small?.languages.contains("multi") == true)
        XCTAssertEqual(small?.id, "whisper-small")
        XCTAssertEqual(small?.sizeMB, 488)

        let large = ModelRegistry.preferred(
            for: .english,
            modelPreference: .largeTurbo
        )
        XCTAssertEqual(large?.id, "whisper-large-v3-turbo")
        XCTAssertEqual(large?.sizeMB, 1_620)
        XCTAssertEqual(
            Set(ModelRegistry.shared.map(\.id)),
            Set([
                "whisper-small",
                "whisper-large-v3-turbo",
                "whisper-large-v3-turbo-german-q5",
            ])
        )
        XCTAssertEqual(
            ModelRegistry.preferred(for: .german)?.id,
            "whisper-large-v3-turbo-german-q5"
        )

        let automatic = WhisperKitTranscriber.decodingOptions(for: .automatic)
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertNil(automatic.language)
        XCTAssertEqual(automatic.chunkingStrategy, .vad)
        XCTAssertEqual(automatic.concurrentWorkerCount, 1)

        let german = WhisperKitTranscriber.decodingOptions(for: .german)
        XCTAssertFalse(german.detectLanguage)
        XCTAssertEqual(german.language, "de")
        XCTAssertEqual(german.chunkingStrategy, .vad)
        XCTAssertEqual(german.temperatureFallbackCount, 1)
        XCTAssertTrue(german.skipSpecialTokens)
        XCTAssertTrue(german.withoutTimestamps)
        XCTAssertEqual(german.concurrentWorkerCount, 1)

        let detectedGerman = WhisperKitTranscriber.decodingOptions(languageCode: "de")
        XCTAssertFalse(detectedGerman.detectLanguage)
        XCTAssertEqual(detectedGerman.language, "de")
        XCTAssertEqual(detectedGerman.chunkingStrategy, .vad)
    }

    func testProcessMemorySnapshotIncludesPhysicalFootprint() {
        guard let snapshot = ProcessMemorySnapshot.current() else {
            XCTFail("task_info should return a process memory snapshot")
            return
        }
        XCTAssertGreaterThan(snapshot.residentBytes, 0)
        XCTAssertGreaterThan(snapshot.physicalFootprintBytes, 0)
        XCTAssertTrue(snapshot.summary.contains("rss="))
        XCTAssertTrue(snapshot.summary.contains("footprint="))
    }

    func testGermanSpecialistHasPinnedDownloadMetadata() {
        let german = ModelRegistry.preferred(for: .german)
        XCTAssertEqual(german?.engine, .whisperCpp)
        XCTAssertEqual(german?.languages, ["de"])
        XCTAssertEqual(
            german?.sha256,
            "15e92e3db0993c52fffa781513eec9253475331c1be808f8fb409285c9d9d030"
        )
        XCTAssertNotNil(german?.downloadURL)
    }

    func testWhisperKitCacheDoesNotRequireDocumentsPermission() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        XCTAssertTrue(
            WhisperKitModelStore.downloadBase.standardizedFileURL.path
                .hasPrefix(applicationSupport.standardizedFileURL.path + "/")
        )
        XCTAssertFalse(WhisperKitModelStore.downloadBase.path.contains("/Documents/"))
    }

    func testWhisperKitInferenceWarmUpUsesThreeSecondsOfDiscardedSilence() {
        XCTAssertEqual(
            WhisperKitTranscriber.inferenceWarmUpAudio.count,
            48_000
        )
        XCTAssertTrue(
            WhisperKitTranscriber.inferenceWarmUpAudio.allSatisfy { $0 == 0 }
        )
    }

    func testAppAndStatusItemUseIndependentStableIdentity() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.pkheisig.parrot")
        XCTAssertFalse(AppIdentity.statusItemAutosaveName.contains("codex"))
        XCTAssertTrue(AppIdentity.statusItemAutosaveName.hasPrefix(AppIdentity.bundleIdentifier))
    }

    func testNamesLeftAndRightModifierShortcuts() {
        XCTAssertEqual(
            HotkeyShortcut(
                keyCode: 58,
                modifiersRawValue: CGEventFlags.maskAlternate.rawValue,
                isModifierOnly: true
            ).displayName,
            "Left Option"
        )
        XCTAssertEqual(
            HotkeyShortcut(
                keyCode: 61,
                modifiersRawValue: CGEventFlags.maskAlternate.rawValue,
                isModifierOnly: true
            ).displayName,
            "Right Option"
        )
    }

    private func withSettings(_ body: (DictationSettings) -> Void) {
        let suiteName = "com.digimata.parrot.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(DictationSettings(defaults: defaults))
    }
}
