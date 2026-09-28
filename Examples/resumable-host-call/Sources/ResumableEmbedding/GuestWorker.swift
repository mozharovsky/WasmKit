import WasmKit
import WasmKitWASI

/// An actor that owns a guest instance and runs its invocations.
///
/// The store and the instance never leave the worker. When the guest calls its `measure`
/// import, the host function pauses the invocation, and the worker awaits a measurement that
/// runs on the main actor. The worker is free during that wait, so it answers other messages.
/// It then continues the same invocation with the reading.
///
/// The worker keeps at most one paused invocation. A guest compiled from Swift keeps a shadow
/// stack in its linear memory, and two paused invocations that continue in the wrong order
/// would corrupt it. A synchronous call that finishes during the pause, such as
/// ``completedSteps()``, leaves the shadow stack as it found it.
public actor GuestWorker {
    /// The reason an evaluation returned no result.
    public enum Failure: Error, Equatable, Sendable {
        /// Another invocation is already paused on this worker.
        case busy
        /// The invocation was cancelled while it waited for a reading.
        case cancelled
        /// WasmKit refused the reading, for example because it answers an earlier pause.
        case refused(ResumeRejection)
        /// The guest paused somewhere other than `measure`.
        case unexpectedPause(tag: UInt64)
        /// The guest does not export the function.
        case missingExport(String)
    }

    /// Where an evaluation stands after the guest returned control to the worker.
    private enum Progress {
        case waiting(SuspensionID, input: Int32)
        case finished(Int32)
    }

    /// The tag with which the `measure` import pauses.
    private static let measureTag: UInt64 = 1

    private let store: Store
    private let instance: Instance
    private let wasi: WASIBridgeToHost
    private let measure: @MainActor @Sendable (Int32) async -> Int32
    private var paused: SuspendedCall?

    /// The events of this worker's evaluations.
    public nonisolated let log: EventLog

    /// Instantiates a guest that imports `native.measure` and `native.note` and exports
    /// `evaluate` and `completed_steps`.
    ///
    /// - Parameters:
    ///   - wasm: The binary module. A WASI reactor is initialized before its first use.
    ///   - threadingModel: The dispatch model, or `nil` for the platform's default.
    ///   - log: The log that receives the worker's and the guest's events.
    ///   - measure: The main-actor operation that answers the guest's `measure(input)`.
    /// - Throws: The error from parsing, instantiating or initializing the module.
    public init(
        wasm: [UInt8],
        threadingModel: EngineConfiguration.ThreadingModel? = nil,
        log: EventLog = EventLog(),
        measure: @escaping @MainActor @Sendable (Int32) async -> Int32
    ) throws {
        let module = try parseWasm(bytes: wasm)
        let store = Store(engine: Engine(configuration: EngineConfiguration(threadingModel: threadingModel)))
        let wasi = try WASIBridgeToHost()
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        imports.define(
            module: "native", name: "measure",
            Function(store: store, parameters: [.i32], results: [.i32]) { _, _ in
                // The reading needs the main actor, so the invocation pauses instead of blocking.
                throw HostCallSuspension(tag: GuestWorker.measureTag)
            })
        imports.define(
            module: "native", name: "note",
            Function(store: store, parameters: [.i32]) { _, arguments in
                log.record(.noted(step: Int32(bitPattern: arguments[0].i32)))
                return []
            })
        let instance = try module.instantiate(store: store, imports: imports)
        try wasi.initialize(instance)
        self.store = store
        self.instance = instance
        self.wasi = wasi
        self.measure = measure
        self.log = log
    }

    deinit {
        try? wasi.close()
    }

    /// Runs the guest's `evaluate(count)` and returns its result.
    ///
    /// Each `measure` call in the guest pauses the invocation until the main actor returns a
    /// reading. Other messages to the worker run during that wait.
    ///
    /// Cancelling the calling task while the invocation is paused releases that pause, and the
    /// guest does not continue, even when the reading arrives before the worker has handled the
    /// cancellation. Cancellation is cooperative. The worker observes it only while the guest is
    /// paused, a measurement that already started runs to its end, and its effects remain.
    ///
    /// - Parameter count: The number of steps, and so of pauses, in the guest.
    /// - Returns: The guest's result.
    /// - Throws: ``Failure/busy`` when another invocation is paused, ``Failure/cancelled`` when
    ///   the calling task was cancelled or the invocation was released during its wait,
    ///   ``Failure/refused(_:)`` when WasmKit refused its reading, and the guest's trap if it
    ///   traps.
    public func evaluate(_ count: Int32) async throws -> Int32 {
        guard paused == nil else { throw Failure.busy }
        log.record(.started(count: count))
        let entry = try export("evaluate")
        var progress = try hold(try entry.invokeResumable([.i32(UInt32(bitPattern: count))]))
        while case .waiting(let id, let input) = progress {
            log.record(.paused(input: input))
            let reading = await withTaskCancellationHandler {
                await measure(input)
            } onCancel: {
                Task { await self.cancel(id) }
            }
            // The handler's task can reach the worker after a fast measurement has returned, so
            // the worker checks the cancellation itself before the guest would continue. It
            // releases only this evaluation's pause, which leaves a successor's pause alone.
            if Task.isCancelled {
                cancel(id)
                log.record(.refusedLateReading(reading: reading))
                throw Failure.cancelled
            }
            progress = try deliver(reading, to: id)
        }
        guard case .finished(let result) = progress else { preconditionFailure("The loop ends only when finished.") }
        return result
    }

    /// Returns the guest's count of finished steps from its synchronous `completed_steps` export.
    ///
    /// The call runs to completion on its own execution stack, even while an invocation is
    /// paused.
    ///
    /// - Returns: The number of steps that every invocation on this instance has finished.
    /// - Throws: The guest's trap.
    public func completedSteps() throws -> Int32 {
        let steps = Int32(bitPattern: try export("completed_steps")()[0].i32)
        if paused != nil {
            log.record(.answeredWhilePaused(completedSteps: steps))
        }
        return steps
    }

    /// Releases the paused invocation, whose reading is then refused when it arrives.
    ///
    /// The main-actor measurement that already started is not interrupted, and its effects
    /// remain.
    ///
    /// - Returns: Whether an invocation was paused.
    @discardableResult
    public func cancelPausedInvocation() -> Bool {
        guard let call = paused.take() else { return false }
        log.record(.cancelled(input: Int32(bitPattern: call.arguments[0].i32)))
        call.cancel()
        return true
    }

    /// Releases the paused invocation only if it is still the pause `id`.
    private func cancel(_ id: SuspensionID) {
        guard paused?.id == id else { return }
        cancelPausedInvocation()
    }

    /// Keeps a paused invocation, or returns the result of a finished one.
    private func hold(_ call: consuming ResumableCall) throws -> Progress {
        switch consume call {
        case .finished(let results):
            let result = Int32(bitPattern: results[0].i32)
            log.record(.finished(result: result))
            return .finished(result)
        case .suspended(let call):
            guard call.tag == Self.measureTag else {
                let tag = call.tag
                call.cancel()
                throw Failure.unexpectedPause(tag: tag)
            }
            let progress = Progress.waiting(call.id, input: Int32(bitPattern: call.arguments[0].i32))
            paused = consume call
            return progress
        }
    }

    /// Continues the paused invocation with `reading` if it still waits for the pause `id`.
    private func deliver(_ reading: Int32, to id: SuspensionID) throws -> Progress {
        guard let call = paused.take() else {
            log.record(.refusedLateReading(reading: reading))
            throw Failure.cancelled
        }
        log.record(.delivering(reading: reading))
        switch try call.resume(returning: [.i32(UInt32(bitPattern: reading))], completing: id, in: store) {
        case .finished(let results):
            return try hold(.finished(results))
        case .suspended(let next):
            return try hold(.suspended(next))
        case .rejected(let call, let reason):
            // The reading answers an earlier pause, so the current one keeps waiting for its own.
            paused = consume call
            log.record(.refusedLateReading(reading: reading))
            throw Failure.refused(reason)
        }
    }

    private func export(_ name: String) throws -> Function {
        guard let function = instance.exports[function: name] else {
            throw Failure.missingExport(name)
        }
        return function
    }
}
