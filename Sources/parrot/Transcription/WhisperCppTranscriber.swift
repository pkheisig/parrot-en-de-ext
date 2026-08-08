import CryptoKit
import Foundation
import whisper

actor WhisperCppTranscriber: Transcriber {
    let modelID: String

    private let model: TranscriptionModel
    private let dictionary: CorrectionDictionaryStore?
    private var context: OpaquePointer?
    private var loadTask: Task<Void, Error>?
    private var maintenanceTask: Task<Void, Error>?
    private let operationGate = AsyncOperationGate()

    init(model: TranscriptionModel, dictionary: CorrectionDictionaryStore? = nil) {
        self.model = model
        self.modelID = model.id
        self.dictionary = dictionary
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    func warmUp() async throws {
        if let loadTask {
            try await loadTask.value
            return
        }
        if context != nil { return }
        let loadTask = Task { [self] in
            try await withOperation(priority: .maintenance) {
                try await loadContext()
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

    /// Touch the Metal-backed context periodically so an idle app is less
    /// likely to pay page-in or backend setup cost on the next dictation.
    func keepWarm() async throws {
        if context == nil || loadTask != nil {
            try await warmUp()
        }
        if let maintenanceTask {
            try await maintenanceTask.value
            return
        }
        let maintenanceTask = Task { [self] in
            try await withOperation(priority: .maintenance) {
                try Task.checkCancellation()
                _ = try decode(
                    WhisperKitTranscriber.inferenceWarmUpAudio,
                    includePrompt: false
                )
            }
        }
        self.maintenanceTask = maintenanceTask
        do {
            try await maintenanceTask.value
            self.maintenanceTask = nil
        } catch {
            self.maintenanceTask = nil
            throw error
        }
    }

    func cancelKeepWarm() async {
        maintenanceTask?.cancel()
    }

    private func loadContext() async throws {
        if context != nil { return }
        let modelURL = try await GermanModelStore.shared.localURL(for: model)
        let memory = MemoryPeakTracker(label: "load \(model.id)")
        defer { memory.logFinish() }
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        parameters.flash_attn = true
        let loaded = modelURL.path.withCString {
            whisper_init_from_file_with_params($0, parameters)
        }
        guard let loaded else {
            throw WhisperCppError.modelLoadFailed(modelURL.path)
        }
        context = loaded
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if context == nil || loadTask != nil { try await warmUp() }
        return try await withOperation(priority: .user) {
            let memory = MemoryPeakTracker(label: "transcribe \(model.id)")
            defer { memory.logFinish() }
            return try decode(audio, includePrompt: true)
        }
    }

    private func decode(_ audio: [Float], includePrompt: Bool) throws -> String {
        guard let context else { throw TranscriberError.notLoaded }
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.no_timestamps = true
        parameters.translate = false
        parameters.no_context = true
        parameters.single_segment = false
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))

        func run(prompt: UnsafePointer<CChar>?) -> Int32 {
            parameters.initial_prompt = prompt
            return "de".withCString { language in
                parameters.language = language
                return audio.withUnsafeBufferPointer { samples in
                    whisper_full(
                        context,
                        parameters,
                        samples.baseAddress,
                        Int32(samples.count)
                    )
                }
            }
        }

        let result: Int32
        if includePrompt, let prompt = dictionary?.promptText() {
            result = prompt.withCString { run(prompt: $0) }
        } else {
            result = run(prompt: nil)
        }
        guard result == 0 else {
            throw WhisperCppError.transcriptionFailed(result)
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            guard let segment = whisper_full_get_segment_text(context, index) else { continue }
            text += String(cString: segment)
        }
        return WhisperKitTranscriber.sanitize(text)
    }

    func isLoaded() -> Bool {
        context != nil
    }

    func unload() async {
        await operationGate.acquire(priority: .user)
        if let context {
            whisper_free(context)
            self.context = nil
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
}

actor GermanModelStore {
    static let shared = GermanModelStore()
    static let filename = "ggml-large-v3-turbo-german-q5_0.bin"
    private var inFlight: Task<URL, Error>?

    func localURL(for model: TranscriptionModel) async throws -> URL {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await Self.obtainLocalURL(for: model) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private static func obtainLocalURL(for model: TranscriptionModel) async throws -> URL {
        guard model.engine == .whisperCpp,
              let remoteURL = model.downloadURL,
              let expectedSHA256 = model.sha256
        else {
            throw WhisperCppError.invalidModelMetadata
        }

        let directory = try modelDirectory()
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path),
           try sha256(of: destination) == expectedSHA256 {
            return destination
        }

        let partial = destination.appendingPathExtension("partial")
        if FileManager.default.fileExists(atPath: partial.path) {
            if try sha256(of: partial) == expectedSHA256 {
                try replaceItem(at: destination, with: partial)
                return destination
            }
            try FileManager.default.removeItem(at: partial)
        }

        FileHandle.standardError.write(Data(
            "downloading \(model.displayName) (\(model.sizeMB) MB)...\n".utf8
        ))
        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw WhisperCppError.downloadFailed
        }
        try FileManager.default.moveItem(at: temporaryURL, to: partial)
        let actualSHA256 = try sha256(of: partial)
        guard actualSHA256 == expectedSHA256 else {
            try? FileManager.default.removeItem(at: partial)
            throw WhisperCppError.checksumMismatch(
                expected: expectedSHA256,
                actual: actualSHA256
            )
        }
        try replaceItem(at: destination, with: partial)
        return destination
    }

    private static func modelDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum WhisperCppError: LocalizedError {
    case invalidModelMetadata
    case downloadFailed
    case checksumMismatch(expected: String, actual: String)
    case modelLoadFailed(String)
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidModelMetadata:
            "German model download metadata is incomplete."
        case .downloadFailed:
            "The German model download failed."
        case let .checksumMismatch(expected, actual):
            "German model checksum mismatch (expected \(expected), received \(actual))."
        case let .modelLoadFailed(path):
            "Could not load the German model at \(path)."
        case let .transcriptionFailed(code):
            "German transcription failed with code \(code)."
        }
    }
}
