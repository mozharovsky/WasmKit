import WasmTypes

/// Why a ``ResumableCall`` stopped before its function returned.
public struct Suspension: Sendable {
    /// What suspended the call.
    public enum Reason: Sendable, Equatable {
        /// The guest could not pay for the code it was about to run from ``Store/fuel``.
        ///
        /// The charge is all-or-nothing: `required` was not deducted. Give the store at least
        /// `required` fuel and resume, and the call retries the charge; with less, it suspends
        /// again at once.
        ///
        /// A bulk memory or table operation suspends before it does anything, and resuming runs
        /// it again from the start. If it is out of bounds, it traps then.
        case outOfFuel(required: UInt64)
        /// The engine's epoch reached the deadline set by
        /// ``Store/setEpochDeadline(ticksBeyondCurrent:)``.
        ///
        /// Set a new deadline and resume, and the call checks the epoch again where it stopped.
        case epochDeadlineReached
        /// The guest called a host function, and the host function threw a ``SuspensionRequest``.
        ///
        /// `id` is the value the host function put in the request, and `arguments` are the
        /// arguments of the host call. To continue, call ``ResumableCall/resume(returning:)`` with
        /// the host function's results or ``ResumableCall/resume(failing:)`` with an error. The
        /// host function does not run again.
        case hostCall(id: UInt64, arguments: [Value])
    }

    /// What suspended the call.
    public let reason: Reason
}

/// An error that a host function throws to suspend the running ``ResumableCall``.
///
/// When the guest of a ``ResumableCall`` calls a host function and the host function throws this
/// error, the call suspends with ``Suspension/Reason/hostCall(id:arguments:)``.
///
/// - Note: Throwing this error anywhere else traps. For example, it traps in these cases:
///   - The guest was called through ``Function/invoke(_:)``, even from a host function of a
///     running ``ResumableCall``.
///   - The host function was called through ``Function/invoke(_:)``.
///   - A ``ResumableCall`` was created directly with the host function.
public struct SuspensionRequest: Error, Sendable, Equatable {
    /// A value the host function chooses, passed on in the suspension reason.
    public var id: UInt64

    /// Creates a suspension request with the given identifier.
    public init(id: UInt64 = 0) {
        self.id = id
    }
}

/// An error raised by misusing a ``ResumableCall``. The call is left as it was.
///
/// - Note: A host function can also throw this error, for example after misusing another call.
///   The misused call stays as it was, but the error finishes the call that ran the host
///   function. Check ``ResumableCall/isFinished`` to tell the cases apart.
public struct ResumableCallError: Error, CustomStringConvertible, Sendable {
    /// The description of the error.
    public let description: String

    static var alreadyRunning: ResumableCallError {
        ResumableCallError(description: "the call is already running")
    }
    static var finished: ResumableCallError {
        ResumableCallError(description: "the call has already finished")
    }
    static var exceptionNotThrowable: ResumableCallError {
        ResumableCallError(description: "a call cannot be cancelled with a WebAssembly exception")
    }
    static var requestNotThrowable: ResumableCallError {
        ResumableCallError(description: "a suspension request cannot be thrown into a call")
    }
    static var suspendedAtHostCall: ResumableCallError {
        ResumableCallError(description: "a call suspended at a host call continues only with resume(returning:) or resume(failing:)")
    }
    static var notSuspendedAtHostCall: ResumableCallError {
        ResumableCallError(description: "the call is not suspended at a host call")
    }
    static func resultTypesMismatch(expected: [ValueType], got: [Value]) -> ResumableCallError {
        ResumableCallError(
            description:
                "result types don't match, expected [\(ValueType.descriptionList(expected))], got [\(Value.descriptionList(got))]"
        )
    }
}

/// How the guest stopped: where to continue from.
///
/// Thrown by the code that suspends, and caught by ``ResumableCall``. The frames between `sp` and
/// the root frame stay on the call's stack while it is suspended.
///
/// It is `@unchecked Sendable` only because `Error` requires `Sendable`. A signal never leaves
/// the thread that runs its call.
struct SuspensionSignal: Error, @unchecked Sendable {
    let reason: Suspension.Reason
    /// The frame to continue in.
    let sp: Sp
    /// The head slot to continue from.
    let resumePC: Pc
    /// The suspended host call, or `nil` for fuel and epoch suspensions.
    let hostCall: SuspendedHostCall?

    init(reason: Suspension.Reason, sp: Sp, resumePC: Pc, hostCall: SuspendedHostCall? = nil) {
        self.reason = reason
        self.sp = sp
        self.resumePC = resumePC
        self.hostCall = hostCall
    }

    var suspension: Suspension {
        Suspension(reason: reason)
    }

    /// The instruction to report in the backtrace of a trap thrown into the suspended call.
    ///
    /// A host function's trap is reported just past the call, which is `resumePC`. A trap at a
    /// fuel or epoch check is reported one slot past `resumePC`.
    var trapSite: Pc {
        hostCall == nil ? resumePC + 1 : resumePC
    }
}

/// The host call that a ``ResumableCall`` is suspended at.
///
/// `parameterArea` points into the stack of the suspended call. It stays valid while the call
/// holds that stack.
struct SuspendedHostCall {
    /// The host function, which gives the result types and their layout.
    let function: EntityHandle<HostFunctionEntity>
    /// Where the guest reads the host function's results.
    let parameterArea: Sp
}

/// A call to a function that can be suspended and resumed.
///
/// A resumable call runs its guest on a stack of its own, which stays alive while the call is
/// suspended. With ``EngineConfiguration/fuelMetering``, running out of ``Store/fuel`` suspends
/// the guest instead of trapping, and so does reaching the epoch deadline with
/// ``EngineConfiguration/epochInterruption``. A host function can also suspend the call by
/// throwing a ``SuspensionRequest``.
///
/// ```swift
/// let call = try ResumableCall(function: run, arguments: [])
/// var status = try call.resume()
/// while case .suspended(let suspension) = status {
///     switch suspension.reason {
///     case .outOfFuel(let required):
///         store.fuel = Fuel(remaining: max(required, 10_000))
///         status = try call.resume()
///     case .epochDeadlineReached:
///         store.setEpochDeadline(ticksBeyondCurrent: 1)
///         status = try call.resume()
///     case .hostCall(let id, let arguments):
///         let results = try await computeResults(id, arguments)
///         status = try call.resume(returning: results)
///     }
/// }
/// ```
///
/// Any number of resumable calls can be suspended on one store at a time, and resumed in any
/// order. A host function can run another resumable call too.
///
/// A plain call made while a resumable call runs, such as a host function calling back into the
/// guest with ``Function/invoke(_:)``, cannot be suspended: running out of fuel or throwing a
/// ``SuspensionRequest`` there traps.
public final class ResumableCall {
    /// What a run of the call ended with, when it did not throw.
    public enum Status {
        /// The function returned these results. The call is finished.
        case returned([Value])
        /// The guest is suspended. Resume the call to continue it.
        case suspended(Suspension)
    }

    /// Where the call is, and who owns its stack: the state while the call is not running, and
    /// the run itself while it is.
    private enum State: ~Copyable {
        /// Not started; holds the arguments.
        case ready([Value], ExecutionStack)
        case running
        case suspended(SuspensionSignal, ExecutionStack)
        /// Holds the stack until ``takeStack()`` takes it.
        case finished(ExecutionStack?)

        /// Returns this state, leaving `.running` in its place.
        mutating func take() -> State {
            let current = self
            self = .running
            return current
        }

        /// Takes the stack of a finished call.
        mutating func takeStack() -> ExecutionStack? {
            switch consume self {
            case .finished(let stack):
                self = .finished(nil)
                return stack
            case let other:
                self = other
                return nil
            }
        }

        /// Finishes a call that is not running, returning where it was suspended, if it was.
        mutating func finish() throws(ResumableCallError) -> SuspensionSignal? {
            switch consume self {
            case .ready(_, let stack):
                self = .finished(stack)
                return nil
            case .suspended(let signal, let stack):
                self = .finished(stack)
                return signal
            case .running:
                self = .running
                throw .alreadyRunning
            case .finished(let stack):
                self = .finished(stack)
                throw .finished
            }
        }
    }

    /// The function this call runs.
    public let function: Function
    private let type: FunctionType
    private var execution: Execution
    /// The code the called function returns to.
    private let rootCode: Execution.RootCode
    private var state: State

    /// Prepares a call of `function` with `arguments`, on a stack of its own, without running it.
    ///
    /// - Throws: A trap if `arguments` do not match the parameters of `function`.
    public convenience init(function: Function, arguments: [Value] = []) throws {
        try self.init(function: function, arguments: arguments, on: ExecutionStack(engine: function.store.engine))
    }

    /// Prepares a call of `function` with `arguments` on `stack`, without running it.
    ///
    /// The call keeps the stack while it runs and while it is suspended. Take it back with
    /// ``takeStack()`` once the call has finished, to use it again.
    ///
    /// - Throws: A trap if `arguments` do not match the parameters of `function`.
    public init(function: Function, arguments: [Value] = [], on stack: consuming ExecutionStack) throws {
        let type = function.type
        guard arguments.count == type.parameters.count,
            zip(arguments, type.parameters).allSatisfy({ $0.matches($1) })
        else {
            throw Trap(.parameterTypesMismatch(expected: type.parameters, got: arguments))
        }
        let store = function.store
        self.function = function
        self.type = type
        // `StoreRef` does not retain the store, so it must not outlive it. It cannot: the
        // execution lives as long as this call, which retains `function`, which retains its store.
        self.execution = Execution(store: StoreRef(store), stackEnd: stack.slots.advanced(by: stack.count))
        self.rootCode = Execution.RootCode(threadingModel: store.engine.configuration.threadingModel)
        self.state = .ready(arguments, stack)
    }

    /// Whether the function has returned, or the call failed.
    public var isFinished: Bool {
        switch state {
        case .finished: return true
        default: return false
        }
    }

    /// Why the call is suspended, or `nil` when it is not.
    public var suspension: Suspension? {
        switch state {
        case .suspended(let signal, _): return signal.suspension
        default: return nil
        }
    }

    /// Takes the call's stack back, to use it again. `nil` until the call has finished, and once
    /// the stack has been taken.
    public func takeStack() -> ExecutionStack? {
        state.takeStack()
    }

    /// Starts the call, or continues it after a suspension.
    ///
    /// - Returns: Whether the function returned or the guest was suspended again.
    /// - Throws: A trap, or another error the guest raised, which finishes the call; or a
    ///   ``ResumableCallError`` if the call cannot be resumed, which leaves it as it was.
    /// - Note: A call suspended at a host call continues only with ``resume(returning:)`` or
    ///   ``resume(failing:)``, even when the host function has no results.
    public func resume() throws -> Status {
        switch state.take() {
        case .ready(let arguments, let stack):
            return try start(arguments: arguments, on: stack)
        case .suspended(let signal, let stack):
            guard signal.hostCall == nil else {
                state = .suspended(signal, stack)
                throw ResumableCallError.suspendedAtHostCall
            }
            return try run(on: stack) { execution, _ in
                try execution.resume(sp: signal.sp, pc: signal.resumePC)
            }
        case .running:
            throw ResumableCallError.alreadyRunning
        case .finished(let stack):
            state = .finished(stack)
            throw ResumableCallError.finished
        }
    }

    /// Continues a call suspended at a host call, as if the host function had returned `results`.
    ///
    /// - Parameter results: The host function's results, or an empty array if it has none.
    /// - Returns: Whether the function returned or the guest was suspended again.
    /// - Throws: A trap, or another error the guest raised, which finishes the call. A
    ///   ``ResumableCallError`` leaves the call as it was. It is thrown when the call has not
    ///   started, is running, has finished, or is suspended for another reason. It is also thrown
    ///   when `results` do not match the result types of the host function.
    /// - Important: WasmKit checks only the type of each result. A function reference must belong
    ///   to the store of this call, and an exception reference must come from this call.
    public func resume(returning results: [Value]) throws -> Status {
        try completeHostCall { hostCall in
            let resultTypes = hostCall.function.resultTypes
            guard results.count == resultTypes.count,
                zip(results, resultTypes).allSatisfy({ $0.matches($1) })
            else {
                throw ResumableCallError.resultTypesMismatch(expected: resultTypes, got: results)
            }
        } continuing: { execution, signal, hostCall in
            let function = hostCall.function
            for (index, result) in results.enumerated() {
                hostCall.parameterArea.storeValue(
                    result, at: function.layout.resultReg(index), type: function.resultTypes[index])
            }
            try execution.resume(sp: signal.sp, pc: signal.resumePC)
        }
    }

    /// Continues a call suspended at a host call, as if the host function had thrown `error`.
    ///
    /// The guest can catch a ``WasmKitException``. Any other error finishes the call, and a
    /// ``Trap`` gets the backtrace of the suspended guest. To end the call without running the
    /// guest, use ``resume(throwing:)``.
    ///
    /// - Parameter error: The error to throw from the host call. It cannot be a
    ///   ``SuspensionRequest``.
    /// - Returns: Whether the function returned or the guest was suspended again.
    /// - Throws: `error` or another error the guest raised, which finishes the call. A
    ///   ``ResumableCallError`` leaves the call as it was. It is thrown when the call has not
    ///   started, is running, has finished, or is suspended for another reason. It is also thrown
    ///   when `error` is a ``SuspensionRequest``.
    public func resume(failing error: any Error) throws -> Status {
        let store = function.store
        return try completeHostCall { _ in
            if error is SuspensionRequest {
                throw ResumableCallError.requestNotThrowable
            }
        } continuing: { execution, signal, _ in
            if let exception = error as? WasmKitException {
                var sp = signal.sp
                var pc = signal.resumePC
                var md: Md = nil
                var ms: Ms = 0
                guard execution.handleException(exception, sp: &sp, pc: &pc, md: &md, ms: &ms) else {
                    throw exception
                }
                try execution.resume(sp: sp, pc: pc)
            } else if let trap = error as? Trap {
                throw trap.withBacktrace(Execution.captureBacktrace(sp: signal.sp, pc: signal.trapSite, store: store))
            } else {
                throw error
            }
        }
    }

    /// Finishes a call without running any more of it, throwing `error` from where it is.
    ///
    /// This is how to cancel a call. A ``Trap`` gets the backtrace of the suspended guest. The
    /// guest cannot catch `error`, so it may not be a ``WasmKitException``.
    ///
    /// - Throws: `error`, which finishes the call. A ``ResumableCallError`` leaves the call as it
    ///   was. It is thrown when the call is running or finished, or when `error` is a
    ///   ``WasmKitException`` or a ``SuspensionRequest``.
    public func resume(throwing error: any Error) throws -> Never {
        if error is WasmKitException {
            throw ResumableCallError.exceptionNotThrowable
        }
        if error is SuspensionRequest {
            throw ResumableCallError.requestNotThrowable
        }
        if let signal = try state.finish(), let trap = error as? Trap {
            throw trap.withBacktrace(
                Execution.captureBacktrace(sp: signal.sp, pc: signal.trapSite, store: function.store))
        }
        throw error
    }

    /// Continues a call suspended at a host call once `check` accepts the results or the error.
    ///
    /// If the call is not suspended at a host call or `check` throws, the call is left as it was
    /// and nothing runs.
    ///
    /// - Parameters:
    ///   - check: Throws a ``ResumableCallError`` to reject the results or the error.
    ///   - body: Writes the results or throws the error, and continues the guest.
    private func completeHostCall(
        check: (SuspendedHostCall) throws -> Void,
        continuing body: (inout Execution, SuspensionSignal, SuspendedHostCall) throws -> Void
    ) throws -> Status {
        switch state.take() {
        case .suspended(let signal, let stack):
            let hostCall: SuspendedHostCall
            do {
                guard let suspended = signal.hostCall else {
                    throw ResumableCallError.notSuspendedAtHostCall
                }
                try check(suspended)
                hostCall = suspended
            } catch {
                state = .suspended(signal, stack)
                throw error
            }
            return try run(on: stack) { execution, _ in
                try body(&execution, signal, hostCall)
            }
        case .ready(let arguments, let stack):
            state = .ready(arguments, stack)
            throw ResumableCallError.notSuspendedAtHostCall
        case .running:
            throw ResumableCallError.alreadyRunning
        case .finished(let stack):
            state = .finished(stack)
            throw ResumableCallError.finished
        }
    }

    private func start(arguments: [Value], on stack: consuming ExecutionStack) throws -> Status {
        let handle = function.handle
        guard handle.isWasm else {
            // A host function has no guest frames to suspend.
            let results: [Value]
            do {
                results = try handle.invokeHost(arguments, store: function.store)
            } catch {
                state = .finished(stack)
                throw error
            }
            state = .finished(stack)
            return .returned(results)
        }
        let type = self.type
        let rootPC = self.rootCode.pc
        return try run(on: stack) { execution, base in
            let sp = try Execution.layOutRootFrame(at: base, type: type, arguments: arguments)
            try execution.execute(sp: sp, pc: rootPC, handle: handle, type: type)
        }
    }

    /// Runs `body` as this call on `stack`, whose start it is given, marking the store as running
    /// a suspendable execution, and records how it stopped.
    private func run(on stack: consuming ExecutionStack, _ body: (inout Execution, Sp) throws -> Void) throws -> Status {
        let store = function.store
        let wasSuspendable = store.isSuspendable
        store.isSuspendable = true
        defer { store.isSuspendable = wasSuspendable }
        let base = stack.slots
        do {
            try body(&execution, base)
        } catch let signal as SuspensionSignal {
            state = .suspended(signal, stack)
            return .suspended(signal.suspension)
        } catch {
            state = .finished(stack)
            throw error
        }
        let results = Execution.readRootResults(sp: base.advanced(by: StackLayout.numberOfSavingSlots), type: type)
        state = .finished(stack)
        return .returned(results)
    }
}
