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
        // Built before the watchdog starts, because a sanitizer makes the long module slow to build.
        let module = try shape == "loop" ? Self.loopModule.get() : Self.straightLineModule.get()
        try watchdog {
            let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
            let store = try directStore(control)
            let instance = try module.instantiate(store: store)
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
                for _ in 0..<20 {
                    results.value.append((try? neighbourSum.value([.i32(20_000)])) ?? [])
                }
                done.signal()
            }
            try stopAfterProgress(stopped, reason: .interrupted) {
                #expect(throws: ExecutionTermination.interrupted) { try spin() }
            }
            // A store runs on one thread at a time, so the neighbour is used again only after the
            // worker is done with it. A sanitizer makes the worker several times slower.
            guard done.wait(timeout: .now() + 90) == .success else {
                Issue.record("The neighbouring store did not finish its calls")
                return
            }
            let expected = try plainSum([.i32(20_000)])
            #expect(results.value.count == 20)
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

    // MARK: - The polling bound

    /// Runs `export` once on a fresh controlled direct store and returns how many times the
    /// controller was checked.
    private func checks(_ wasm: [UInt8], _ export: String, _ arguments: [Value], pollingInterval: UInt32) throws -> UInt64 {
        let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
        let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: directStore(control))
        let function = try #require(instance.exports[function: export])
        _ = try function(arguments)
        return control.observedCheckpointCount
    }

    /// Counts the WebAssembly operators `export` runs, with fuel metering on an uncontrolled store.
    ///
    /// Fuel charges each region in advance, so this equals the operators executed only for code
    /// that runs every region to its end, which the bound fixtures below do.
    private func operators(_ wasm: [UInt8], _ export: String, _ arguments: [Value]) throws -> UInt64 {
        let store = Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: .direct, features: .all, fuelMetering: true)))
        store.fuel = Fuel(remaining: 1 << 40)
        let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: store)
        let function = try #require(instance.exports[function: export])
        _ = try function(arguments)
        return (1 << 40) - (store.fuel?.remaining ?? 0)
    }

    /// The polls a run made: its checks less those of a run that never polls.
    private func polls(_ wasm: [UInt8], _ export: String, _ arguments: [Value], pollingInterval: UInt32) throws -> UInt64 {
        try checks(wasm, export, arguments, pollingInterval: pollingInterval)
            - checks(wasm, export, arguments, pollingInterval: .max)
    }

    /// Polls exactly once per polling interval of operators in straight-line code.
    ///
    /// A fresh store starts with a full budget, and every poll charges the segment it starts, so
    /// `n` operators split into segments of one interval poll `ceil(n / interval) - 1` times.
    ///
    /// - Parameter pollingInterval: The operators between polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: [UInt32(16), 256])
    func straightLineCodePollsOncePerInterval(pollingInterval: UInt32) throws {
        let body = Array(repeating: "global.get 0 i32.const 1 i32.add global.set 0", count: 5_000).joined(separator: "\n")
        let wasm = try wat2wasm("(module (global (mut i32) (i32.const 0)) (func (export \"work\") \(body)))")
        let executed = try operators(wasm, "work", [])
        #expect(executed == 20_000)
        let interval = UInt64(pollingInterval)
        #expect(try polls(wasm, "work", [], pollingInterval: pollingInterval) == (executed + interval - 1) / interval - 1)
    }

    /// Fixtures for the bound that run every region they enter to its end, so fuel counts exactly
    /// the operators they execute.
    private static let boundFixtures = Result {
        try wat2wasm(
            """
            (module (global $g (mut i32) (i32.const 0))
                (func $leaf (param $x i32) (result i32)
                    (i32.add (i32.mul (local.get $x) (i32.const 3)) (global.get $g)))
                (func (export "loop") (param $n i32) (local $i i32)
                    (loop $next
                        (global.set $g (i32.add (global.get $g) (local.get $i)))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n)))))
                (func (export "calls") (param $n i32) (local $i i32)
                    (loop $next
                        (global.set $g (call $leaf (local.get $i)))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n)))))
                (func $recurse (export "recurse") (param $n i32)
                    (if (local.get $n)
                        (then
                            (global.set $g (i32.add (global.get $g) (i32.const 1)))
                            (call $recurse (i32.sub (local.get $n) (i32.const 1)))
                            (global.set $g (i32.add (global.get $g) (i32.const 2))))
                        (else (global.set $g (i32.add (global.get $g) (i32.const 5))))))
                (func (export "branches") (param $n i32) (local $i i32)
                    (loop $next
                        (if (i32.and (local.get $i) (i32.const 1))
                            (then (global.set $g (i32.add (global.get $g) (i32.const 1))))
                            (else (global.set $g (i32.sub (global.get $g) (i32.const 1)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n))))))
            """)
    }

    /// Polls at least once per polling interval of operators in loops, calls, recursion, and
    /// branches, measured against the operators that fuel metering counts.
    ///
    /// With at most `interval` operators between two polls, `n` operators make at least
    /// `ceil(n / interval) - 1` polls.
    ///
    /// - Parameters:
    ///   - export: The fixture.
    ///   - pollingInterval: The operators between polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["loop", "calls", "recurse", "branches"], [UInt32(16), 97, 1024])
    func everyShapePollsWithinTheInterval(export: String, pollingInterval: UInt32) throws {
        let wasm = try Self.boundFixtures.get()
        let arguments = [Value.i32(export == "recurse" ? 400 : 3_000)]
        let executed = try operators(wasm, export, arguments)
        let interval = UInt64(pollingInterval)
        let made = try polls(wasm, export, arguments, pollingInterval: pollingInterval)
        #expect(made >= (executed + interval - 1) / interval - 1, "\(executed) operators, \(made) polls")
    }

    /// Polls in code that runs after a callee or a loop has already polled.
    ///
    /// A `mark` import records the controller's count. The code after it was translated before
    /// the polls that precede it, so it polls only if returns and loop ends start new segments.
    ///
    /// - Parameter shape: `unwind` returns through 60 frames that each run 200 operators after
    ///   the recursive call. `continuation` runs 800 operators after a loop ends.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["unwind", "continuation"])
    func codeAfterAPollStillPolls(shape: String) throws {
        let work = Array(repeating: "global.get $g i32.const 1 i32.add global.set $g", count: 50).joined(separator: "\n")
        let tail = Array(repeating: "global.get $g i32.const 1 i32.add global.set $g", count: 200).joined(separator: "\n")
        let wasm = try wat2wasm(
            """
            (module (import "host" "mark" (func $mark)) (global $g (mut i32) (i32.const 0))
                (func $down (export "unwind") (param $n i32)
                    (if (local.get $n)
                        (then (call $down (i32.sub (local.get $n) (i32.const 1))) \(work))
                        (else (call $mark))))
                (func (export "continuation") (param $n i32) (local $i i32)
                    (loop $next
                        (if (i32.eq (local.get $i) (i32.sub (local.get $n) (i32.const 1))) (then (call $mark)))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n))))
                    \(tail)))
            """)
        // The checks after the mark: the polls in the code that follows it, plus the fixed checks
        // of the import's return and of the invocation's completion.
        func checksAfterMark(_ pollingInterval: UInt32) throws -> UInt64 {
            let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
            let store = try directStore(control)
            let marked = Box<UInt64>(0)
            var imports = Imports()
            imports.define(
                module: "host", name: "mark",
                Function(store: store, parameters: []) { _, _ in
                    marked.value = control.observedCheckpointCount
                    return []
                })
            let instance = try parseWasm(bytes: wasm).instantiate(store: store, imports: imports)
            let function = try #require(instance.exports[function: shape])
            _ = try function([.i32(60)])
            return control.observedCheckpointCount - marked.value
        }
        let after = try checksAfterMark(16) - checksAfterMark(.max)
        // 60 frames of 200 operators, or 800 operators, at most 16 apart between polls.
        let operatorsAfter: UInt64 = shape == "unwind" ? 60 * 200 : 800
        #expect(after >= operatorsAfter / 16 - 1, "\(after) polls after the mark")
    }

    #if WasmDebuggingSupport
        /// A module whose start function calls the `host.started` import, with an `answer` export.
        private static let startModule = Result {
            try parseWasm(
                bytes: wat2wasm(
                    """
                    (module (import "host" "started" (func $started))
                        (func $start (call $started)) (start $start)
                        (func (export "_start"))
                        (func (export "answer") (result i32) i32.const 42))
                    """))
        }

        /// The imports of ``startModule``, whose `started` import counts its calls in `starts`.
        private func startImports(_ store: Store, _ starts: Box<Int>) -> Imports {
            var imports = Imports()
            imports.define(
                module: "host", name: "started",
                Function(store: store, parameters: []) { _, _ in
                    starts.value += 1
                    return []
                })
            return imports
        }

        /// Refuses a debuggable instance and a debugger on a controlled direct store before the start
        /// function runs, and leaves the store and its controller usable.
        ///
        /// Debuggable code is translated without checkpoints, so either path would otherwise run the
        /// guest without polling the controller.
        ///
        /// - Parameter path: `instance` for the public debuggable instantiation, `debugger` for the
        ///   debugger.
        /// - Throws: Fixture construction or invocation failures.
        @Test(arguments: ["instance", "debugger"])
        func debuggableCodeIsRefusedBeforeItRuns(path: String) throws {
            let control = try ExecutionControl()
            let store = try directStore(control)
            let starts = Box(0)
            let module = try Self.startModule.get()
            let imports = startImports(store, starts)
            #expect(throws: ExecutionControlError.unsupportedThreadingModel) {
                if path == "instance" {
                    _ = try module.instantiate(store: store, imports: imports, isDebuggable: true)
                } else {
                    _ = try Debugger(module: module, store: store, imports: imports)
                }
            }
            #expect(starts.value == 0)
            #expect(control.termination == nil)
            let instance = try module.instantiate(store: store, imports: imports)
            #expect(starts.value == 1)
            let answer = try #require(instance.exports[function: "answer"])
            #expect(try answer() == [.i32(42)])
        }

        /// A loop that counts to its argument and records how far it got.
        private static let countModule = Result {
            try parseWasm(
                bytes: wat2wasm(
                    """
                    (module (global $done (export "done") (mut i32) (i32.const 0))
                        (func (export "_start"))
                        (func (export "count") (param $n i32) (local $i i32)
                            (loop $next
                                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                                (br_if $next (i32.lt_u (local.get $i) (local.get $n))))
                            (global.set $done (local.get $i))))
                    """))
        }

        /// Keeps debuggable instances on an uncontrolled direct store and on a controlled token store,
        /// and keeps a stop reaching the latter's loop.
        ///
        /// - Throws: Fixture construction or invocation failures.
        @Test
        func otherDebuggableStoresKeepTheirBehaviour() throws {
            let module = try Self.countModule.get()
            let plain = try module.instantiate(
                store: Store(engine: Engine(configuration: EngineConfiguration(threadingModel: .direct))),
                isDebuggable: true)
            let plainCount = try #require(plain.exports[function: "count"])
            _ = try plainCount([.i32(1_000)])
            #expect(plain.exports[global: "done"]?.value == .i32(1_000))

            let control = try ExecutionControl(recordsCheckpoints: true)
            let store = try Store(
                engine: Engine(configuration: EngineConfiguration(threadingModel: .token, memoryBoundsChecking: .software)),
                executionControl: control)
            let token = try module.instantiate(store: store, isDebuggable: true)
            let count = try #require(token.exports[function: "count"])
            try stopAfterProgress(control, reason: .interrupted) {
                #expect(throws: ExecutionTermination.interrupted) { try count([.i32(UInt32.max)]) }
            }
            #expect(token.exports[global: "done"]?.value == .i32(0))

            var debugger = try Debugger(
                module: module,
                store: Store(
                    engine: Engine(configuration: EngineConfiguration(threadingModel: .token)),
                    executionControl: ExecutionControl()),
                imports: [:])
            try debugger.run()
        }
    #endif

    /// A value handed to a closure that may cross threads, where the test orders every access.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// The number of increments in the straight-line fixture, enough to outlast the watcher.
    private static let straightLineCount = 100_000

    /// The fixtures of ``aStopEndsGuestCode(shape:reason:)``, parsed once per process.
    private static let loopModule = Result { try fixture("(loop $again global.get 0 i32.const 1 i32.add global.set 0 (br $again))") }
    private static let straightLineModule = Result {
        try fixture(Array(repeating: "global.get 0 i32.const 1 i32.add global.set 0", count: straightLineCount).joined(separator: "\n"))
    }

    /// A module whose `work` export runs `body`, with a `count` global and an `answer` export.
    private static func fixture(_ body: String) throws -> Module {
        try parseWasm(
            bytes: wat2wasm(
                """
                (module (global $count (export "count") (mut i32) (i32.const 0))
                    (func (export "work") \(body))
                    (func (export "answer") (result i32) i32.const 42))
                """))
    }

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
        // Generous, because the sanitizer jobs run these fixtures several times slower.
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler {
            FileHandle.standardError.write(Data("Direct control watchdog expired.\n".utf8))
            exit(124)
        }
        timer.resume()
        defer { timer.cancel() }
        try body()
    }
}
