import Synchronization

/// Something that happened during an evaluation, in the order the log received it.
public enum Event: Equatable, Sendable {
    /// The worker started a guest invocation with this step count.
    case started(count: Int32)
    /// The guest called `measure(input)` and the worker paused the invocation.
    case paused(input: Int32)
    /// The main actor performed the measurement.
    case measured(input: Int32, reading: Int32)
    /// The worker passed the reading to WasmKit to continue the paused invocation.
    case delivering(reading: Int32)
    /// The guest reported a finished step through its synchronous import.
    case noted(step: Int32)
    /// The worker answered another message while an invocation was paused.
    case answeredWhilePaused(completedSteps: Int32)
    /// The invocation returned.
    case finished(result: Int32)
    /// The paused invocation was cancelled and released.
    case cancelled(input: Int32)
    /// A reading arrived for an invocation that no longer waits for it.
    case refusedLateReading(reading: Int32)
}

/// A record of events that the worker, the main actor and the guest's host calls append to.
public final class EventLog: Sendable {
    private struct State {
        var events: [Event] = []
        var watchers: [(event: Event, checkpoint: Checkpoint)] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Appends `event` after every event recorded before this call returned.
    ///
    /// Checkpoints that wait for this event open after it is appended.
    public func record(_ event: Event) {
        let reached = state.withLock { state in
            state.events.append(event)
            let reached = state.watchers.filter { $0.event == event }.map(\.checkpoint)
            state.watchers.removeAll { $0.event == event }
            return reached
        }
        for checkpoint in reached {
            checkpoint.open()
        }
    }

    /// Returns a checkpoint that opens once `event` has been recorded.
    ///
    /// The checkpoint is already open when the log contains `event`.
    ///
    /// - Parameter event: The event to wait for.
    /// - Returns: The checkpoint, whose ``Checkpoint/wait()`` a caller can bound with
    ///   ``withDeadline(_:_:)``.
    public func checkpoint(for event: Event) -> Checkpoint {
        let checkpoint = Checkpoint()
        let alreadyRecorded = state.withLock { state in
            if state.events.contains(event) { return true }
            state.watchers.append((event, checkpoint))
            return false
        }
        if alreadyRecorded {
            checkpoint.open()
        }
        return checkpoint
    }

    /// The events recorded so far.
    public var snapshot: [Event] {
        state.withLock { $0.events }
    }
}
