import Foundation

enum RuntimeClock {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func seconds(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000_000
    }
}
