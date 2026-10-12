import Dispatch
import Foundation
import Synchronization
import Testing
import WAT

@testable import WasmKit

/// Resumable invocations on stores whose execution a controller can stop.
///
/// Every check runs on a token-threaded and a direct-threaded store. The controller is a signal. The
/// embedder still owns each paused invocation and ends it by resuming or cancelling it.
@Suite(.serialized)
struct ResumableExecutionControlTests {
    /// The dispatch models that each check runs with. A token store polls between dispatch groups,
    /// and a direct store polls at the checkpoints that translation places in its code.
    static let models: [EngineConfiguration.ThreadingModel] = [.token, .direct]

    /// Every pair of an element of `first` and an element of `second`, for checks that already take
    /// two arguments besides the model.
    static func pairs<First, Second>(_ first: [First], _ second: [Second]) -> [(First, Second)] {
        first.flatMap { a in second.map { b in (a, b) } }
    }

    typealias Fixture = ResumableCallTests.Fixture
    typealias HostFailure = ResumableCallTests.HostFailure

    /// A guest that records effects before and after its pausing import.
    static let effects = """
        (module
          (import "env" "before" (func $before))
          (import "env" "pause" (func $pause (result i32)))
          (import "env" "after" (func $after (param i32)))
          (memory (export "memory") 1)
          (func (export "run") (result i32)
            (call $before)
            (i32.store (i32.const 0) (i32.const 1))
            (call $after (call $pause))
            (i32.store (i32.const 4) (i32.const 1))
            (i32.const 7))
          (func (export "spin") (result i32)
            (drop (call $pause))
            (loop $again (br $again))
            (i32.const 0))
          (func (export "answer") (result i32) (i32.const 42)))
        """

    /// Instantiates ``effects`` on a store bound to `control`.
    ///
    /// - Parameters:
    ///   - model: The store's dispatch model.
    ///   - control: The store's controller.
    ///   - pause: The host function for the `pause` import.
    ///   - fuel: A fuel budget, which also enables fuel metering.
    /// - Returns: The fixture.
    /// - Throws: Fixture construction failures.
    static func controlled(
        _ model: EngineConfiguration.ThreadingModel, _ control: ExecutionControl, fuel: UInt64? = nil,
        pause: @escaping (Fixture, [Value]) throws -> [Value] = ResumableCallTests.pause
    ) throws -> Fixture {
        try Fixture(
            effects, threadingModel: model, fuel: fuel, executionControl: control,
            hosts: ["before": { _, _ in [] }, "pause": pause, "after": { _, _ in [] }])
    }

    /// A guest that returns the `v128` of a raw host import, at once or after a pause.
    ///
    /// The `after` global becomes 1 only when guest code runs after the import returns.
    static let rawImport = """
        (module
          (import "env" "pause" (func $pause))
          (import "env" "host" (func $host (result v128)))
          (global (export "after") (mut i32) (i32.const 0))
          (func (export "run") (result v128)
            (call $host)
            (global.set 0 (i32.const 1)))
          (func (export "pauseThenRun") (result v128)
            (call $pause)
            (call $host)
            (global.set 0 (i32.const 1))))
        """

    /// Instantiates ``rawImport`` with a `pause` import that always pauses.
    ///
    /// - Parameters:
    ///   - store: A store, with or without a controller.
    ///   - host: The body of the raw `host` import, which receives its one-element result buffer.
    /// - Returns: The instance.
    /// - Throws: Parsing or instantiation failures.
    static func rawImportInstance(
        store: Store, host: @escaping (UnsafeMutableBufferPointer<Value>) throws -> Void
    ) throws -> Instance {
        var imports = Imports()
        imports.define(
            module: "env", name: "pause",
            Function(store: store, parameters: []) { _, _ in throw HostCallSuspension(tag: 1) })
        imports.define(
            module: "env", name: "host",
            Function(store: store, parameters: [], results: [.v128], raw: { _, _, results in try host(results) }))
        return try parseWasm(bytes: wat2wasm(rawImport, features: .all), features: .all)
            .instantiate(store: store, imports: imports)
    }

    /// Returns whether the guest wrote the memory flag at `offset`.
    static func wrote(_ fixture: Fixture, at offset: Int) throws -> Bool {
        let memory = try #require(fixture.instance.exports[memory: "memory"])
        return memory.withUnsafeBufferPointer(offset: UInt(offset), count: 1) { $0[0] } != 0
    }

    /// Checks that the guest stopped at its pausing import and wrote nothing after it.
    static func expectNoEffectsAfterTheImport(_ fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(fixture.count("after") == 0, sourceLocation: sourceLocation)
        #expect(try !wrote(fixture, at: 4), sourceLocation: sourceLocation)
        #expect(fixture.store.resumableStackEnd == nil, sourceLocation: sourceLocation)
    }

    // MARK: - Entry and native import boundaries

    /// Refuses a resumable invocation of a stopped store before any guest code or import runs.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aStoppedStoreStartsNoResumableInvocation(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control)
        control.requestInterruption()
        #expect(throws: ExecutionTermination.interrupted) {
            _ = try fixture.export("run").invokeResumable()
        }
        #expect(fixture.count("before") == 0)
        #expect(try !Self.wrote(fixture, at: 0))
        #expect(fixture.store.resumableStackEnd == nil)
    }

    /// How the host import ends after it requested the stop.
    enum ImportOutcome: String, CaseIterable, Sendable {
        case value, error, suspension
    }

    /// Ends the invocation with the stop that an import requested, whatever the import then
    /// returns, throws or asks for, and runs no guest code after the import.
    ///
    /// - Parameters:
    ///   - model: The dispatch model of the controlled store.
    ///   - variant: How the import ends and the reason it requests.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models, Self.pairs(ImportOutcome.allCases, [ExecutionTermination.interrupted, .deadlineExceeded]))
    func aStopDuringTheImportOutranksItsOutcome(
        model: EngineConfiguration.ThreadingModel, _ variant: (outcome: ImportOutcome, reason: ExecutionTermination)
    ) throws {
        let (outcome, reason) = variant
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control) { _, _ in
            // The native work completes. The stop is observed when it returns.
            control.requestInterruption(reason: reason)
            switch outcome {
            case .value: return [.i32(5)]
            case .error: throw HostFailure()
            case .suspension: throw HostCallSuspension(tag: 1)
            }
        }
        #expect(throws: reason) {
            _ = try fixture.export("run").invokeResumable()
        }
        #expect(fixture.count("before") == 1)
        try Self.expectNoEffectsAfterTheImport(fixture)
        #expect(control.termination == reason)
    }

    /// Reports the stop, rather than the refused pause, of a host function that the embedder calls
    /// directly and that requests a stop before it asks to pause.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction failures.
    @Test(arguments: Self.models)
    func aStopOutranksTheRefusalOfADirectHostPause(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: model)), executionControl: control)
        let pausing = Function(store: store, parameters: [], results: [.i32]) { _, _ in
            control.requestInterruption()
            throw HostCallSuspension(tag: 1)
        }
        #expect(throws: ExecutionTermination.interrupted) { _ = try pausing() }
    }

    /// When a resumable invocation reaches the raw import.
    enum RawImportMoment: String, CaseIterable, Sendable {
        case firstRun, afterAResume
    }

    /// Ends the invocation with the stop that a raw import requested before the import's mistyped
    /// result reaches the guest, on the first run and after a resume.
    ///
    /// - Parameters:
    ///   - model: The dispatch model of the controlled store.
    ///   - variant: When the invocation reaches the import, and the reason the import requests.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models, Self.pairs(RawImportMoment.allCases, [ExecutionTermination.interrupted, .deadlineExceeded]))
    func aStopOutranksTheResultsOfARawImport(
        model: EngineConfiguration.ThreadingModel, _ variant: (moment: RawImportMoment, reason: ExecutionTermination)
    ) throws {
        let (moment, reason) = variant
        let control = try ExecutionControl()
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: model, features: .all)),
            executionControl: control)
        let instance = try Self.rawImportInstance(store: store) { results in
            control.requestInterruption(reason: reason)
            // Storing an i32 in the v128 result would fail a precondition, so the stop must come
            // first.
            results[0] = .i32(42)
        }
        let run = try #require(instance.exports[function: moment == .firstRun ? "run" : "pauseThenRun"])
        #expect(throws: reason) {
            switch try run.invokeResumable() {
            case .finished(let results):
                Issue.record("Finished with \(results)")
            case .suspended(let call):
                #expect(moment == .afterAResume)
                _ = try call.resume(returning: [], in: store)
            }
        }
        #expect(instance.exports[global: "after"]?.value == .i32(0))
        #expect(store.resumableStackEnd == nil)
    }

    /// Delivers a raw import's `v128` result to the guest after a resume on a live controlled store.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aRawImportDeliversItsResultsAfterAResume(model: EngineConfiguration.ThreadingModel) throws {
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: model, features: .all)),
            executionControl: ExecutionControl())
        let value = V128(bytes: Array(1...16))
        let instance = try Self.rawImportInstance(store: store) { results in results[0] = .v128(value) }
        let run = try #require(instance.exports[function: "pauseThenRun"])
        let call = try ResumableCallTests.suspended(try run.invokeResumable())
        #expect(try ResumableCallTests.finished(try call.resume(returning: [], in: store)) == [.v128(value)])
        #expect(instance.exports[global: "after"]?.value == .i32(1))
        #expect(store.resumableStackEnd == nil)
    }

    /// Ends the invocation with a stop that another thread requests while a long import runs, once
    /// the import returns, and runs no guest code after the import.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aStopRequestedFromAnotherThreadDuringALongImportWins(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fixture = try Self.controlled(model, control) { _, _ in
            entered.signal()
            // The native call runs until the test releases it, as a long SDK call would.
            guard release.wait(timeout: .now() + 10) == .success else { throw HostFailure() }
            return [.i32(5)]
        }
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let run = try fixture.export("run")
        nonisolated(unsafe) let unsafeRun = run
        DispatchQueue.global().async {
            do {
                switch try unsafeRun.invokeResumable() {
                case .finished: outcome.withLock { $0 = .success(()) }
                case .suspended(let call):
                    call.cancel()
                    outcome.withLock { $0 = .success(()) }
                }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 10) == .success)
        control.requestInterruption()
        release.signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        let result = try #require(outcome.withLock { $0 })
        switch result {
        case .success: Issue.record("The guest finished after the stop.")
        case .failure(let error): #expect(error as? ExecutionTermination == .interrupted)
        }
        try Self.expectNoEffectsAfterTheImport(fixture)
    }

    // MARK: - Paused invocations after a stop

    /// Ends a paused invocation with the stop at its resume, releases its state, and refuses later
    /// entries of the store.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aStopDuringAPauseEndsTheInvocationAtItsResume(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control)
        weak var state: ResumableExecutionState?
        do {
            let paused = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
            state = paused.state
            control.requestInterruption()
            do {
                _ = try paused.resume(returning: [.i32(5)], in: fixture.store)
                Issue.record("The stopped invocation continued.")
            } catch let termination as ExecutionTermination {
                #expect(termination == .interrupted)
            }
        }
        #expect(state == nil)
        try Self.expectNoEffectsAfterTheImport(fixture)
        #expect(throws: ExecutionTermination.interrupted) { _ = try fixture.export("answer")() }
        #expect(throws: ExecutionTermination.interrupted) { _ = try fixture.export("answer").invokeResumable() }
    }

    /// Keeps a paused invocation after a stop until its owner cancels it, which releases it.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func theOwnerCancelsAPausedInvocationAfterAStop(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control)
        weak var state: ResumableExecutionState?
        do {
            let paused = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
            state = paused.state
            control.requestInterruption()
            // The controller is only a signal, so the paused invocation stays until its owner acts.
            #expect(state != nil)
            paused.cancel()
        }
        #expect(state == nil)
        try Self.expectNoEffectsAfterTheImport(fixture)
    }

    /// A completion that a resume would refuse on a live store.
    enum RefusedCompletion: CaseIterable, Sendable {
        /// Fewer results than the host function declares.
        case resultCount
        /// A result of another type than the host function declares.
        case resultType
        /// Results for another pause of the same store.
        case stalePause
        /// Results passed with another store.
        case foreignStore
        /// A failure for another pause of the same store.
        case staleFailure
    }

    /// Ends a stopped invocation at a resume that a live store would refuse, so the stop outranks
    /// each kind of refused completion.
    ///
    /// - Parameters:
    ///   - model: The dispatch model of the controlled store.
    ///   - completion: The completion that a live store would refuse.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models, RefusedCompletion.allCases)
    func aStopOutranksTheRefusalOfAResume(model: EngineConfiguration.ThreadingModel, _ completion: RefusedCompletion) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control)
        weak var state: ResumableExecutionState?
        do {
            let other = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
            let otherID = other.id
            other.cancel()
            let paused = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
            state = paused.state
            control.requestInterruption()
            // A stop is checked before the completion, so each of these ends the invocation
            // instead of returning it refused.
            do {
                switch completion {
                case .resultCount:
                    _ = try paused.resume(returning: [], in: fixture.store)
                case .resultType:
                    _ = try paused.resume(returning: [.i64(5)], in: fixture.store)
                case .stalePause:
                    _ = try paused.resume(returning: [.i32(5)], completing: otherID, in: fixture.store)
                case .foreignStore:
                    _ = try paused.resume(returning: [.i32(5)], in: Store(engine: fixture.store.engine))
                case .staleFailure:
                    _ = try paused.resume(throwing: HostFailure(), completing: otherID, in: fixture.store)
                }
                Issue.record("The stopped invocation was refused instead of ended.")
            } catch let termination as ExecutionTermination {
                #expect(termination == .interrupted)
            }
        }
        #expect(state == nil)
        try Self.expectNoEffectsAfterTheImport(fixture)
    }

    /// Keeps a deadline that arrived first during a pause when a second stop follows, and reports it
    /// at the resume and at later entries.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aDeadlineDuringAPauseKeepsItsReason(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(model, control)
        let paused = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
        control.requestInterruption(reason: .deadlineExceeded)
        control.requestInterruption(reason: .interrupted)
        do {
            _ = try paused.resume(throwing: HostFailure(), in: fixture.store)
            Issue.record("The stopped invocation continued.")
        } catch let termination as ExecutionTermination {
            #expect(termination == .deadlineExceeded)
        }
        #expect(control.termination == .deadlineExceeded)
        #expect(throws: ExecutionTermination.deadlineExceeded) { _ = try fixture.export("answer")() }
        try Self.expectNoEffectsAfterTheImport(fixture)
    }

    // MARK: - Polling after a resume

    /// Stops a guest loop that starts after a resume, which shows that a resumed invocation polls.
    ///
    /// - Parameter model: The dispatch model of the controlled store.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aGuestLoopAfterAResumeStaysInterruptible(model: EngineConfiguration.ThreadingModel) throws {
        try watchdog {
            let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
            // The fuel budget ends the loop if polling ever stops after a resume, so a regression
            // fails with an out-of-fuel trap instead of hanging.
            let fixture = try Self.controlled(model, control, fuel: 50_000_000)
            let paused = try ResumableCallTests.suspended(try fixture.export("spin").invokeResumable())
            let progress = control.observedCheckpointCount
            let observed = Mutex(false)
            let requested = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while control.observedCheckpointCount < progress + 8, ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.0001)
                }
                observed.withLock { $0 = control.observedCheckpointCount >= progress + 8 }
                control.requestInterruption()
                requested.signal()
            }
            do {
                _ = try paused.resume(returning: [.i32(0)], in: fixture.store)
                Issue.record("The loop finished.")
            } catch let termination as ExecutionTermination {
                #expect(termination == .interrupted)
            } catch {
                Issue.record("The resumed loop ended with \(error) instead of the stop.")
            }
            #expect(requested.wait(timeout: .now() + 10) == .success)
            #expect(observed.withLock { $0 })
            #expect(fixture.store.resumableStackEnd == nil)
        }
    }

    // MARK: - Pauses and validation under a controller

    /// Keeps the frames, locals and effects of nested calls across several pauses on a live
    /// controlled store, and keeps an exception handler across a pause, so that it catches the
    /// exception the guest throws after the resume.
    ///
    /// - Parameter model: The dispatch model of the controlled stores.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func severalPausesUnderAControllerKeepFramesLocalsAndEffects(model: EngineConfiguration.ThreadingModel) throws {
        let control = try ExecutionControl()
        let fixture = try Fixture(
            ResumableCallTests.nested, threadingModel: model, executionControl: control,
            hosts: ["pause": ResumableCallTests.pause, "effect": { _, _ in [] }])
        let first = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
        #expect(first.arguments == [.i32(30)])
        let second = try ResumableCallTests.suspended(
            try first.resume(returning: [.i32(35)], in: fixture.store))
        #expect(second.arguments == [.i32(65)])
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(2)]])
        let results = try ResumableCallTests.finished(try second.resume(returning: [.i32(130)], in: fixture.store))
        #expect(results == [.i32(UInt32(bitPattern: try ResumableCallTests.nestedReference(3, threadingModel: model)))])
        #expect(fixture.count("pause") == 2)
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(2)]])
        #expect(try fixture.export("writes")() == [.i32(2)])

        let exceptionControl = try ExecutionControl()
        let exceptions = try Fixture(
            ResumableCallEngineTests.exceptions, threadingModel: model, features: [.exceptionHandling],
            executionControl: exceptionControl, hosts: ["pause": ResumableCallTests.pause])
        let outer = try ResumableCallTests.suspended(try exceptions.export("outer").invokeResumable())
        #expect(try ResumableCallTests.finished(try outer.resume(returning: [.i32(5)], in: exceptions.store)) == [.i32(15)])
    }

    /// Refuses stale, foreign, miscounted and mistyped completions on live stores without
    /// disturbing either paused invocation, which then finish with their own results.
    ///
    /// - Parameter model: The dispatch model of the controlled stores.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func invalidCompletionsLeaveOtherLiveContinuationsIntact(model: EngineConfiguration.ThreadingModel) throws {
        let first = try Self.controlled(model, try ExecutionControl())
        let second = try Self.controlled(model, try ExecutionControl())
        let a = try ResumableCallTests.suspended(try first.export("run").invokeResumable())
        let b = try ResumableCallTests.suspended(try second.export("run").invokeResumable())
        let bID = b.id

        let stale = try ResumableCallTests.rejected(try a.resume(returning: [.i32(5)], completing: bID, in: first.store))
        #expect(stale.reason == .staleSuspension)
        let foreign = try ResumableCallTests.rejected(try stale.call.resume(returning: [.i32(5)], in: second.store))
        #expect(foreign.reason == .foreignStore)
        let count = try ResumableCallTests.rejected(try foreign.call.resume(returning: [], in: first.store))
        #expect(count.reason == .resultCount(expected: 1, actual: 0))
        let type = try ResumableCallTests.rejected(try count.call.resume(returning: [.i64(5)], in: first.store))
        #expect(type.reason == .resultType(index: 0, expected: .i32))
        #expect(first.count("after") == 0)
        #expect(second.count("after") == 0)

        #expect(try ResumableCallTests.finished(try b.resume(returning: [.i32(6)], in: second.store)) == [.i32(7)])
        #expect(try ResumableCallTests.finished(try type.call.resume(returning: [.i32(5)], in: first.store)) == [.i32(7)])
        #expect(first.calls["after"] == [[.i32(5)]])
        #expect(second.calls["after"] == [[.i32(6)]])
    }

    // MARK: - The polling budget across pauses

    /// A guest that probes, pauses, runs three `nop`s, and probes again.
    ///
    /// Under direct threading each call ends a control segment. The segments hold `call $probe`,
    /// then `call $pause`, then `local.set`, three `nop`s and `call $probe`, then `local.get` and
    /// the closing `end`, so they count one, one, five, and two operators.
    static let budgeted = """
        (module (import "host" "probe" (func $probe)) (import "host" "pause" (func $pause (result i32)))
            (func (export "run") (result i32) (local $r i32)
                (call $probe)
                (local.set $r (call $pause))
                nop nop nop
                (call $probe)
                (local.get $r)))
        """

    /// The polling interval of every ``budgeted`` store, far above the operators the guest runs.
    static let budgetInterval: UInt32 = 1_000

    /// Budgets that host functions read on the guest's thread, in call order.
    final class BudgetLog: @unchecked Sendable {
        var values: [UInt64] = []
    }

    /// A ``budgeted`` instance whose host functions record the store's budget when they run.
    struct Budgeted {
        let store: Store
        let control: ExecutionControl
        let run: Function
        /// The budgets that `probe` and `pause` read.
        let budgets: BudgetLog
    }

    /// Instantiates ``budgeted`` on a fresh controlled store.
    ///
    /// - Parameter model: The store's dispatch model.
    /// - Returns: The fixture.
    /// - Throws: Fixture construction failures.
    static func budgeted(_ model: EngineConfiguration.ThreadingModel) throws -> Budgeted {
        let control = try ExecutionControl(pollingInterval: budgetInterval)
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: model, memoryBoundsChecking: .software)),
            executionControl: control)
        let budgets = BudgetLog()
        var imports = Imports()
        imports.define(
            module: "host", name: "probe",
            Function(store: store, parameters: []) { caller, _ in
                budgets.values.append(caller.store.controlBudget.value)
                return []
            })
        imports.define(
            module: "host", name: "pause",
            Function(store: store, parameters: [], results: [.i32]) { caller, _ in
                budgets.values.append(caller.store.controlBudget.value)
                throw HostCallSuspension(tag: 1)
            })
        let instance = try parseWasm(bytes: wat2wasm(budgeted)).instantiate(store: store, imports: imports)
        return Budgeted(
            store: store, control: control, run: try #require(instance.exports[function: "run"]), budgets: budgets)
    }

    /// Keeps a pause's budget through refused completions and a foreign store, continues in
    /// checkpointed code from that budget when the right completion arrives, and leaves the
    /// remaining budget to the next invocation after the call completes.
    ///
    /// The expected budgets follow from the segments that ``budgeted`` describes. Only a poll refills
    /// the budget, and none happens here. A token store never reads or writes its budget, which
    /// stays at the interval throughout.
    ///
    /// - Parameter model: The dispatch model of both stores.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func aPauseKeepsItsBudgetThroughRefusals(model: EngineConfiguration.ThreadingModel) throws {
        let main = try Self.budgeted(model)
        let neighbour = try Self.budgeted(model)
        let full = UInt64(Self.budgetInterval)
        let direct = model == .direct

        let neighbourPaused = try ResumableCallTests.suspended(try neighbour.run.invokeResumable())
        let neighbourBudget = neighbour.store.controlBudget.value
        let paused = try ResumableCallTests.suspended(try main.run.invokeResumable())
        let atPause = main.store.controlBudget.value
        #expect(main.budgets.values == (direct ? [full - 1, full - 2] : [full, full]))
        #expect(atPause == main.budgets.values.last)

        let stale = try ResumableCallTests.rejected(
            try paused.resume(returning: [.i32(5)], completing: neighbourPaused.id, in: main.store))
        #expect(stale.reason == .staleSuspension)
        let foreign = try ResumableCallTests.rejected(try stale.call.resume(returning: [.i32(5)], in: neighbour.store))
        #expect(foreign.reason == .foreignStore)
        let count = try ResumableCallTests.rejected(try foreign.call.resume(returning: [], in: main.store))
        #expect(count.reason == .resultCount(expected: 1, actual: 0))
        let type = try ResumableCallTests.rejected(try count.call.resume(returning: [.i64(5)], in: main.store))
        #expect(type.reason == .resultType(index: 0, expected: .i32))
        #expect(main.store.controlBudget.value == atPause)
        #expect(neighbour.store.controlBudget.value == neighbourBudget)

        let results = try ResumableCallTests.finished(try type.call.resume(returning: [.i32(5)], in: main.store))
        #expect(results == [.i32(5)])
        #expect(main.budgets.values == (direct ? [full - 1, full - 2, full - 7] : [full, full, full]))
        #expect(main.store.controlBudget.value == (direct ? full - 9 : full))
        #expect(neighbour.store.controlBudget.value == neighbourBudget)
        #expect(main.control.termination == nil)

        // The completed call's end does not refill the budget, so the next invocation starts from it.
        let next = try ResumableCallTests.suspended(try main.run.invokeResumable())
        #expect(main.budgets.values == (direct ? [full - 1, full - 2, full - 7, full - 10, full - 11] : Array(repeating: full, count: 5)))
        #expect(main.store.controlBudget.value == (direct ? full - 11 : full))
        next.cancel()
        neighbourPaused.cancel()
        #expect(neighbour.store.controlBudget.value == neighbourBudget)
    }

    /// Leaves the budget where the pause left it when the invocation is cancelled or dropped,
    /// and lets the next invocation of the store continue from it.
    ///
    /// - Parameter model: The store's dispatch model.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func cancellingOrDroppingAPauseLeavesTheBudget(model: EngineConfiguration.ThreadingModel) throws {
        let main = try Self.budgeted(model)
        let full = UInt64(Self.budgetInterval)
        let first = try ResumableCallTests.suspended(try main.run.invokeResumable())
        let afterFirst = main.store.controlBudget.value
        first.cancel()
        #expect(main.store.controlBudget.value == afterFirst)
        do {
            _ = try ResumableCallTests.suspended(try main.run.invokeResumable())
        }
        let afterSecond = main.store.controlBudget.value
        #expect(afterFirst == (model == .direct ? full - 2 : full))
        #expect(afterSecond == (model == .direct ? full - 4 : full))
        #expect(main.control.termination == nil)
    }

    // MARK: - Ownership and independent stores

    /// Releases every paused invocation over repeated cycles that end with a resume, a cancel, a
    /// failure or a stop.
    ///
    /// - Parameter model: The dispatch model of the controlled stores.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func repeatedCyclesUnderAControllerReleaseEveryInvocation(model: EngineConfiguration.ThreadingModel) throws {
        var released: [() -> Bool] = []
        for round in 0..<40 {
            let control = try ExecutionControl()
            let fixture = try Self.controlled(model, control)
            weak var state: ResumableExecutionState?
            do {
                let paused = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable())
                state = paused.state
                switch round % 4 {
                case 0:
                    #expect(try ResumableCallTests.finished(try paused.resume(returning: [.i32(1)], in: fixture.store)) == [.i32(7)])
                case 1:
                    paused.cancel()
                case 2:
                    do {
                        _ = try paused.resume(throwing: HostFailure(), in: fixture.store)
                        Issue.record("The host failure did not end the invocation.")
                    } catch is HostFailure {}
                default:
                    control.requestInterruption()
                    do {
                        _ = try paused.resume(returning: [.i32(1)], in: fixture.store)
                        Issue.record("The stopped invocation continued.")
                    } catch let termination as ExecutionTermination {
                        #expect(termination == .interrupted)
                    }
                }
            }
            released.append { state == nil }
            #expect(fixture.store.resumableStackEnd == nil)
        }
        #expect(released.allSatisfy { $0() })
    }

    /// Ends the paused invocation of a stopped store and lets the paused invocation of another
    /// store finish.
    ///
    /// - Parameter model: The dispatch model of the controlled stores.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: Self.models)
    func stoppingOneStoreLeavesAnotherRunning(model: EngineConfiguration.ThreadingModel) throws {
        let stopped = try ExecutionControl()
        let running = try ExecutionControl()
        let first = try Self.controlled(model, stopped)
        let second = try Self.controlled(model, running)
        let a = try ResumableCallTests.suspended(try first.export("run").invokeResumable())
        let b = try ResumableCallTests.suspended(try second.export("run").invokeResumable())
        stopped.requestInterruption()
        do {
            _ = try a.resume(returning: [.i32(1)], in: first.store)
            Issue.record("The stopped invocation continued.")
        } catch let termination as ExecutionTermination {
            #expect(termination == .interrupted)
        }
        #expect(running.termination == nil)
        #expect(try ResumableCallTests.finished(try b.resume(returning: [.i32(2)], in: second.store)) == [.i32(7)])
        #expect(try second.export("answer")() == [.i32(42)])
        #expect(second.calls["after"] == [[.i32(2)]])
    }

    /// Accepts a controller on a token-threaded and on a direct-threaded store.
    ///
    /// - Throws: Controller configuration failures.
    @Test
    func controlledStoresAcceptBothModels() throws {
        for model in Self.models {
            let engine = Engine(configuration: EngineConfiguration(threadingModel: model))
            _ = try Store(engine: engine, executionControl: try ExecutionControl())
        }
    }

    /// Ends this test process if a regression stops the guest from ever unwinding.
    ///
    /// - Parameter body: The fixture expected to finish before the watchdog expires.
    /// - Throws: The fixture's own failure.
    private func watchdog(_ body: () throws -> Void) rethrows {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler {
            FileHandle.standardError.write(Data("Resumable control watchdog expired.\n".utf8))
            exit(124)
        }
        timer.resume()
        defer { timer.cancel() }
        try body()
    }
}
