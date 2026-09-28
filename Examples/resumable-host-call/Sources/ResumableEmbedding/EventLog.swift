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
    private let events = Mutex<[Event]>([])

    public init() {}

    /// Appends `event` after every event recorded before this call returned.
    public func record(_ event: Event) {
        events.withLock { $0.append(event) }
    }

    /// The events recorded so far.
    public var snapshot: [Event] {
        events.withLock { $0 }
    }
}
