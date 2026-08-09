import AppKit
import ApplicationServices
import ArgumentParser
import Darwin
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon with a configurable global hotkey.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Models.self, Install.self,
            TranscribeFile.self, DeliverTest.self,
        ],
        defaultSubcommand: Run.self
    )
}

/// Internal end-to-end delivery probe used by the local UI test harness. It
/// deliberately bypasses audio and model inference while exercising the exact
/// production target capture and TextInjector transaction.
struct DeliverTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deliver-test",
        abstract: "Deliver transcript text to the focused application for UI verification."
    )

    @Argument(help: "Text to deliver to the focused application.")
    var text: String

    mutating func run() throws {
        let text = self.text
        Task { @MainActor in
            let target = TextInjector.captureTarget()
            var output: [String] = []
            if let target {
                output.append(
                    "target=\(target.applicationName)[\(target.processIdentifier)] "
                        + "classification=\(target.classification.logLabel)"
                )
            } else {
                output.append("target=none")
            }
            let candidateSnapshot = FocusedTextSnapshot.capture()
            let snapshot = target.flatMap { target in
                candidateSnapshot?.belongs(to: target.processIdentifier) == true
                    ? candidateSnapshot
                    : nil
            }
            let delivery = await TextInjector.deliver(
                TextDeliveryFormatter.withTrailingSpace(text),
                to: target,
                verificationSnapshot: snapshot
            )
            output.append(delivery.testDescription)
            FileHandle.standardOutput.write(
                Data((output.joined(separator: "\n") + "\n").utf8)
            )
            Darwin.exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    func run() throws {
        let settings = DictationSettings()
        let dictionary = CorrectionDictionaryStore()
        let isAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        if !skipDoctor, !isAppBundle {
            let checks = DoctorReport.run(shortcut: settings.shortcut)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.preferred(
                for: settings.transcriptionLanguage,
                modelPreference: settings.transcriptionModelPreference
            ) else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriptionService = TranscriptionService(
            model: chosenModel,
            language: settings.transcriptionLanguage,
            modelPreference: settings.transcriptionModelPreference,
            usesExplicitModel: model != nil,
            dictionary: dictionary
        )
        let readyModelID = chosenModel.id
        let memoryPressureMonitor = RuntimeMemoryPressureMonitor {
            Task {
                await transcriptionService.handleMemoryPressure()
            }
        }
        let modelWarmupScheduler = ModelWarmupScheduler {
            try await transcriptionService.keepWarm()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(
            shortcut: settings.shortcut,
            learningShortcut: settings.learningShortcut,
            debug: debugHotkey
        )
        let capture = AudioCapture()
        let learningController = MainActor.assumeIsolated {
            CorrectionLearningController()
        }
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // The standalone CLI remains headless. Only the signed .app owns a
        // status item, avoiding the duplicate "parrot" identity macOS creates
        // for /usr/local/bin/parrot.
        let menuBar: MenuBarController? = MainActor.assumeIsolated {
            isAppBundle
                ? MenuBarController(
                    modelID: chosenModel.id,
                    settings: settings,
                    dictionary: dictionary
                )
                : nil
        }
        var activationMode = settings.activationMode
        var recordingMode = activationMode
        var isRecording = false
        var recordingContextTask: Task<DeliveryContext, Never>?
        let readiness = MainActor.assumeIsolated {
            RuntimeReadiness(modelReady: !isAppBundle)
        }
        MainActor.assumeIsolated {
            menuBar?.onShortcutChanged = { shortcut in
                monitor.setShortcut(shortcut)
            }
            menuBar?.onLearningShortcutChanged = { shortcut in
                monitor.setLearningShortcut(shortcut)
            }
            menuBar?.onActivationModeChanged = { mode in
                activationMode = mode
            }
            menuBar?.onLanguageChanged = { language in
                readiness.modelReady = false
                menuBar?.setLoading(language)
                Task {
                    do {
                        guard let modelID = try await transcriptionService.setLanguage(language)
                        else { return }
                        await MainActor.run {
                            readiness.modelReady = true
                            menuBar?.setReady(
                                modelID: modelID,
                                language: language,
                                modelPreference: settings.transcriptionModelPreference
                            )
                        }
                    } catch {
                        FileHandle.standardError.write(Data(
                            "language model load failed: \(error)\n".utf8
                        ))
                        await MainActor.run {
                            readiness.modelReady = true
                            menuBar?.setLanguageError("model load failed · try again")
                        }
                    }
                }
            }
            menuBar?.onModelPreferenceChanged = { modelPreference in
                readiness.modelReady = false
                menuBar?.setLoading(settings.transcriptionLanguage)
                Task {
                    do {
                        guard let modelID = try await transcriptionService
                            .setModelPreference(modelPreference)
                        else { return }
                        await MainActor.run {
                            readiness.modelReady = true
                            menuBar?.setReady(
                                modelID: modelID,
                                language: settings.transcriptionLanguage,
                                modelPreference: modelPreference
                            )
                        }
                    } catch {
                        FileHandle.standardError.write(Data(
                            "transcription model load failed: \(error)\n".utf8
                        ))
                        await MainActor.run {
                            readiness.modelReady = true
                            menuBar?.setLanguageError("model load failed · try again")
                        }
                    }
                }
            }
        }

        let handleHotkey: (HotkeyMonitor.Event) -> Void = { event in
            switch event {
            case .pressed:
                guard MainActor.assumeIsolated({ readiness.modelReady }) else {
                    MainActor.assumeIsolated {
                        menuBar?.setUnavailable("model is still loading…")
                    }
                    return
                }
                if recordingMode == .toggle, isRecording {
                    isRecording = false
                    let releaseTime = RuntimeClock.now()
                    let initialContextTask = recordingContextTask
                    recordingContextTask = nil
                    let releaseContextTask = Task { @MainActor in
                        guard !Task.isCancelled else { return DeliveryContext() }
                        return DeliveryContext.capture()
                    }
                    let stopStarted = RuntimeClock.now()
                    let samples = capture.stop()
                    let captureStopElapsed = RuntimeClock.seconds(since: stopStarted)
                    transcribe(
                        samples: samples,
                        transcriptionService: transcriptionService,
                        overlay: overlay,
                        menuBar: menuBar,
                        dumpWav: dumpWav,
                        learningController: learningController,
                        initialDeliveryContext: initialContextTask,
                        releaseDeliveryContext: releaseContextTask,
                        releaseTime: releaseTime,
                        captureStopElapsed: captureStopElapsed
                    )
                    return
                }
                guard !isRecording else { return }
                recordingMode = activationMode
                do {
                    try capture.start()
                } catch {
                    FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    return
                }
                isRecording = true
                recordingContextTask = Task { @MainActor in
                    guard !Task.isCancelled else { return DeliveryContext() }
                    return DeliveryContext.capture()
                }
                FileHandle.standardError.write(Data("● recording\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.show(.recording)
                    menuBar?.setRecording(true)
                }
                Task(priority: .userInitiated) {
                    do {
                        if try await transcriptionService.prepareForRecording() {
                            FileHandle.standardError.write(Data(
                                "model refreshed during recording\n".utf8
                            ))
                        }
                    } catch {
                        FileHandle.standardError.write(Data(
                            "recording-start warmup failed: \(error)\n".utf8
                        ))
                    }
                }
            case .released:
                guard recordingMode == .hold, isRecording else { return }
                isRecording = false
                let releaseTime = RuntimeClock.now()
                let initialContextTask = recordingContextTask
                recordingContextTask = nil
                let releaseContextTask = Task { @MainActor in
                    guard !Task.isCancelled else { return DeliveryContext() }
                    return DeliveryContext.capture()
                }
                let stopStarted = RuntimeClock.now()
                let samples = capture.stop()
                let captureStopElapsed = RuntimeClock.seconds(since: stopStarted)
                transcribe(
                    samples: samples,
                    transcriptionService: transcriptionService,
                    overlay: overlay,
                    menuBar: menuBar,
                    dumpWav: dumpWav,
                    learningController: learningController,
                    initialDeliveryContext: initialContextTask,
                    releaseDeliveryContext: releaseContextTask,
                    releaseTime: releaseTime,
                    captureStopElapsed: captureStopElapsed
                )
            case .cancelRequested:
                guard isRecording else { return }
                isRecording = false
                _ = capture.stop()
                recordingContextTask?.cancel()
                recordingContextTask = nil
                FileHandle.standardError.write(Data("recording canceled\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar?.setRecording(false)
                }
            case .learnCorrectionRequested:
                NSLog("Parrot Learn hotkey received")
                guard !isRecording else {
                    MainActor.assumeIsolated {
                        menuBar?.showLearningError(
                            "Finish or cancel the recording before learning a correction."
                        )
                    }
                    return
                }
                MainActor.assumeIsolated {
                    do {
                        let proposals = try learningController.proposals()
                        let learned = menuBar?.confirmCorrections(proposals) ?? 0
                        if learned > 0 {
                            learningController.clear()
                            menuBar?.setLearningStatus(
                                learned == 1
                                    ? "learned 1 correction"
                                    : "learned \(learned) corrections"
                            )
                        }
                    } catch {
                        menuBar?.showLearningError(error.localizedDescription)
                        NSLog(
                            "Parrot correction learning failed: %@",
                            error.localizedDescription
                        )
                        FileHandle.standardError.write(Data(
                            "learn correction failed: \(error.localizedDescription)\n".utf8
                        ))
                    }
                }
            }
        }

        if isAppBundle {
            MainActor.assumeIsolated {
                menuBar?.setLoading(settings.transcriptionLanguage)
            }

            do {
                try monitor.start(onEvent: handleHotkey)
                MainActor.assumeIsolated {
                    readiness.monitorStarted = true
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "failed to register hotkey tap: \(error)\n".utf8
                ))
                MainActor.assumeIsolated {
                    menuBar?.setUnavailable(
                        "Accessibility required · enable Parrot; it will reconnect"
                    )
                    _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                        guard AXIsProcessTrusted() else { return }
                        Task { @MainActor in
                            do {
                                try monitor.start(onEvent: handleHotkey)
                                readiness.monitorStarted = true
                                timer.invalidate()
                                if readiness.modelReady {
                                    menuBar?.setReady(
                                        modelID: readyModelID,
                                        language: settings.transcriptionLanguage,
                                        modelPreference: settings.transcriptionModelPreference
                                    )
                                } else {
                                    menuBar?.setLoading(settings.transcriptionLanguage)
                                }
                            } catch {
                                // Permission propagation can lag briefly after
                                // the Settings toggle. Keep retrying until the tap exists.
                            }
                        }
                    }
                }
            }

            // Load and prime the selected model in the background while the
            // menu-bar app remains responsive. The hotkey is guarded by
            // `readiness.modelReady`, so the first recording never pays the
            // Core ML download/compilation cost and the model stays hot after
            // this task completes.
            Task {
                do {
                    try await transcriptionService.warmUp()
                } catch {
                    FileHandle.standardError.write(Data("warmup failed: \(error)\n".utf8))
                    await MainActor.run {
                        menuBar?.setLanguageError("model load failed · check your connection")
                    }
                    return
                }
                await MainActor.run {
                    readiness.modelReady = true
                    modelWarmupScheduler.start()
                    if readiness.monitorStarted {
                        menuBar?.setReady(
                            modelID: readyModelID,
                            language: settings.transcriptionLanguage,
                            modelPreference: settings.transcriptionModelPreference
                        )
                    }
                }
            }
        } else {
            let warmupSemaphore = DispatchSemaphore(value: 0)
            var warmupError: Error?
            Task.detached {
                do {
                    try await transcriptionService.warmUp()
                } catch {
                    warmupError = error
                }
                warmupSemaphore.signal()
            }
            warmupSemaphore.wait()
            if let warmupError {
                FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
                throw ExitCode(1)
            }
            modelWarmupScheduler.start()
            do {
                try monitor.start(onEvent: handleHotkey)
            } catch {
                FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
                throw ExitCode(1)
            }
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            modelWarmupScheduler.stop()
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "listening on \(settings.shortcut.displayName) \(settings.activationMode.rawValue) · model: \(chosenModel.id) · ^C to quit\n"
                .utf8
        ))
        withExtendedLifetime(memoryPressureMonitor) {
            withExtendedLifetime(modelWarmupScheduler) {
                app.run()
            }
        }
    }
}

@MainActor
private final class RuntimeReadiness {
    var modelReady: Bool
    var monitorStarted = false

    init(modelReady: Bool) {
        self.modelReady = modelReady
    }
}

private struct DeliveryContext: Sendable {
    let target: TextInjector.Target?
    let snapshot: FocusedTextSnapshot?

    init(
        target: TextInjector.Target? = nil,
        snapshot: FocusedTextSnapshot? = nil
    ) {
        self.target = target
        self.snapshot = snapshot
    }

    static func capture() -> DeliveryContext {
        DeliveryContext(
            target: TextInjector.captureTarget(),
            snapshot: FocusedTextSnapshot.capture()
        )
    }
}

private func transcribe(
    samples: [Float],
    transcriptionService: TranscriptionService,
    overlay: RecordingOverlay?,
    menuBar: MenuBarController?,
    dumpWav: Bool,
    learningController: CorrectionLearningController,
    initialDeliveryContext: Task<DeliveryContext, Never>?,
    releaseDeliveryContext: Task<DeliveryContext, Never>,
    releaseTime: UInt64,
    captureStopElapsed: Double
) {
    MainActor.assumeIsolated {
        overlay?.show(.transcribing)
        menuBar?.setTranscribing()
    }
    Task(priority: .userInitiated) {
        do {
            let queueDelay = RuntimeClock.seconds(since: releaseTime)
            let taskDelayAfterStop = queueDelay - captureStopElapsed
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(samples)
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
            ))
            if dumpWav, !samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                    FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                }
            }
            guard !samples.isEmpty else {
                await MainActor.run {
                    overlay?.hide()
                    menuBar?.setRecording(false)
                }
                return
            }

            let started = RuntimeClock.now()
            let text = try await transcriptionService.transcribe(samples)
            let elapsed = RuntimeClock.seconds(since: started)
            let releaseContext = await releaseDeliveryContext.value
            let initialContext: DeliveryContext
            if let initialDeliveryContext {
                initialContext = await initialDeliveryContext.value
            } else {
                initialContext = DeliveryContext()
            }
            let deliveryTarget = releaseContext.target ?? initialContext.target
            let deliverySnapshot = releaseContext.snapshot ?? initialContext.snapshot
            FileHandle.standardError.write(Data(
                String(
                    format: "→ decode %.2fs · stop %.3fs · stop→task %.3fs · %@\n",
                    elapsed,
                    captureStopElapsed,
                    max(0, taskDelayAfterStop),
                    text
                ).utf8
            ))
            await deliverTranscript(
                text,
                overlay: overlay,
                menuBar: menuBar,
                learningController: learningController,
                deliveryTarget: deliveryTarget,
                deliverySnapshot: deliverySnapshot
            )
        } catch {
            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
            await MainActor.run {
                overlay?.hide()
                menuBar?.setRecording(false)
            }
        }
    }
}

@MainActor
private func deliverTranscript(
    _ text: String,
    overlay: RecordingOverlay?,
    menuBar: MenuBarController?,
    learningController: CorrectionLearningController,
    deliveryTarget: TextInjector.Target?,
    deliverySnapshot: FocusedTextSnapshot?
) async {
    guard !text.isEmpty else {
        overlay?.hide()
        menuBar?.setRecording(false)
        return
    }
    let target = deliveryTarget ?? TextInjector.captureTarget()
    let candidateSnapshot = deliverySnapshot ?? FocusedTextSnapshot.capture()
    let snapshot: FocusedTextSnapshot?
    if let target,
       candidateSnapshot?.belongs(to: target.processIdentifier) == true {
        snapshot = candidateSnapshot
    } else {
        snapshot = nil
    }
    let deliveryText = TextDeliveryFormatter.withTrailingSpace(text)
    let delivery = await TextInjector.deliver(
        deliveryText,
        to: target,
        verificationSnapshot: snapshot
    )
    learningController.remember(insertedText: text, snapshot: snapshot)
    menuBar?.setRecording(false)

    switch delivery {
    case .verifiedInserted, .insertedIntoTextTarget:
        overlay?.hide()
    case .unverifiedWithClipboardBackup:
        FileHandle.standardError.write(Data(
            "delivery unverified · clipboard backup retained\n".utf8
        ))
        overlay?.showCopiedToClipboard()
        menuBar?.setCopiedToClipboard()
    case .copiedToClipboard:
        FileHandle.standardError.write(Data(
            "no writable text target · copied transcript to clipboard\n".utf8
        ))
        overlay?.showCopiedToClipboard()
        menuBar?.setCopiedToClipboard()
    case .deliveryFailed:
        FileHandle.standardError.write(Data(
            "delivery failed · clipboard unavailable\n".utf8
        ))
        overlay?.showDeliveryFailure()
        menuBar?.setDeliveryFailure()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and hotkey configuration."
    )

    func run() throws {
        let checks = DoctorReport.run(shortcut: DictationSettings().shortcut)
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = ModelRegistry.recommended()?.id == m.id ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t: any Transcriber
            switch m.engine {
            case .whisperKit:
                t = WhisperKitTranscriber(model: m)
            case .whisperCpp:
                t = WhisperCppTranscriber(model: m)
            }

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}

/// Internal smoke-test path for exercising the same language router as live
/// dictation without requiring microphone or Accessibility access.
struct TranscribeFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-file",
        abstract: "Transcribe an audio file (internal verification command).",
        shouldDisplay: false
    )

    @Argument(help: "One or more audio files. The model is loaded once for the complete batch.")
    var paths: [String]

    @Option(name: .long, help: "automatic, english, or german")
    var language: String = TranscriptionLanguage.automatic.rawValue

    @Option(name: .long, help: "Model id to benchmark instead of the language default.")
    var modelID: String?

    @Flag(name: .long, help: "Include per-file elapsed time in the output.")
    var benchmark: Bool = false

    @Option(name: .long, help: "Temporary correction alias for verification.")
    var correctionAlias: String?

    @Option(name: .long, help: "Temporary correction spelling for verification.")
    var correctionCanonical: String?

    func run() throws {
        guard let selectedLanguage = TranscriptionLanguage(rawValue: language) else {
            throw ValidationError("language must be automatic, english, or german")
        }
        let model: TranscriptionModel
        let usesExplicitModel: Bool
        if let modelID {
            guard let selectedModel = ModelRegistry.find(modelID) else {
                throw ValidationError("unknown model: \(modelID)")
            }
            model = selectedModel
            usesExplicitModel = true
        } else {
            guard let selectedModel = ModelRegistry.preferred(for: selectedLanguage) else {
                throw ValidationError("no model is registered for \(selectedLanguage.rawValue)")
            }
            model = selectedModel
            usesExplicitModel = false
        }

        guard (correctionAlias == nil) == (correctionCanonical == nil) else {
            throw ValidationError(
                "--correction-alias and --correction-canonical must be provided together"
            )
        }
        let dictionary: CorrectionDictionaryStore
        if let correctionAlias, let correctionCanonical {
            dictionary = CorrectionDictionaryStore(persistent: false)
            guard dictionary.upsert(
                alias: correctionAlias,
                canonical: correctionCanonical
            ) != nil else {
                throw ValidationError("temporary correction is invalid")
            }
        } else {
            dictionary = CorrectionDictionaryStore()
        }

        let recordings = try paths.map { path in
            (path, try AudioProcessor.loadAudioAsFloatArray(fromPath: path))
        }
        let service = TranscriptionService(
            model: model,
            language: selectedLanguage,
            usesExplicitModel: usesExplicitModel,
            dictionary: dictionary
        )
        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<[(String, String, TimeInterval)], Error>?
        Task.detached {
            do {
                try await service.warmUp()
                var transcripts: [(String, String, TimeInterval)] = []
                for (path, samples) in recordings {
                    let started = Date()
                    let text = try await service.transcribe(samples)
                    transcripts.append((path, text, Date().timeIntervalSince(started)))
                }
                capturedResult = .success(transcripts)
            } catch {
                capturedResult = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch capturedResult {
        case let .success(transcripts):
            for (path, text, elapsed) in transcripts {
                if benchmark || transcripts.count > 1 {
                    print("\(path)\t\(String(format: "%.3f", elapsed))s\t\(text)")
                } else {
                    print(text)
                }
            }
        case let .failure(error):
            throw error
        case nil:
            throw TranscriberError.notLoaded
        }
    }
}
