import Foundation

/// Serializes access to an inference backend without blocking an executor
/// thread. User work is preferred over maintenance work that is waiting for
/// the same model.
actor AsyncOperationGate {
    enum Priority {
        case user
        case maintenance
    }

    private var occupied = false
    private var userWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(priority: Priority) async {
        guard occupied else {
            occupied = true
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .user:
                userWaiters.append(continuation)
            case .maintenance:
                maintenanceWaiters.append(continuation)
            }
        }
    }

    func release() {
        if let continuation = userWaiters.first {
            userWaiters.removeFirst()
            continuation.resume()
            return
        }
        if let continuation = maintenanceWaiters.first {
            maintenanceWaiters.removeFirst()
            continuation.resume()
            return
        }
        occupied = false
    }
}
