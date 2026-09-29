import Dispatch
import Foundation
import Synchronization
import Testing
import WAT

@testable import WasmKit

/// Resumable invocations on stores whose execution a controller can stop.
///
/// A controlled store runs token dispatch only. The controller is a signal. The embedder still owns
/// each paused invocation and ends it by resuming or cancelling it.
@Suite(.serialized)
struct ResumableExecutionControlTests {
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
    ///   - control: The store's controller.
    ///   - pause: The host function for the `pause` import.
    ///   - fuel: A fuel budget, which also enables fuel metering.
    /// - Returns: The fixture.
    /// - Throws: Fixture construction failures.
    static func controlled(
        _ control: ExecutionControl, fuel: UInt64? = nil,
        pause: @escaping (Fixture, [Value]) throws -> [Value] = ResumableCallTests.pause
    ) throws -> Fixture {
        try Fixture(
            effects, threadingModel: .token, fuel: fuel, executionControl: control,
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
    ///   - store: A token store, with or without a controller.
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

    @Test
    func aStoppedStoreStartsNoResumableInvocation() throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(control)
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

    @Test(arguments: ImportOutcome.allCases, [ExecutionTermination.interrupted, .deadlineExceeded])
    func aStopDuringTheImportOutranksItsOutcome(
        _ outcome: ImportOutcome, _ reason: ExecutionTermination
    ) throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(control) { _, _ in
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

    @Test
    func aStopOutranksTheRefusalOfADirectHostPause() throws {
        let control = try ExecutionControl()
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: .token)), executionControl: control)
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

    @Test(arguments: RawImportMoment.allCases, [ExecutionTermination.interrupted, .deadlineExceeded])
    func aStopOutranksTheResultsOfARawImport(
        _ moment: RawImportMoment, _ reason: ExecutionTermination
    ) throws {
        let control = try ExecutionControl()
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: .token, features: .all)),
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

    @Test
    func aRawImportDeliversItsResultsAfterAResume() throws {
        let store = try Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: .token, features: .all)),
            executionControl: ExecutionControl())
        let value = V128(bytes: Array(1...16))
        let instance = try Self.rawImportInstance(store: store) { results in results[0] = .v128(value) }
        let run = try #require(instance.exports[function: "pauseThenRun"])
        let call = try ResumableCallTests.suspended(try run.invokeResumable())
        #expect(try ResumableCallTests.finished(try call.resume(returning: [], in: store)) == [.v128(value)])
        #expect(instance.exports[global: "after"]?.value == .i32(1))
        #expect(store.resumableStackEnd == nil)
    }

    @Test
    func aStopRequestedFromAnotherThreadDuringALongImportWins() throws {
        let control = try ExecutionControl()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fixture = try Self.controlled(control) { _, _ in
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

    @Test
    func aStopDuringAPauseEndsTheInvocationAtItsResume() throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(control)
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

    @Test
    func theOwnerCancelsAPausedInvocationAfterAStop() throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(control)
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

    @Test
    func aDeadlineDuringAPauseKeepsItsReason() throws {
        let control = try ExecutionControl()
        let fixture = try Self.controlled(control)
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

    @Test
    func aGuestLoopAfterAResumeStaysInterruptible() throws {
        try watchdog {
            let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
            // The fuel budget ends the loop if polling ever stops after a resume, so a regression
            // fails with an out-of-fuel trap instead of hanging.
            let fixture = try Self.controlled(control, fuel: 50_000_000)
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

    @Test
    func severalPausesUnderAControllerKeepFramesLocalsAndEffects() throws {
        let control = try ExecutionControl()
        let fixture = try Fixture(
            ResumableCallTests.nested, threadingModel: .token, executionControl: control,
            hosts: ["pause": ResumableCallTests.pause, "effect": { _, _ in [] }])
        let first = try ResumableCallTests.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
        #expect(first.arguments == [.i32(30)])
        let second = try ResumableCallTests.suspended(
            try first.resume(returning: [.i32(35)], in: fixture.store))
        #expect(second.arguments == [.i32(65)])
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(2)]])
        let results = try ResumableCallTests.finished(try second.resume(returning: [.i32(130)], in: fixture.store))
        #expect(results == [.i32(UInt32(bitPattern: try ResumableCallTests.nestedReference(3, threadingModel: .token)))])
        #expect(fixture.count("pause") == 2)
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(2)]])
        #expect(try fixture.export("writes")() == [.i32(2)])

        let exceptionControl = try ExecutionControl()
        let exceptions = try Fixture(
            ResumableCallEngineTests.exceptions, threadingModel: .token, features: [.exceptionHandling],
            executionControl: exceptionControl, hosts: ["pause": ResumableCallTests.pause])
        let outer = try ResumableCallTests.suspended(try exceptions.export("outer").invokeResumable())
        #expect(try ResumableCallTests.finished(try outer.resume(returning: [.i32(5)], in: exceptions.store)) == [.i32(15)])
    }

    @Test
    func invalidCompletionsLeaveOtherLiveContinuationsIntact() throws {
        let first = try Self.controlled(try ExecutionControl())
        let second = try Self.controlled(try ExecutionControl())
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

    // MARK: - Ownership and independent stores

    @Test
    func repeatedCyclesUnderAControllerReleaseEveryInvocation() throws {
        var released: [() -> Bool] = []
        for round in 0..<40 {
            let control = try ExecutionControl()
            let fixture = try Self.controlled(control)
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

    @Test
    func stoppingOneStoreLeavesAnotherRunning() throws {
        let stopped = try ExecutionControl()
        let running = try ExecutionControl()
        let first = try Self.controlled(stopped)
        let second = try Self.controlled(running)
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

    @Test
    func controlledStoresStayTokenOnly() throws {
        let direct = Engine(configuration: EngineConfiguration(threadingModel: .direct))
        #expect(throws: ExecutionControlError.unsupportedThreadingModel) {
            try Store(engine: direct, executionControl: try ExecutionControl())
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
