import Foundation

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func check() throws {
        try withPermission {}
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func withPermission(_ operation: () throws -> Void) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try operation()
        }
    }
}

