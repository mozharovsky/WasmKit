import Synchronization

/// A one-shot signal that tasks wait for, used as a barrier in the demo and its tests.
public final class Checkpoint: Sendable {
    private struct State: ~Copyable {
        var isOpen = false
        var lastWaiter = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Lets every current and later waiter continue.
    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Waits until the checkpoint opens.
    ///
    /// - Throws: `CancellationError` when the waiting task is cancelled before the checkpoint
    ///   opens.
    public func wait() async throws {
        let id = state.withLock { state in
            state.lastWaiter += 1
            return state.lastWaiter
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// The error of an operation that did not finish before its deadline.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    /// The time the operation was allowed.
    public let limit: Duration

    public var description: String { "The operation did not finish within \(limit)." }
}

/// Runs `operation` and cancels it if it has not finished after `limit`.
///
/// The operation must respond to cancellation, because this function returns only after the
/// operation does.
///
/// - Parameters:
///   - limit: The time the operation may take.
///   - operation: The work to run in a child task.
/// - Returns: The operation's result.
/// - Throws: ``DeadlineExceeded`` after the limit, or the operation's error.
public func withDeadline<Result: Sendable>(
    _ limit: Duration = .seconds(10),
    _ operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let result = first else {
            throw DeadlineExceeded(limit: limit)
        }
        return result
    }
}
