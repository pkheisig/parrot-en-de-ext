import Foundation
import CoreML
import OSLog
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    private static let logger = Logger(
        subsystem: "com.pkheisig.parrot",
        category: "transcription"
    )

    let modelID: String
    private let model: TranscriptionModel
    private let defaultLanguage: TranscriptionLanguage
    private let dictionary: CorrectionDictionaryStore?
    private var pipeline: WhisperKit?
    private var loadTask: Task<Void, Error>?
    private let operationGate = AsyncOperationGate()

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage = .english,
        dictionary: CorrectionDictionaryStore? = nil
    ) {
        self.modelID = model.id
        self.model = model
        // English-only checkpoints cannot perform language detection.
        self.defaultLanguage = model.languages.contains("multi") ? language : .english
        self.dictionary = dictionary
    }

    /// Loads the model into memory; downloads first if not already on disk, then
    /// runs one discarded inference so Core ML compilation cannot delay the
    /// user's first dictation.
    func warmUp() async throws {
        if let loadTask {
            try await loadTask.value
            return
        }
        if pipeline != nil { return }
        let loadTask = Task { [self] in
            try await withOperation(priority: .maintenance) {
                try await loadPipeline()
            }
        }
        self.loadTask = loadTask
        do {
            try await loadTask.value
            self.loadTask = nil
        } catch {
            self.loadTask = nil
            throw error
        }
    }

    private func loadPipeline() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        let memory = MemoryPeakTracker(label: "load \(model.id)")
        defer { memory.logFinish() }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        // `prewarm` loads every CoreML model twice. That reduces peak memory,
        // but turns Large models into a multi-minute startup gate. A menu-bar
        // dictation app needs one normal load and immediate input readiness.
        // The default macOS configuration specializes both encoder and decoder
        // for the Neural Engine. A wedged ANECompilerService can then block the
        // entire app indefinitely. Base models are fast enough on GPU and this
        // path loads independently of the ANE compiler service.
        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: WhisperKitModelStore.downloadBase,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: false,
            load: true
        )
        let loadedPipeline = try await WhisperKit(config)
        pipeline = loadedPipeline

        let inferenceStarted = Date()
        _ = try await loadedPipeline.transcribe(
            audioArray: Self.inferenceWarmUpAudio,
            decodeOptions: Self.decodingOptions(for: defaultLanguage)
        )
        let inferenceElapsed = Date().timeIntervalSince(inferenceStarted)
        FileHandle.standardError.write(Data(
            String(
                format: "✓ %@ ready · inference primed %.2fs\n",
                model.id,
                inferenceElapsed
            ).utf8
        ))
    }

    /// Three seconds of discarded silence are enough to compile the mel, encoder,
    /// prefill, and decoder graphs. WhisperKit does not carry transcript state
    /// between calls, so this cannot condition the subsequent real recording.
    static let inferenceWarmUpAudio = [Float](
        repeating: 0,
        count: WhisperKit.sampleRate * 3
    )

    func transcribe(_ audio: [Float]) async throws -> String {
        try await transcribe(audio, languageCode: defaultLanguage.languageCode)
    }

    /// Transcribes with a caller-selected language on the shared multilingual
    /// pipeline. Automatic routing uses this to detect and transcribe with one
    /// loaded model instead of keeping a separate detector resident.
    func transcribe(_ audio: [Float], languageCode: String?) async throws -> String {
        if pipeline == nil || loadTask != nil { try await warmUp() }

        return try await withOperation(priority: .user) { [self] in
            guard let pipeline else { throw TranscriberError.notLoaded }

            let memory = MemoryPeakTracker(label: "transcribe \(model.id)")
            defer { memory.logFinish() }
            let baselineOptions = Self.decodingOptions(languageCode: languageCode)

            func decode(
                _ decodeOptions: DecodingOptions
            ) async throws -> (text: String, language: String?) {
                let results = try await pipeline.transcribe(
                    audioArray: audio,
                    decodeOptions: decodeOptions
                )
                let raw = results.map(\.text).joined(separator: " ")
                let sanitized = Self.sanitize(raw)
                if sanitized.isEmpty, !raw.isEmpty {
                    FileHandle.standardError.write(Data(
                        "Whisper returned only non-speech tokens: \(raw)\n".utf8
                    ))
                }
                return (sanitized, results.first?.language)
            }

            // First preserve Whisper's normal audio-led recognition. Only when
            // that transcript contains a previously learned rendering do we
            // decode the same audio again with the associated spelling in its
            // context. This avoids globally biasing unrelated dictation and,
            // in Automatic mode, keeps prompt tokens out of language detection.
            let baseline = try await decode(baselineOptions)
            guard !baseline.text.isEmpty,
                  let prompt = dictionary?.promptText(matching: baseline.text),
                  let tokenizer = pipeline.tokenizer
            else { return baseline.text }

            let resolvedLanguage = languageCode ?? baseline.language
            var promptedOptions = Self.decodingOptions(
                languageCode: resolvedLanguage,
                detectLanguage: false
            )
            promptedOptions.promptTokens = tokenizer
                .encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            // WhisperKit cannot reuse its fixed prefill cache when custom
            // prompt tokens precede the language/task tokens.
            promptedOptions.usePrefillPrompt = true
            promptedOptions.usePrefillCache = false

            do {
                let prompted = try await decode(promptedOptions)
                guard !prompted.text.isEmpty else {
                    Self.logger.notice(
                        "Relevant learned-vocabulary re-decode was empty; using baseline transcript"
                    )
                    return baseline.text
                }
                return prompted.text
            } catch {
                Self.logger.error(
                    "Relevant learned-vocabulary re-decode failed; using baseline transcript: \(String(describing: error), privacy: .public)"
                )
                return baseline.text
            }
        }
    }

    func isLoaded() -> Bool {
        pipeline != nil
    }

    func unload() async {
        await operationGate.acquire(priority: .user)
        if let loadedPipeline = pipeline {
            // WhisperKit exposes an explicit lifecycle operation. Calling it
            // before dropping the pipeline releases Core ML model weights now,
            // rather than waiting for ARC/deinitialization to unwind later.
            await loadedPipeline.unloadModels()
            pipeline = nil
            RuntimeMemoryLog.write("unloaded \(model.id)")
        }
        await operationGate.release()
    }

    private func withOperation<T>(
        priority: AsyncOperationGate.Priority,
        operation: () async throws -> T
    ) async throws -> T {
        await operationGate.acquire(priority: priority)
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    static func downloadModel(_ model: TranscriptionModel) async throws {
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        _ = try await WhisperKit.download(
            variant: whisperKitID,
            downloadBase: WhisperKitModelStore.downloadBase
        )
    }

    static func decodingOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        Self.decodingOptions(
            languageCode: language.languageCode,
            detectLanguage: language == .automatic
        )
    }

    static func decodingOptions(
        languageCode: String?,
        detectLanguage: Bool? = nil
    ) -> DecodingOptions {
        let shouldDetect = detectLanguage ?? (languageCode == nil)
        return DecodingOptions(
            task: .transcribe,
            language: languageCode,
            // Interactive dictation only needs the text. Avoid producing
            // timestamp tokens and limit fallback retries, both of which can
            // multiply decoder work on long recordings.
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: shouldDetect,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // WhisperKit shares one Core ML/Metal pipeline between VAD chunks.
            // Multiple GPU workers can race its MPSGraph buffers and abort the
            // process, so chunks must be decoded serially on this pipeline.
            concurrentWorkerCount: Self.safeWorkerCount,
            chunkingStrategy: .vad
        )
    }

    static let safeWorkerCount = 1

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperKitModelStore {
    /// WhisperKit defaults to `~/Documents/huggingface`, which is protected by
    /// macOS Files and Folders privacy. A menu-bar app launched by LaunchServices
    /// can block there even though the same executable works from Terminal.
    /// Application Support belongs to Parrot and does not depend on another
    /// process having granted access to the user's Documents directory.
    static let downloadBase: URL = {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let url = root
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data(
                "Could not create WhisperKit model cache at \(url.path): \(error)\n".utf8
            ))
        }
        return url
    }()
}

actor TranscriptionService {
    /// Only the user-selected multilingual model is loaded. Keeping both actor
    /// instances lets the menu switch models without rebuilding the service;
    /// inactive pipelines are explicitly unloaded after a successful switch.
    private let smallMultilingual: WhisperKitTranscriber
    private let largeMultilingual: WhisperKitTranscriber
    private let german: WhisperCppTranscriber
    private var language: TranscriptionLanguage
    private var modelPreference: TranscriptionModelPreference
    private var configurationRequest = 0
    private let explicitModel: (any Transcriber)?
    private var activeTranscriptions = 0
    private var activeLoads = 0
    private var cleanupRequested = false
    private var memoryPressurePending = false

    init(
        model: TranscriptionModel,
        language: TranscriptionLanguage,
        modelPreference: TranscriptionModelPreference = .small,
        usesExplicitModel: Bool = false,
        dictionary: CorrectionDictionaryStore? = nil
    ) {
        guard let smallModel = ModelRegistry.find(
                  TranscriptionModelPreference.small.modelID
              ),
              let largeModel = ModelRegistry.find(
                  TranscriptionModelPreference.largeTurbo.modelID
              ),
              let germanModel = ModelRegistry.preferred(for: .german)
        else {
            preconditionFailure("Required transcription models are not registered")
        }
        let dictionary = dictionary ?? CorrectionDictionaryStore()
        self.smallMultilingual = WhisperKitTranscriber(
            model: smallModel,
            language: .automatic,
            dictionary: dictionary
        )
        self.largeMultilingual = WhisperKitTranscriber(
            model: largeModel,
            language: .automatic,
            dictionary: dictionary
        )
        self.german = WhisperCppTranscriber(model: germanModel, dictionary: dictionary)
        self.language = language
        self.modelPreference = modelPreference
        self.explicitModel = usesExplicitModel
            ? Self.makeTranscriber(
                model: model,
                language: language,
                dictionary: dictionary
            )
            : nil
    }

    func warmUp() async throws {
        activeLoads += 1
        do {
            if let explicitModel {
                try await explicitModel.warmUp()
                await finishLoad()
                return
            }
            try await transcriber(
                for: language,
                modelPreference: modelPreference
            ).warmUp()
            // This only downloads the optional explicit German specialist. It
            // is not loaded into memory and never competes with the active model.
            if language != .german {
                prefetchGermanSpecialist()
            }
            await finishLoad()
        } catch {
            await finishLoad()
            throw error
        }
    }

    func setLanguage(_ language: TranscriptionLanguage) async throws -> String? {
        configurationRequest += 1
        let request = configurationRequest
        if let explicitModel {
            // An explicit model selection is an intentional override. Do not
            // warm a second language model just because the menu setting
            // changes; that would defeat the single-resident-model guarantee.
            self.language = language
            return explicitModel.modelID
        }
        let next = transcriber(for: language, modelPreference: modelPreference)
        activeLoads += 1
        do {
            try await next.warmUp()
        } catch {
            cleanupRequested = true
            await finishLoad()
            throw error
        }
        guard request == configurationRequest else {
            cleanupRequested = true
            await finishLoad()
            return nil
        }
        self.language = language
        cleanupRequested = true
        if language != .german {
            prefetchGermanSpecialist()
        }
        await finishLoad()
        return next.modelID
    }

    func setModelPreference(
        _ modelPreference: TranscriptionModelPreference
    ) async throws -> String? {
        configurationRequest += 1
        let request = configurationRequest
        if let explicitModel {
            self.modelPreference = modelPreference
            return explicitModel.modelID
        }

        let next = transcriber(
            for: language,
            modelPreference: modelPreference
        )
        activeLoads += 1
        do {
            try await next.warmUp()
        } catch {
            cleanupRequested = true
            await finishLoad()
            throw error
        }
        guard request == configurationRequest else {
            cleanupRequested = true
            await finishLoad()
            return nil
        }
        self.modelPreference = modelPreference
        cleanupRequested = true
        await finishLoad()
        return next.modelID
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        activeTranscriptions += 1
        do {
            let raw: String
            if let explicitModel {
                raw = try await explicitModel.transcribe(audio)
            } else {
                switch language {
                case .english:
                    raw = try await multilingual(
                        for: modelPreference
                    ).transcribe(audio, languageCode: "en")
                case .german:
                    raw = try await german.transcribe(audio)
                case .automatic:
                    // WhisperKit detects the language and decodes in this one
                    // call. A separate detection pass produced identical text
                    // in the local corpus while adding ~1.65 seconds and ~1 GB.
                    raw = try await multilingual(
                        for: modelPreference
                    ).transcribe(audio, languageCode: nil)
                }
            }
            await finishTranscription()
            return raw
        } catch {
            await finishTranscription()
            throw error
        }
    }

    private func transcriber(
        for language: TranscriptionLanguage,
        modelPreference: TranscriptionModelPreference
    ) -> any Transcriber {
        switch language {
        case .automatic, .english: multilingual(for: modelPreference)
        case .german: german
        }
    }

    private func multilingual(
        for modelPreference: TranscriptionModelPreference
    ) -> WhisperKitTranscriber {
        switch modelPreference {
        case .small: smallMultilingual
        case .largeTurbo: largeMultilingual
        }
    }

    /// Called by the menu-bar process when macOS reports memory pressure.
    /// During a decode we defer release until the active operation has finished.
    func handleMemoryPressure() async {
        if activeTranscriptions > 0 || activeLoads > 0 {
            memoryPressurePending = true
            cleanupRequested = true
            return
        }
        await unloadAll()
    }

    private func finishTranscription() async {
        activeTranscriptions = max(0, activeTranscriptions - 1)
        guard activeTranscriptions == 0, activeLoads == 0 else { return }

        if memoryPressurePending {
            await unloadAll()
        } else if cleanupRequested {
            await unloadInactiveIfSafe()
        }
    }

    private func finishLoad() async {
        activeLoads = max(0, activeLoads - 1)
        guard activeLoads == 0, activeTranscriptions == 0 else { return }

        if memoryPressurePending {
            await unloadAll()
        } else if cleanupRequested {
            await unloadInactiveIfSafe()
        }
    }

    private func unloadInactiveIfSafe() async {
        guard activeTranscriptions == 0, activeLoads == 0 else {
            cleanupRequested = true
            return
        }
        guard explicitModel == nil else {
            cleanupRequested = false
            return
        }

        switch language {
        case .automatic, .english:
            await german.unload()
            switch modelPreference {
            case .small:
                await largeMultilingual.unload()
            case .largeTurbo:
                await smallMultilingual.unload()
            }
        case .german:
            await smallMultilingual.unload()
            await largeMultilingual.unload()
        }
        cleanupRequested = false
    }

    private func unloadAll() async {
        guard activeTranscriptions == 0, activeLoads == 0 else {
            memoryPressurePending = true
            cleanupRequested = true
            return
        }
        if let explicitModel {
            await explicitModel.unload()
        } else {
            await smallMultilingual.unload()
            await largeMultilingual.unload()
            await german.unload()
        }
        memoryPressurePending = false
        cleanupRequested = false
        RuntimeMemoryLog.write("all-models-released")
    }

    private nonisolated static func makeTranscriber(
        model: TranscriptionModel,
        language: TranscriptionLanguage,
        dictionary: CorrectionDictionaryStore
    ) -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            WhisperKitTranscriber(
                model: model,
                language: language,
                dictionary: dictionary
            )
        case .whisperCpp:
            WhisperCppTranscriber(model: model, dictionary: dictionary)
        }
    }

    private func prefetchGermanSpecialist() {
        guard let germanModel = ModelRegistry.preferred(for: .german)
        else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await GermanModelStore.shared.localURL(for: germanModel)
            } catch {
                FileHandle.standardError.write(Data(
                    "German specialist prefetch failed: \(error)\n".utf8
                ))
            }
        }
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
    case modelUnavailable
}
