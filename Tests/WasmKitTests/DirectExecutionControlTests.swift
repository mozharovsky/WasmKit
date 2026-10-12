import Dispatch
import Foundation
import Synchronization
import Testing
import WAT

@testable import WasmKit

/// Checks of an execution controller on a direct-threaded store, which polls at checkpoints that
/// translation places in the guest code instead of between token dispatch groups.
@Suite(.serialized)
struct DirectExecutionControlTests {
    /// Ends a guest that loops forever, and a long straight-line function without imports, with
    /// the reason the host requested, and keeps ending later invocations with it.
    ///
    /// - Parameters:
    ///   - shape: `loop` for a branch cycle, `straight` for one long function without branches.
    ///   - reason: The terminal reason the host requests.
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test(arguments: ["loop", "straight"], [ExecutionTermination.interrupted, .deadlineExceeded])
    func aStopEndsGuestCode(shape: String, reason: ExecutionTermination) throws {
        try watchdog {
            let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
            let store = try directStore(control)
            let body =
                shape == "loop"
                ? "(loop $again global.get 0 i32.const 1 i32.add global.set 0 (br $again))"
                : Array(repeating: "global.get 0 i32.const 1 i32.add global.set 0", count: Self.straightLineCount)
                    .joined(separator: "\n")
            let instance = try parseWasm(
                bytes: wat2wasm(
                    """
                    (module (global $count (export "count") (mut i32) (i32.const 0))
                        (func (export "work") \(body))
                        (func (export "answer") (result i32) i32.const 42))
                    """)
            ).instantiate(store: store)
            let work = try #require(instance.exports[function: "work"])
            try stopAfterProgress(control, reason: reason) {
                #expect(throws: reason) { try work() }
            }
            let count = try #require(instance.exports[global: "count"]?.value.i32)
            // The straight-line function stopped before its end, so a checkpoint inside it saw the request.
            #expect(count > 0)
            if shape == "straight" {
                #expect(count < UInt32(Self.straightLineCount))
            }
            let answer = try #require(instance.exports[function: "answer"])
            #expect(throws: reason) { try answer() }
            #expect(control.termination == reason)
        }
    }

    /// Keeps the first reason when a second request arrives, and refuses every later entry,
    /// including a host function called directly and a module start function.
    ///
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test
    func theFirstReasonRetiresTheStore() throws {
        let control = try ExecutionControl()
        let store = try directStore(control)
        let host = Function(store: store, parameters: [], results: [.i32]) { _, _ in [.i32(7)] }
        let instance = try parseWasm(bytes: wat2wasm("(module (func (export \"answer\") (result i32) i32.const 42))"))
            .instantiate(store: store)
        let answer = try #require(instance.exports[function: "answer"])
        #expect(try answer() == [.i32(42)])
        #expect(try host() == [.i32(7)])
        control.requestInterruption(reason: .deadlineExceeded)
        control.requestInterruption(reason: .interrupted)
        #expect(control.termination == .deadlineExceeded)
        #expect(throws: ExecutionTermination.deadlineExceeded) { try answer() }
        #expect(throws: ExecutionTermination.deadlineExceeded) { try host() }
        let started = try parseWasm(bytes: wat2wasm("(module (func $start) (start $start))"))
        #expect(throws: ExecutionTermination.deadlineExceeded) { try started.instantiate(store: store) }
        #expect(throws: ExecutionTermination.deadlineExceeded) { try answer() }
    }

    /// The outcomes a host import can produce while the store is being stopped.
    enum ImportOutcome: CaseIterable, Sendable {
        /// The import returns a well-typed result.
        case result
        /// The import throws its own error.
        case failure
        /// The import returns a result of the wrong type through the array-based API.
        case invalidResult
    }

    /// Fails for an import whose own error must not reach the caller after a stop.
    struct HostFailure: Error {}

    /// Checks the controller when an import returns, before its result, its error, or the
    /// rejection of an invalid result reaches the guest, and runs no guest code after it.
    ///
    /// - Parameters:
    ///   - outcome: What the import produces after it requests the stop.
    ///   - reason: The terminal reason the import requests.
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test(arguments: ImportOutcome.allCases, [ExecutionTermination.interrupted, .deadlineExceeded])
    func aStopDuringAnImportOutranksItsOutcome(outcome: ImportOutcome, reason: ExecutionTermination) throws {
        let control = try ExecutionControl()
        let store = try directStore(control)
        let host = Function(store: store, parameters: [], results: [.i32]) { _, _ in
            control.requestInterruption(reason: reason)
            switch outcome {
            case .result: return [.i32(5)]
            case .failure: throw HostFailure()
            case .invalidResult: return [.i64(5)]
            }
        }
        var imports = Imports()
        imports.define(module: "host", name: "call", host)
        let instance = try parseWasm(
            bytes: wat2wasm(
                """
                (module (import "host" "call" (func $call (result i32)))
                    (global (export "after") (mut i32) (i32.const 0))
                    (func (export "run") (result i32)
                        call $call
                        i32.const 1 global.set 0))
                """)
        ).instantiate(store: store, imports: imports)
        let run = try #require(instance.exports[function: "run"])
        #expect(throws: reason) { try run() }
        #expect(instance.exports[global: "after"]?.value == .i32(0))
    }

    /// Lets a neighbouring store finish its work while another store with the same module is
    /// stopped, and keeps a stopped store's results from leaking into the neighbour.
    ///
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test
    func aNeighbouringStoreKeepsRunning() throws {
        try watchdog {
            let module = try parseWasm(
                bytes: wat2wasm(
                    """
                    (module
                        (func (export "spin") (loop $again (br $again)))
                        (func (export "sum") (param $n i32) (result i32) (local $acc i32)
                            (block $done (loop $next
                                (br_if $done (i32.eqz (local.get $n)))
                                (local.set $acc (i32.add (local.get $acc) (local.get $n)))
                                (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                                (br $next)))
                            local.get $acc))
                    """))
            let stopped = try ExecutionControl(recordsCheckpoints: true)
            let first = try module.instantiate(store: directStore(stopped))
            let neighbourControl = try ExecutionControl()
            let neighbour = try module.instantiate(store: directStore(neighbourControl))
            let plain = try module.instantiate(
                store: Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .direct))))
            let spin = try #require(first.exports[function: "spin"])
            let plainSum = try #require(plain.exports[function: "sum"])
            // The neighbour's store runs only on the worker thread until the worker is done.
            let neighbourSum = Box(try #require(neighbour.exports[function: "sum"]))
            let results = Box<[[Value]]>([])
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                for _ in 0..<50 {
                    results.value.append((try? neighbourSum.value([.i32(100_000)])) ?? [])
                }
                done.signal()
            }
            try stopAfterProgress(stopped, reason: .interrupted) {
                #expect(throws: ExecutionTermination.interrupted) { try spin() }
            }
            #expect(done.wait(timeout: .now() + 10) == .success)
            let expected = try plainSum([.i32(100_000)])
            #expect(results.value.count == 50)
            #expect(results.value.allSatisfy { value in value == expected })
            #expect(neighbourControl.termination == nil)
            #expect(try neighbourSum.value([.i32(10)]) == [.i32(55)])
        }
    }

    /// Runs nested guest calls through a host import, linear memory growth, and caught guest
    /// exceptions on a live store with the same answers as an uncontrolled direct store.
    ///
    /// - Parameter pollingInterval: The operators between polls. One polls at almost every
    ///   checkpoint.
    /// - Throws: Fixture construction, export lookup, or invocation failures.
    @Test(arguments: [UInt32(1), 1024])
    func aLiveStoreKeepsItsResults(pollingInterval: UInt32) throws {
        let wasm = try wat2wasm(
            """
            (module (import "host" "reenter" (func $reenter (param i32) (result i32)))
                (memory (export "memory") 1 64)
                (tag $odd (param i32))
                (func $inner (export "inner") (param $x i32) (result i32)
                    (i32.add (i32.mul (local.get $x) (i32.const 3)) (i32.const 1)))
                (func (export "grow") (param $pages i32) (result i32) (local $i i32) (local $acc i32)
                    (loop $next
                        (drop (memory.grow (i32.const 1)))
                        (i32.store (i32.mul (memory.size) (i32.const 65532)) (local.get $i))
                        (local.set $acc (i32.add (local.get $acc)
                            (i32.load (i32.mul (memory.size) (i32.const 65532)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $pages))))
                    (i32.add (local.get $acc) (memory.size)))
                (func (export "nested") (param $n i32) (result i32) (local $acc i32)
                    (loop $next
                        (local.set $acc (i32.add (local.get $acc) (call $reenter (local.get $n))))
                        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                        (br_if $next (local.get $n)))
                    local.get $acc)
                (func (export "catching") (param $n i32) (result i32) (local $caught i32)
                    (loop $next
                        (block $handler (result i32)
                            (try_table (catch $odd $handler)
                                (if (i32.and (local.get $n) (i32.const 1))
                                    (then (throw $odd (local.get $n)))))
                            (i32.const 0))
                        (local.set $caught (i32.add (local.get $caught)))
                        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
                        (br_if $next (local.get $n)))
                    local.get $caught))
            """, features: .all)
        func results(_ store: Store) throws -> [[Value]] {
            var imports = Imports()
            let inner = Box<Function?>(nil)
            imports.define(
                module: "host", name: "reenter",
                Function(store: store, parameters: [.i32], results: [.i32]) { _, arguments in
                    guard let function = inner.value else { throw HostFailure() }
                    return try function(arguments)
                })
            let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: store, imports: imports)
            inner.value = instance.exports[function: "inner"]
            return try ["grow", "nested", "catching"].map { name in
                let function = try #require(instance.exports[function: name])
                return try function([.i32(name == "grow" ? 40 : 300)])
            }
        }
        let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
        let controlled = try results(directStore(control))
        let plain = try results(
            Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .direct, features: .all))))
        #expect(controlled == plain)
        #expect(control.termination == nil)
        // With an interval of one the guest polls at about every other checkpoint, so the
        // answers above were computed across thousands of polls.
        if pollingInterval == 1 {
            #expect(control.observedCheckpointCount > 3_000)
        }
    }

    /// Keeps fuel metering's trap and remaining budget on a controlled direct store equal to an
    /// uncontrolled one, both when the budget runs out and when it suffices.
    ///
    /// - Parameter budget: The fuel the store starts with.
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test(arguments: [UInt64(500), 1_000_000])
    func fuelKeepsItsSemantics(budget: UInt64) throws {
        let wasm = try wat2wasm(
            """
            (module (func (export "count") (param $n i32) (result i32) (local $i i32)
                (loop $next
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br_if $next (i32.lt_u (local.get $i) (local.get $n))))
                local.get $i))
            """)
        func outcome(_ store: Store) throws -> (Result<[Value], Trap>, UInt64?) {
            store.fuel = Fuel(remaining: budget)
            let instance = try parseWasm(bytes: wasm).instantiate(store: store)
            let count = try #require(instance.exports[function: "count"])
            let result: Result<[Value], Trap>
            do {
                result = .success(try count([.i32(1_000)]))
            } catch let trap as Trap {
                result = .failure(trap)
            }
            return (result, store.fuel?.remaining)
        }
        let configuration = EngineConfiguration(threadingModel: .direct, fuelMetering: true)
        let control = try ExecutionControl(pollingInterval: 7)
        let (controlled, controlledFuel) = try outcome(Store(engine: Engine(configuration: configuration), executionControl: control))
        let (plain, plainFuel) = try outcome(Store(engine: Engine(configuration: configuration)))
        #expect(controlledFuel == plainFuel)
        switch (controlled, plain) {
        case (.success(let a), .success(let b)):
            #expect(a == b)
            #expect(budget == 1_000_000)
        case (.failure(let a), .failure(let b)):
            #expect(a.reason.description == b.reason.description)
            #expect(a.reason.description == TrapReason.outOfFuel.description)
            #expect(budget == 500)
        default:
            Issue.record("controlled \(controlled) and uncontrolled \(plain) disagree")
        }
    }

    /// Frees a stopped store, its controller's claim, and its instances once the host drops them.
    ///
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test
    func aStoppedStoreIsReleased() throws {
        weak var released: Store?
        let control = try ExecutionControl()
        do {
            let store = try directStore(control)
            released = store
            let instance = try parseWasm(bytes: wat2wasm("(module (func (export \"spin\") (loop $again (br $again))))"))
                .instantiate(store: store)
            let spin = try #require(instance.exports[function: "spin"])
            control.requestInterruption()
            #expect(throws: ExecutionTermination.interrupted) { try spin() }
        }
        #expect(released == nil)
        #expect(throws: ExecutionControlError.reusedControl) { try directStore(control) }
    }

    #if WasmDebuggingSupport
        /// Refuses a debugger on a controlled direct store, whose debuggable code has no checkpoint.
        ///
        /// - Throws: Fixture construction or controller configuration failures.
        @Test
        func theDebuggerRefusesAControlledDirectStore() throws {
            let store = try directStore(ExecutionControl())
            let module = try parseWasm(bytes: wat2wasm("(module (func (export \"_start\")))"))
            #expect(throws: ExecutionControlError.unsupportedThreadingModel) {
                _ = try Debugger(module: module, store: store, imports: [:])
            }
        }
    #endif

    /// A value handed to a closure that may cross threads, where the test orders every access.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// The number of increments in the straight-line fixture, enough to outlast the watcher.
    private static let straightLineCount = 100_000

    /// Constructs a direct-threaded store with software bounds and all parser features.
    ///
    /// - Parameter control: The unclaimed signal bound to this store.
    /// - Returns: The store used for one fixture.
    /// - Throws: A reused controller.
    private func directStore(_ control: ExecutionControl) throws -> Store {
        try Store(
            engine: Engine(
                configuration: EngineConfiguration(
                    threadingModel: .direct, compilationMode: .eager, features: .all,
                    memoryBoundsChecking: .software
                )), executionControl: control)
    }

    /// Requests a stop as soon as the active guest has polled eight times.
    ///
    /// The watcher spins rather than sleeps, so it reacts within microseconds and the straight-line
    /// fixture cannot finish first.
    ///
    /// - Parameters:
    ///   - control: The controller with checkpoint recording enabled.
    ///   - reason: The terminal reason to request.
    ///   - body: The operation expected to remain active until the stop arrives.
    /// - Throws: The fixture operation's own failure.
    private func stopAfterProgress(
        _ control: ExecutionControl, reason: ExecutionTermination, body: () throws -> Void
    ) throws {
        let observed = Mutex(false)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while control.observedCheckpointCount < 8, ContinuousClock.now < deadline {}
            observed.withLock { $0 = control.observedCheckpointCount >= 8 }
            control.requestInterruption(reason: reason)
            completed.signal()
        }
        try body()
        #expect(completed.wait(timeout: .now() + 6) == .success)
        #expect(observed.withLock { $0 })
    }

    /// Terminates only this test process if a controlled direct store cannot be stopped.
    ///
    /// - Parameter body: The fixture expected to unwind before the watchdog expires.
    /// - Throws: The fixture operation's own failure.
    private func watchdog(_ body: () throws -> Void) rethrows {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler {
            FileHandle.standardError.write(Data("Direct control watchdog expired.\n".utf8))
            exit(124)
        }
        timer.resume()
        defer { timer.cancel() }
        try body()
    }
}
