import Darwin
import Foundation

/// The two memory values that are useful when profiling a Core ML/Metal app.
/// RSS includes shared and mapped pages, while physical footprint is closer to
/// the memory pressure attributed to this process by macOS.
struct ProcessMemorySnapshot: Equatable {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64

    var residentMB: Double {
        Double(residentBytes) / 1_048_576
    }

    var physicalFootprintMB: Double {
        Double(physicalFootprintBytes) / 1_048_576
    }

    var summary: String {
        String(
            format: "rss=%.1fMB footprint=%.1fMB",
            residentMB,
            physicalFootprintMB
        )
    }

    static func current() -> ProcessMemorySnapshot? {
        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let basicResult = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(basicCount)
            ) { infoPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    infoPointer,
                    &basicCount
                )
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(vmCount)
            ) { infoPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    infoPointer,
                    &vmCount
                )
            }
        }

        let footprint = vmResult == KERN_SUCCESS
            ? UInt64(vmInfo.phys_footprint)
            : UInt64(basicInfo.resident_size)
        return ProcessMemorySnapshot(
            residentBytes: UInt64(basicInfo.resident_size),
            physicalFootprintBytes: footprint
        )
    }
}

enum RuntimeDiagnostics {
    /// Memory sampling calls task_info every 100 ms and writes one log line per
    /// model operation. Keep it out of normal dictation; benchmarks opt in with
    /// `PARROT_PROFILE_MEMORY=1`.
    static var profileMemory: Bool {
        ProcessInfo.processInfo.environment["PARROT_PROFILE_MEMORY"] == "1"
    }
}

/// Samples process memory while a model operation is running. Core ML model
/// specialization can create short-lived peaks that a before/after snapshot
/// misses, so the tracker polls the process footprint during the operation.
final class MemoryPeakTracker {
    private let lock = NSLock()
    private let label: String
    private let enabled: Bool
    private var peak: ProcessMemorySnapshot?
    private var timer: DispatchSourceTimer?

    init(label: String, interval: TimeInterval = 0.10) {
        self.label = label
        self.enabled = RuntimeDiagnostics.profileMemory
        guard enabled else { return }
        peak = ProcessMemorySnapshot.current()

        let timer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
    }

    func finish() -> ProcessMemorySnapshot? {
        guard enabled else { return nil }
        timer?.cancel()
        timer = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func logFinish() {
        guard enabled else { return }
        guard let peak = finish() else {
            FileHandle.standardError.write(
                Data("memory \(label) unavailable\n".utf8)
            )
            return
        }
        FileHandle.standardError.write(
            Data("memory \(label) peak \(peak.summary)\n".utf8)
        )
    }

    private func sample() {
        guard let current = ProcessMemorySnapshot.current() else { return }
        lock.lock()
        defer { lock.unlock() }
        if let peak {
            if current.physicalFootprintBytes > peak.physicalFootprintBytes {
                self.peak = current
            }
        } else {
            peak = current
        }
    }
}

/// The menu-bar process has no UI surface for profiling, so lifecycle events
/// are intentionally written to stderr alongside the existing model logs.
enum RuntimeMemoryLog {
    static func write(_ event: String) {
        guard let snapshot = ProcessMemorySnapshot.current() else { return }
        FileHandle.standardError.write(
            Data("memory \(event) \(snapshot.summary)\n".utf8)
        )
    }
}

/// Releases loaded models when macOS reports memory pressure. This is a
/// safety net alongside periodic warming; it never touches model files in
/// Application Support.
final class RuntimeMemoryPressureMonitor {
    private let source: DispatchSourceMemoryPressure

    init(onPressure: @escaping () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            RuntimeMemoryLog.write("memory-pressure")
            onPressure()
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
