import Foundation
import PlayerCore

/// Bridges libmpv's reply-ID based asynchronous command API to Swift async
/// calls. A reply can race ahead of waiter registration, so completed results
/// are retained until the corresponding command consumes them.
internal final class MPVAsyncCommandBroker: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<Void, any Error>

    private let lock = NSLock()
    private var waiters: [UInt64: Waiter] = [:]
    private var completed: [UInt64: Result<Void, PlaybackError>] = [:]
    private var cancelled: Set<UInt64> = []
    private var terminalError: PlaybackError?

    func waitForReply(_ replyID: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Void, PlaybackError>? = lock.withLock {
                    if let terminalError {
                        return .failure(terminalError)
                    }
                    if cancelled.remove(replyID) != nil {
                        return .failure(
                            PlaybackError(
                                code: .cancelled,
                                message: "The playback command was cancelled."
                            )
                        )
                    }
                    if let result = completed.removeValue(forKey: replyID) {
                        return result
                    }
                    waiters[replyID] = continuation
                    return nil
                }

                if let immediateResult {
                    continuation.resume(with: immediateResult.mapError { $0 as any Error })
                }
            }
        } onCancel: {
            cancel(replyID)
        }
    }

    func resolve(replyID: UInt64, result: Result<Void, PlaybackError>) {
        let waiter: Waiter? = lock.withLock {
            guard terminalError == nil else {
                return nil
            }
            guard cancelled.remove(replyID) == nil else {
                return nil
            }
            if let waiter = waiters.removeValue(forKey: replyID) {
                return waiter
            }
            completed[replyID] = result
            return nil
        }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    func failAll(with error: PlaybackError) {
        let pending: [Waiter] = lock.withLock {
            terminalError = error
            completed.removeAll()
            cancelled.removeAll()
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }

    private func cancel(_ replyID: UInt64) {
        let waiter: Waiter? = lock.withLock {
            completed.removeValue(forKey: replyID)
            if let waiter = waiters.removeValue(forKey: replyID) {
                return waiter
            }
            cancelled.insert(replyID)
            return nil
        }
        waiter?.resume(throwing: CancellationError())
    }
}
