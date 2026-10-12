import Synchronization

/// An independently writable stop signal permanently bound to one interpreter store.
///
/// Only the controller crosses threads. Its store and exports retain their ordinary serial
/// execution requirements. The first requested termination wins and every later invocation fails.
/// Parsing, translation, native imports, and blocking atomic waits require their own host policies.
/// Interruption is observed when those operations return to an interpreter checkpoint.
public final class ExecutionControl: Sendable {
    /// The positive maximum amount of guest work between external-signal polls, in the units of the
    /// store's threading model.
    ///
    /// A token-threaded store counts dispatches and polls between groups of at most this many. A
    /// translated superinstruction can perform several WebAssembly operations in one dispatch.
    ///
    /// A direct-threaded store counts WebAssembly operators. Every reachable operator of a function
    /// body counts once, including `nop`, `block`, `end` and the other operators that fuel metering
    /// leaves free. Translation places checkpoints at function entries, loop headers, `if` arms,
    /// after calls, at the end labels of blocks that contain a checkpoint, and every interval of
    /// operators within straight-line code. Each one charges its segment in advance, so from one
    /// poll to the next the guest runs at most `pollingInterval` operators. The same value therefore
    /// allows different amounts of work under the two models.
    ///
    /// Neither count is a wall-clock bound. Export entry, completion, native import return, and
    /// caught guest exceptions also check the external signal. Native work inside one operator, such
    /// as a host import, a bulk memory operation, or an atomic wait, is not counted and is not
    /// interrupted.
    public let pollingInterval: UInt32
    /// Whether this controller records checkpoints for cross-thread progress diagnostics.
    private let recordsCheckpoints: Bool
    /// The first stop reason, with zero reserved for a live store.
    private let stop = Atomic<UInt8>(0)
    /// Whether a store already claimed this controller, including a store that has been released.
    private let claimed = Atomic(false)
    /// Optional checkpoint counts without instruction-by-instruction instrumentation.
    private let checkpoints = Atomic<UInt>(0)

    /// Creates a controller without allocating a timer or starting an execution.
    ///
    /// - Parameters:
    ///   - pollingInterval: A value from one through UInt32.max, in the units
    ///     ``pollingInterval`` describes. The default is 1,024.
    ///   - recordsCheckpoints: Enables test progress recording. Ordinary execution leaves it false.
    /// - Throws: An invalid-polling-interval error when the interval is zero.
    public init(
        pollingInterval: UInt32 = 1024,
        recordsCheckpoints: Bool = false
    ) throws(ExecutionControlError) {
        guard pollingInterval > 0 else { throw .invalidPollingInterval }
        self.pollingInterval = pollingInterval
        self.recordsCheckpoints = recordsCheckpoints
    }

    /// Requests permanent termination without entering or waiting for the store's executor.
    ///
    /// - Parameter reason: The host's reason for discarding this store. The first request wins.
    public func requestInterruption(reason: ExecutionTermination = .interrupted) {
        let value: UInt8 = reason == .interrupted ? 1 : 2
        _ = stop.compareExchange(expected: 0, desired: value, ordering: .relaxed)
    }

    /// The first requested reason, or nil while no interruption has been requested.
    public var termination: ExecutionTermination? {
        switch stop.load(ordering: .relaxed) {
        case 1: .interrupted
        case 2: .deadlineExceeded
        default: nil
        }
    }

    /// The diagnostic checkpoint count, which stays zero when recording is disabled.
    ///
    /// This includes entry and native-return checks and wraps after UInt.max on the host. It is not a count
    /// of guest instructions and is not used to decide whether execution should terminate.
    public var observedCheckpointCount: UInt64 { UInt64(checkpoints.load(ordering: .relaxed)) }

    /// Claims unique store ownership before any function can begin using this controller.
    ///
    /// - Throws: A reused-control error when a store has already claimed this controller.
    func claim() throws(ExecutionControlError) {
        guard claimed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        else { throw .reusedControl }
    }

    /// Rejects execution after an independent host request and optionally publishes test progress.
    ///
    /// - Throws: The first requested terminal reason, retained for every future check.
    @inline(__always)
    func check() throws(ExecutionTermination) {
        let value = stop.load(ordering: .relaxed)
        if _slowPath(value != 0) {
            throw value == 1 ? .interrupted : .deadlineExceeded
        }
        if recordsCheckpoints {
            _ = checkpoints.wrappingAdd(1, ordering: .relaxed)
        }
    }
}

/// Terminal outcomes delivered at a checkpoint after the host requests permanent interruption.
public enum ExecutionTermination: Error, Equatable, Sendable, CustomStringConvertible {
    /// The owner explicitly stopped the current store.
    case interrupted
    /// A host-managed deadline expired while the owner was executing this store.
    case deadlineExceeded

    /// The stable diagnostic retained independently of the discarded guest heap.
    public var description: String {
        switch self {
        case .interrupted: "WebAssembly execution was interrupted."
        case .deadlineExceeded: "WebAssembly execution exceeded its host deadline."
        }
    }
}

/// Configuration failures reported before an execution controller can be used by a store.
public enum ExecutionControlError: Error, Equatable, Sendable {
    /// A zero interval would make the grouped dispatcher unable to reach its next checkpoint.
    case invalidPollingInterval
    /// A controller cannot be used by more than one store, including replacement stores.
    case reusedControl
    /// A direct-threaded store with a controller cannot run a debuggable instance or the debugger,
    /// whose code has no checkpoints.
    case unsupportedThreadingModel
}
