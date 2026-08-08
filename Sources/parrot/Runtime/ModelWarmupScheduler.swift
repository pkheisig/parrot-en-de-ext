import Foundation

/// Periodically touches the active inference graph so Core ML/Metal has a
/// chance to re-specialize or page in model resources before the next user
/// recording. This is deliberately best-effort: macOS may still reclaim model
/// memory under pressure, and the scheduler must never prevent the app from
/// responding to a real dictation.
final class ModelWarmupScheduler: @unchecked Sendable {
    static let defaultInterval: TimeInterval = 5 * 60

    private let intervalNanoseconds: UInt64
    private let warm: @Sendable () async throws -> Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(
        interval: TimeInterval = ModelWarmupScheduler.defaultInterval,
        warm: @escaping @Sendable () async throws -> Bool
    ) {
        intervalNanoseconds = max(1, UInt64(interval * 1_000_000_000))
        self.warm = warm
    }

    func start() {
        lock.lock()
        task?.cancel()
        task = Task(priority: .utility) { [weak self] in
            await self?.run()
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    deinit {
        stop()
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            do {
                if try await warm() {
                    FileHandle.standardError.write(
                        Data("model keep-warm complete\n".utf8)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                FileHandle.standardError.write(
                    Data("model keep-warm failed: \(error)\n".utf8)
                )
            }
        }
    }
}
