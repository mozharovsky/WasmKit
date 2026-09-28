import struct WasmTypes.FunctionType

/// An error a host function throws to pause the resumable invocation that called it.
///
/// Throwing it from a host function that ``Function/invokeResumable(_:)`` reached pauses the
/// invocation at that call and returns ``ResumableCall/suspended(_:)`` to the embedder. The
/// guest keeps the synchronous signature of its import. It continues from the call with the
/// results the embedder passes to ``SuspendedCall/resume(returning:completing:in:)``.
///
/// Any other invocation, including a synchronous call that a host function makes into a guest,
/// cannot pause. There the request fails with ``ResumableCallError/suspensionUnavailable``.
public struct HostCallSuspension: Error, Sendable, Equatable {
    /// A value the embedder chooses to recognize the request, reported by ``SuspendedCall/tag``.
    public var tag: UInt64

    /// Creates a request to pause.
    ///
    /// - Parameter tag: A value the embedder chooses to recognize the request.
    public init(tag: UInt64 = 0) {
        self.tag = tag
    }
}

/// A failure to start or pause a resumable invocation.
public enum ResumableCallError: Error, Sendable, Equatable {
    /// A host function asked to pause an invocation that cannot pause.
    ///
    /// Only the invocation that ``Function/invokeResumable(_:)`` started can pause, and only at a
    /// host call that it makes itself. A pause inside a synchronous call nested in a host
    /// function would have to keep that host function's native frames, which the engine does
    /// not keep.
    case suspensionUnavailable
    /// ``Function/invokeResumable(_:)`` was called on a host function, which has no guest frames
    /// to keep.
    case notAGuestFunction
}

/// The identity of one pause of a resumable invocation.
///
/// Each pause receives a new identifier. The embedder sends it along with the work it starts
/// and passes it back when it resumes, so a result that arrives for an earlier pause is refused.
/// Identifiers stay unique within the process for as long as any copy of them exists.
public struct SuspensionID: Hashable, Sendable {
    /// The identity of the store that paused, kept alive by the identifier.
    let store: SuspensionStoreIdentity
    /// The pause's serial number within that store.
    let serial: UInt64

    public static func == (lhs: SuspensionID, rhs: SuspensionID) -> Bool {
        lhs.store === rhs.store && lhs.serial == rhs.serial
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(store))
        hasher.combine(serial)
    }
}

/// An object whose identity distinguishes the suspension identifiers of one store.
///
/// An identifier retains it, so its address cannot be reused by another store while an
/// identifier that names it exists.
final class SuspensionStoreIdentity: Sendable {}

/// The state of a resumable invocation after it returned control to the embedder.
public enum ResumableCall: ~Copyable {
    /// The invocation returned these results.
    case finished([Value])
    /// A host function paused the invocation.
    case suspended(SuspendedCall)
}

/// The state of a resumable invocation after the embedder tried to resume it.
public enum ResumeResult: ~Copyable {
    /// The invocation returned these results.
    case finished([Value])
    /// A host function paused the invocation again, with a new identifier.
    case suspended(SuspendedCall)
    /// The resume was refused before the guest ran. The same pause can be resumed again.
    case rejected(SuspendedCall, ResumeRejection)
}

/// The reason a resume was refused before the guest ran.
public enum ResumeRejection: Error, Sendable, Equatable {
    /// The completion names an earlier pause than the one this continuation holds.
    case staleSuspension
    /// The store passed to resume is not the store that paused.
    case foreignStore
    /// The number of results differs from the host function's result count.
    case resultCount(expected: Int, actual: Int)
    /// A result does not have the type the host function declares at that position.
    case resultType(index: Int, expected: ValueType)
}

/// The right to continue one paused invocation.
///
/// A host function paused the invocation at one of its calls. The continuation owns the
/// invocation's guest stack, the frames on it, the position after the call, and the guest's
/// exception handlers, and it keeps the store alive. No native frame of the paused call survives
/// the pause, and no borrowed ``Caller`` or temporary buffer is kept.
///
/// The continuation is noncopyable. Resuming or cancelling consumes it, so it can be completed
/// once. Dropping it releases the invocation like ``cancel()``. The guest does not run again for
/// a released invocation, and work that the embedder already did for it is not undone.
///
/// The continuation is not `Sendable`, like the ``Store`` it keeps. Keep it on the executor that
/// owns the store and send only ``id``, ``arguments``, and the results across executors.
public struct SuspendedCall: ~Copyable {
    /// The paused invocation.
    let state: ResumableExecutionState

    /// The identity of this pause, which a completion passes back to resume.
    public let id: SuspensionID
    /// The tag of the host function's ``HostCallSuspension``.
    public let tag: UInt64
    /// The host function that paused, whose results resume the invocation.
    public let hostFunction: Function
    /// A copy of the arguments the guest passed to the host function.
    public let arguments: [Value]

    /// The result types the host function declares, which resume checks.
    public var resultTypes: [ValueType] {
        state.pending?.function.resultTypes ?? []
    }

    /// Continues the guest with the host function's results.
    ///
    /// The results must belong to this pause, match the host function's result count and types,
    /// and the store must be the one that paused. A failed check returns
    /// ``ResumeResult/rejected(_:_:)`` before the guest runs, with the continuation intact.
    ///
    /// - Parameters:
    ///   - results: The host function's results.
    ///   - id: The identifier of the pause the results complete.
    ///   - store: The store that paused.
    /// - Returns: The finished results, the next pause, or the refusal.
    /// - Throws: A trap or an error that ends the invocation after it continued. The invocation
    ///   is released before the error is thrown.
    public consuming func resume(
        returning results: [Value], completing id: SuspensionID, in store: Store
    ) throws -> ResumeResult {
        if let rejection = rejection(completing: id, store: store) {
            return .rejected(self, rejection)
        }
        let resultTypes = self.resultTypes
        guard results.count == resultTypes.count else {
            return .rejected(self, .resultCount(expected: resultTypes.count, actual: results.count))
        }
        for (index, result) in results.enumerated() {
            do {
                try result.checkType(resultTypes[index])
            } catch {
                return .rejected(self, .resultType(index: index, expected: resultTypes[index]))
            }
        }
        let state = self.state
        return try state.continueAfterHostCall(.returning(results))
    }

    /// Continues the guest with the host function's results for this pause.
    ///
    /// This is ``resume(returning:completing:in:)`` with this continuation's own ``id``, for an
    /// embedder that completes the pause where it holds the continuation.
    ///
    /// - Parameters:
    ///   - results: The host function's results.
    ///   - store: The store that paused.
    /// - Returns: The finished results, the next pause, or the refusal.
    /// - Throws: A trap or an error that ends the invocation after it continued.
    public consuming func resume(returning results: [Value], in store: Store) throws -> ResumeResult {
        let id = self.id
        return try resume(returning: results, completing: id, in: store)
    }

    /// Continues the guest as if the host function had thrown `error` for this pause.
    ///
    /// This is ``resume(throwing:completing:in:)`` with this continuation's own ``id``.
    ///
    /// - Parameters:
    ///   - error: The host function's failure.
    ///   - store: The store that paused.
    /// - Returns: The finished results, the next pause, or the refusal.
    /// - Throws: The error when no guest handler catches it, or an error raised after the
    ///   guest continued.
    public consuming func resume(throwing error: any Error, in store: Store) throws -> ResumeResult {
        let id = self.id
        return try resume(throwing: error, completing: id, in: store)
    }

    /// Continues the guest as if the host function had thrown `error`.
    ///
    /// A ``WasmKitException`` reaches the guest's exception handlers. A ``Trap`` or any other
    /// error ends the invocation, as it does when a synchronous host function throws it.
    ///
    /// - Parameters:
    ///   - error: The host function's failure.
    ///   - id: The identifier of the pause the failure completes.
    ///   - store: The store that paused.
    /// - Returns: The finished results, the next pause, or the refusal.
    /// - Throws: The error when no guest handler catches it, or an error raised after the
    ///   guest continued. The invocation is released before the error is thrown.
    public consuming func resume(
        throwing error: any Error, completing id: SuspensionID, in store: Store
    ) throws -> ResumeResult {
        if let rejection = rejection(completing: id, store: store) {
            return .rejected(self, rejection)
        }
        let state = self.state
        return try state.continueAfterHostCall(.throwing(error))
    }

    /// Releases the paused invocation without running the guest again.
    ///
    /// The guest stack and the rest of the invocation's state are freed. A completion that
    /// arrives later has no continuation to resume.
    public consuming func cancel() {}

    /// Checks a completion against this pause and its store.
    ///
    /// - Parameters:
    ///   - id: The identifier the completion carries.
    ///   - store: The store passed to resume.
    /// - Returns: The reason to refuse, or nil when the completion belongs to this pause.
    private func rejection(completing id: SuspensionID, store: Store) -> ResumeRejection? {
        guard store === state.store else { return .foreignStore }
        guard id == self.id, state.pending?.id == id else { return .staleSuspension }
        return nil
    }
}

/// The error that unwinds the native frames of a paused host call and the dispatch loop.
///
/// It carries the position that ``ResumableExecutionState`` keeps. The pointers refer to the
/// invocation's guest stack and instruction sequences, which the state keeps alive.
struct SuspendedHostCall: Error, @unchecked Sendable {
    /// The host function's request.
    let request: HostCallSuspension
    /// The host function that paused.
    let function: EntityHandle<HostFunctionEntity>
    /// A copy of the arguments of the call.
    let arguments: [Value]
    /// The frame of the guest function that called the host function.
    let sp: Sp
    /// The position after the call instruction, where the guest continues.
    let pc: Pc
    /// The offset from `sp` of the call's argument and result registers.
    let spAddend: VReg
}

/// A paused host call with the identity the embedder completes.
struct PendingHostCall {
    /// The position and function of the call.
    let call: SuspendedHostCall
    /// The identity of the pause.
    let id: SuspensionID

    /// The host function that paused.
    var function: EntityHandle<HostFunctionEntity> { call.function }
}

/// The owned state of one resumable invocation.
///
/// It owns the guest stack for the whole invocation, and a heap copy of the end-of-execution
/// slot that the root frame returns to, because a pause outlives the native frame that holds that
/// slot in a synchronous invocation. It keeps the store alive, so the store's instances, memories
/// and compiled code stay valid while the invocation is paused.
final class ResumableExecutionState {
    /// The store that runs the invocation.
    let store: Store
    /// The guest stack of the invocation.
    let stack: ExecutionStack
    /// The end-of-execution slot that the root frame returns to.
    let rootCode: UnsafeMutablePointer<CodeSlot>
    /// The root frame, which holds the arguments and then the results.
    let rootSp: Sp
    /// The root function's signature.
    let type: FunctionType
    /// The root frame's layout.
    let layout: FrameHeaderLayout
    /// The guest's `try_table` handlers while the invocation is paused.
    var exceptionHandlers: [Execution.ExceptionHandler] = []
    /// The guest's caught exceptions while the invocation is paused.
    var storedExceptions: [WasmKitException] = []
    /// The paused host call, or nil while the guest runs or after it finished.
    var pending: PendingHostCall?

    /// How the embedder completed a paused host call.
    enum Completion {
        /// The host function returned these checked results.
        case returning([Value])
        /// The host function failed with this error.
        case throwing(any Error)
    }

    /// Lays out the root frame of an invocation on a new guest stack.
    ///
    /// - Parameters:
    ///   - store: The store that runs the invocation.
    ///   - type: The root function's signature.
    ///   - arguments: Arguments already checked against `type`.
    /// - Throws: A trap when the root frame does not fit the register range.
    init(store: Store, type: FunctionType, arguments: [Value]) throws {
        self.store = store
        self.type = type
        stack = ExecutionStack(engine: store.engine)
        rootCode = .allocate(capacity: 1)
        rootCode.initialize(
            to: Instruction.endOfExecution(.init()).headSlot(
                threadingModel: store.engine.configuration.threadingModel))
        let rootSp = stack.slots.advanced(by: FrameHeaderLayout.numberOfSavingSlots)
        self.rootSp = rootSp
        layout = FrameHeaderLayout(type: type)
        // The root frame has no caller, so its saved stack pointer and function are empty.
        rootSp.previousSP = nil
        rootSp.currentFunction = nil
        try FrameHeaderLayout.checkFitsVRegRange(layout.size)
        for (index, argument) in arguments.enumerated() {
            let reg = VReg(slotIndex: layout.size) + layout.paramReg(index)
            rootSp.storeValue(argument, at: reg, type: type.parameters[index])
        }
    }

    deinit {
        rootCode.deallocate()
    }

    /// Runs the root function until it finishes or pauses.
    ///
    /// - Parameter function: The guest function.
    /// - Returns: The finished results or the first pause.
    /// - Throws: A trap or an error that ends the invocation.
    func start(_ function: InternalFunction) throws -> ResumableCall {
        let paused = try run { execution in
            try execution.execute(sp: rootSp, pc: rootCode, handle: function, type: type)
        }
        guard let paused else { return .finished(results()) }
        return .suspended(pause(paused))
    }

    /// Completes the paused host call and runs the guest until it finishes or pauses again.
    ///
    /// - Parameter completion: The checked results or the failure of the host function.
    /// - Returns: The finished results or the next pause.
    /// - Throws: A trap or an error that ends the invocation.
    func continueAfterHostCall(_ completion: Completion) throws -> ResumeResult {
        guard let pending else {
            preconditionFailure("A continuation exists only while its host call is pending.")
        }
        self.pending = nil
        let call = pending.call
        let threadingModel = store.engine.configuration.threadingModel
        let paused = try run { execution in
            var sp = call.sp
            var pc = call.pc
            var md: Md = nil
            var ms: Ms = 0
            if let instance = sp.currentInstance {
                Execution.CurrentMemory.mayUpdateCurrentInstance(instance: instance, md: &md, ms: &ms)
            }
            switch completion {
            case .returning(let results):
                let function = call.function
                for (index, result) in results.enumerated() {
                    sp.storeValue(
                        result, at: call.spAddend + function.layout.returnReg(index),
                        type: function.resultTypes[index])
                }
            case .throwing(let error):
                if let exception = error as? WasmKitException {
                    guard execution.handleException(exception, sp: &sp, pc: &pc, md: &md, ms: &ms)
                    else { throw exception }
                } else if let trap = error as? Trap {
                    throw trap.withBacktrace(Execution.captureBacktrace(sp: sp, store: store))
                } else {
                    throw error
                }
            }
            do {
                switch threadingModel {
                case .direct:
                    try execution.runDirectThreaded(sp: sp, pc: pc, md: md, ms: ms)
                case .token:
                    try execution.runTokenThreaded(sp: &sp, pc: &pc, md: &md, ms: &ms)
                }
            } catch is Execution.EndOfExecution {
                return
            }
        }
        guard let paused else { return .finished(results()) }
        return .suspended(pause(paused))
    }

    /// Runs the guest on this invocation's stack and classifies how it stopped.
    ///
    /// The store records the stack while the guest runs, so that only host calls of this
    /// invocation can pause it. A nested resumable invocation restores the previous record when
    /// it returns.
    ///
    /// - Parameter body: Enters or re-enters the dispatch loops.
    /// - Returns: The pause, or nil when the guest finished.
    /// - Throws: A trap or an error that ends the invocation.
    private func run(
        _ body: (inout Execution) throws -> Void
    ) throws -> SuspendedHostCall? {
        let stackEnd = stack.slots.advanced(by: stack.count)
        var execution = Execution(store: StoreRef(store), stackEnd: stackEnd)
        execution.exceptionHandlers = exceptionHandlers
        execution.storedExceptions = storedExceptions
        exceptionHandlers = []
        storedExceptions = []
        let previous = store.resumableStackEnd
        store.resumableStackEnd = stackEnd
        defer { store.resumableStackEnd = previous }
        do {
            try body(&execution)
            return nil
        } catch let paused as SuspendedHostCall {
            exceptionHandlers = execution.exceptionHandlers
            storedExceptions = execution.storedExceptions
            return paused
        }
    }

    /// Records a pause and creates its continuation.
    ///
    /// - Parameter call: The paused host call.
    /// - Returns: The continuation with a new identifier.
    private func pause(_ call: SuspendedHostCall) -> SuspendedCall {
        store.lastSuspensionSerial += 1
        let id = SuspensionID(store: store.suspensionIdentity, serial: store.lastSuspensionSerial)
        pending = PendingHostCall(call: call, id: id)
        return SuspendedCall(
            state: self, id: id, tag: call.request.tag,
            hostFunction: Function(handle: .host(call.function), store: store),
            arguments: call.arguments)
    }

    /// Reads the root function's results from the root frame.
    ///
    /// - Returns: The results in declaration order.
    private func results() -> [Value] {
        type.results.enumerated().map { index, resultType in
            let reg = VReg(slotIndex: layout.size) + layout.returnReg(index)
            return rootSp.loadValue(at: reg, type: resultType)
        }
    }
}

extension Function {
    /// Invokes the function so that a host function it calls can pause the invocation.
    ///
    /// The invocation runs synchronously on the calling thread, like ``invoke(_:)``, until the
    /// guest returns or a host function throws ``HostCallSuspension``. At a pause the native frames
    /// of the host call unwind and the guest's frames stay on the invocation's own stack. The
    /// returned ``SuspendedCall`` continues the guest from the call once the embedder has the
    /// host function's results, on whichever executor owns the store.
    ///
    /// - Parameter arguments: The arguments to pass to the function.
    /// - Returns: The finished results or the first pause.
    /// - Throws: A trap or an error that ends the invocation, ``ResumableCallError/notAGuestFunction``
    ///   for a host function, or a parameter type mismatch.
    public func invokeResumable(_ arguments: [Value] = []) throws -> ResumableCall {
        guard handle.isWasm else { throw ResumableCallError.notAGuestFunction }
        let type = store.engine.resolveType(handle.wasm.type)
        try handle.checkParameters(of: type, arguments)
        let state = try ResumableExecutionState(store: store, type: type, arguments: arguments)
        return try state.start(handle)
    }
}
