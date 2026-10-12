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

    /// Counts the WebAssembly operators that fuel prices in a run of `export`, with fuel metering on
    /// an uncontrolled store.
    ///
    /// Fuel charges each region in advance, so this equals the priced operators executed only for
    /// code that runs every region to its end, which the bound fixtures below do. Control also
    /// counts the operators that fuel leaves free, so this is a lower bound of the operators the
    /// polling interval counts.
    private func operators(_ wasm: [UInt8], _ export: String, _ arguments: [Value]) throws -> UInt64 {
        let store = Store(
            engine: Engine(configuration: EngineConfiguration(threadingModel: .direct, features: .all, fuelMetering: true)))
        store.fuel = Fuel(remaining: 1 << 40)
        let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: store)
        let function = try #require(instance.exports[function: export])
        _ = try function(arguments)
        return (1 << 40) - (store.fuel?.remaining ?? 0)
    }

    /// The polls a run made, which are its checks less those of a run that never polls.
    private func polls(_ wasm: [UInt8], _ export: String, _ arguments: [Value], pollingInterval: UInt32) throws -> UInt64 {
        try checks(wasm, export, arguments, pollingInterval: pollingInterval)
            - checks(wasm, export, arguments, pollingInterval: .max)
    }

    /// Polls exactly once per polling interval of operators in straight-line code.
    ///
    /// A fresh store starts with a full budget, and every poll charges the segment it starts, so
    /// `n` operators split into segments of one interval poll `ceil(n / interval) - 1` times. The
    /// body runs 20,000 operators that fuel prices and the closing `end`, which only control counts.
    ///
    /// - Parameter pollingInterval: The operators between polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: [UInt32(16), 256])
    func straightLineCodePollsOncePerInterval(pollingInterval: UInt32) throws {
        let body = Array(repeating: "global.get 0 i32.const 1 i32.add global.set 0", count: 5_000).joined(separator: "\n")
        let wasm = try wat2wasm("(module (global (mut i32) (i32.const 0)) (func (export \"work\") \(body)))")
        #expect(try operators(wasm, "work", []) == 20_000)
        let counted: UInt64 = 20_000 + 1
        let interval = UInt64(pollingInterval)
        #expect(try polls(wasm, "work", [], pollingInterval: pollingInterval) == (counted + interval - 1) / interval - 1)
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
    /// branches, measured against the operators that fuel metering prices.
    ///
    /// With at most `interval` operators between two polls, `n` operators make at least
    /// `ceil(n / interval) - 1` polls. The operators that fuel prices are a subset of those that
    /// control counts, so their count gives a lower bound that does not depend on the translator.
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
        // The checks after the mark are the polls in the code that follows it, plus the fixed
        // checks of the import's return and of the invocation's completion.
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

    // MARK: - Operators that fuel leaves free

    /// `count` copies of `text`, separated by spaces.
    private static func repeated(_ text: String, _ count: Int) -> String {
        Array(repeating: text, count: count).joined(separator: " ")
    }

    /// Straight-line functions made mostly of operators that fuel leaves free.
    ///
    /// `nops` runs 4,000 `nop`s. `mixed` runs 1,000 groups of `nop`, `i32.const`, `drop` and
    /// `nop`, of which fuel prices only the constant. Both end with the closing `end`, which fuel
    /// leaves free too.
    private static let freeStraightLine = Result {
        try wat2wasm(
            """
            (module
                (func (export "nops") \(repeated("nop", 4_000)))
                (func (export "mixed") \(repeated("nop i32.const 7 drop nop", 1_000))))
            """)
    }

    /// Counts every `nop` and the other operators that fuel leaves free toward the polling
    /// interval, and keeps their fuel price at zero.
    ///
    /// The oracle counts the operators in the source. Control counts each one, so `n` of them in
    /// straight-line code poll `ceil(n / interval) - 1` times, as
    /// ``straightLineCodePollsOncePerInterval(pollingInterval:)`` explains. Fuel metering of the
    /// same code charges only the constants.
    ///
    /// - Parameters:
    ///   - export: `nops` or `mixed`.
    ///   - pollingInterval: The operators between polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["nops", "mixed"], [UInt32(16), 256])
    func freeOperatorsCountTowardTheInterval(export: String, pollingInterval: UInt32) throws {
        let wasm = try Self.freeStraightLine.get()
        let counted: UInt64 = export == "nops" ? 4_000 + 1 : 4 * 1_000 + 1
        let priced: UInt64 = export == "nops" ? 0 : 1_000
        #expect(try operators(wasm, export, []) == priced)
        let interval = UInt64(pollingInterval)
        #expect(try polls(wasm, export, [], pollingInterval: pollingInterval) == (counted + interval - 1) / interval - 1)
    }

    /// The operators of a counting loop's own increment and back-edge test, all priced by fuel.
    static let counter = """
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $next (i32.lt_u (local.get $i) (local.get $n)))
        """

    /// Loops whose bodies are mostly operators that fuel leaves free, with no host call in them.
    ///
    /// Each iteration also runs the eight operators of ``counter``. `nops` adds 1,000 `nop`s.
    /// `blocks` adds 250 blocks that each hold one `nop`, three operators apiece. `arms` adds 100
    /// `if`s whose arms each hold one `nop`. Either arm runs six operators. Three evaluate the
    /// condition, and then come the `if`, the `nop`, and the `else` or `end` that closes the arm.
    /// Fuel prices only the condition and the `if`.
    private static let freeLoops = Result {
        try wat2wasm(
            """
            (module
                (func (export "nops") (param $n i32) (local $i i32)
                    (loop $next \(repeated("nop", 1_000)) \(counter)))
                (func (export "blocks") (param $n i32) (local $i i32)
                    (loop $next \(repeated("(block nop)", 250)) \(counter)))
                (func (export "arms") (param $n i32) (local $i i32)
                    (loop $next \(repeated("(if (i32.and (local.get $i) (i32.const 1)) (then nop) (else nop))", 100)) \(counter))))
            """)
    }

    /// Polls in loops of operators that fuel leaves free at least once per interval of them, and
    /// keeps the fuel those loops consume.
    ///
    /// With at most `interval` operators between two polls, `n` operators make at least
    /// `ceil(n / interval) - 1` polls. The operators per iteration come from the source as
    /// ``freeLoops`` describes, and fuel prices exactly ``counter`` and the `if` conditions.
    ///
    /// - Parameter export: `nops`, `blocks`, or `arms`.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["nops", "blocks", "arms"])
    func freeOperatorsInLoopsPollWithinTheInterval(export: String) throws {
        let wasm = try Self.freeLoops.get()
        let iterations: UInt64 = 2_000
        let (perIteration, pricedPerIteration): (UInt64, UInt64) =
            switch export {
            case "nops": (1_000 + 8, 8)
            case "blocks": (250 * 3 + 8, 8)
            default: (100 * 6 + 8, 100 * 4 + 8)
            }
        let arguments = [Value.i32(UInt32(iterations))]
        #expect(try operators(wasm, export, arguments) == iterations * pricedPerIteration)
        let interval: UInt64 = 64
        let made = try polls(wasm, export, arguments, pollingInterval: UInt32(interval))
        let counted = iterations * perIteration
        #expect(made >= (counted + interval - 1) / interval - 1, "\(counted) operators, \(made) polls")
    }

    /// Ends a long run of `nop`s from another thread after the guest started it.
    ///
    /// The fixtures call no import, so only checkpoints inside the run can see the stop. The
    /// module is translated eagerly before the watcher starts, and the watcher waits for eight
    /// checks before it requests the stop. `straight` sets the `count` global only after its last
    /// `nop`, so it stays zero when a checkpoint inside the run saw the stop. `loop` never ends on
    /// its own.
    ///
    /// - Parameter shape: `straight` for 100,000 `nop`s in one body, `loop` for a loop of 1,000.
    /// - Throws: Fixture construction, export lookup, or controller configuration failures.
    @Test(arguments: ["straight", "loop"])
    func aStopEndsALongRunOfNops(shape: String) throws {
        let module = try shape == "loop" ? Self.nopLoopModule.get() : Self.nopStraightModule.get()
        try watchdog {
            let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
            let instance = try module.instantiate(store: directStore(control))
            let work = try #require(instance.exports[function: "work"])
            try stopAfterProgress(control, reason: .interrupted) {
                #expect(throws: ExecutionTermination.interrupted) { try work() }
            }
            #expect(instance.exports[global: "count"]?.value == .i32(0))
            #expect(control.termination == .interrupted)
        }
    }

    /// The fixtures of ``aStopEndsALongRunOfNops(shape:)``, parsed once per process.
    private static let nopLoopModule = Result { try fixture("(loop $again \(repeated("nop", 1_000)) (br $again))") }
    private static let nopStraightModule = Result {
        try fixture("\(repeated("nop", 100_000)) (global.set $count (i32.const 1))")
    }

    // MARK: - The largest gap between two polls

    /// Ten increments of a global or 40 `nop`s, either way 40 operators that the polling interval
    /// counts.
    private static func tail(_ kind: String) -> String {
        kind == "nops"
            ? repeated("nop", 40)
            : repeated("global.get $g i32.const 1 i32.add global.set $g", 10)
    }

    /// The operators of either ``tail(_:)``.
    private static let tailOperators: UInt64 = 40

    /// Loops whose body branches past a call to the end label of the frame that holds it.
    ///
    /// The call is never made. Its after-call checkpoint lies inside the frame, so only a
    /// checkpoint at the end label charges the code that follows. `sample` records the
    /// controller's count at the head of each iteration.
    private static func skipModule(_ kind: String) throws -> [UInt8] {
        try wat2wasm(
            """
            (module (import "host" "sample" (func $sample)) (import "host" "never" (func $never))
                (global $g (mut i32) (i32.const 0)) (tag $e)
                (func $thrower (throw $e))
                (func (export "block") (param $n i32) (param $skip i32) (local $i i32)
                    (loop $next
                        (call $sample)
                        (block $b
                            (br_if $b (local.get $skip))
                            (call $never))
                        \(tail(kind))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n)))))
                (func (export "table") (param $n i32) (param $skip i32) (local $i i32)
                    (loop $next
                        (call $sample)
                        (block $b
                            (block $c
                                (br_table $b $c (i32.sub (local.get $skip) (i32.const 1))))
                            (call $never))
                        \(tail(kind))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n)))))
                (func (export "catch") (param $n i32) (param $skip i32) (local $i i32)
                    (loop $next
                        (call $sample)
                        (block $landed
                            (try_table (catch_all $landed)
                                (call $thrower)))
                        \(tail(kind))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $n))))))
            """, features: .all)
    }

    /// The controller's count at the head of every iteration of `shape`.
    private func samples(_ wasm: [UInt8], _ shape: String, iterations: Int, pollingInterval: UInt32) throws -> [UInt64] {
        let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
        let store = try directStore(control)
        let samples = Box<[UInt64]>([])
        var imports = Imports()
        imports.define(
            module: "host", name: "sample",
            Function(store: store, parameters: []) { _, _ in
                samples.value.append(control.observedCheckpointCount)
                return []
            })
        imports.define(
            module: "host", name: "never",
            Function(store: store, parameters: []) { _, _ in
                Issue.record("The skipped call ran")
                return []
            })
        let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: store, imports: imports)
        let function = try #require(instance.exports[function: shape])
        _ = try function([.i32(UInt32(iterations)), .i32(1)])
        #expect(samples.value.count == iterations)
        return samples.value
    }

    /// Bounds the largest gap between two polls from below and checks it against the interval.
    ///
    /// Each iteration runs at least the 40 operators of its tail. A run of `m` iterations with no
    /// poll between their heads lies inside one gap, so that gap holds at least `40 m` operators.
    /// The checks that are not polls, such as import returns and caught exceptions, come from a run
    /// whose interval is never reached.
    ///
    /// The branch skips the call and with it the call's after-call checkpoint. Without a
    /// checkpoint at the end label, every iteration would run its tail uncharged, and the gap would
    /// grow with the iterations rather than stay within one segment.
    ///
    /// - Parameters:
    ///   - shape: How the body reaches the end label past the call.
    ///   - tail: `arithmetic` or `nops`, the operators that follow the end label.
    ///   - pollingInterval: The operators allowed between two polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["block", "table", "catch"], [("arithmetic", UInt32(64)), ("arithmetic", 1024), ("nops", 64), ("nops", 1024)])
    func theLargestGapStaysWithinTheInterval(shape: String, configuration: (tail: String, pollingInterval: UInt32)) throws {
        let wasm = try Self.skipModule(configuration.tail)
        let iterations = 4_000
        let measured = try samples(wasm, shape, iterations: iterations, pollingInterval: configuration.pollingInterval)
        let baseline = try samples(wasm, shape, iterations: iterations, pollingInterval: .max)
        var longest = 0
        var run = 0
        for index in 1..<iterations {
            let made = (measured[index] - measured[index - 1]) - (baseline[index] - baseline[index - 1])
            run = made == 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        let gapAtLeast = UInt64(longest) * Self.tailOperators
        #expect(gapAtLeast <= UInt64(configuration.pollingInterval), "a gap of at least \(gapAtLeast) operators")
    }

    // MARK: - Code after a merge label, after a poll

    /// Recursions whose frames run a tail after a merge label once their callee returns.
    ///
    /// The deepest frame calls `mark`. Every frame then reaches its tail through one kind of
    /// merge, which is the end of an `if`, a `br` or `br_table` to a block's end, a caught
    /// exception, or the end of a loop.
    private static func mergeModule(_ kind: String) throws -> [UInt8] {
        try wat2wasm(
            """
            (module (import "host" "mark" (func $mark)) (global $g (mut i32) (i32.const 0)) (tag $e)
                (func $if (export "if") (param $n i32)
                    (if (local.get $n)
                        (then (call $if (i32.sub (local.get $n) (i32.const 1))))
                        (else (call $mark)))
                    \(tail(kind)))
                (func $block (export "block") (param $n i32)
                    (block $out
                        (block $base
                            (br_if $base (i32.eqz (local.get $n)))
                            (call $block (i32.sub (local.get $n) (i32.const 1)))
                            (br $out))
                        (call $mark))
                    \(tail(kind)))
                (func $table (export "table") (param $n i32)
                    (block $out
                        (block $base
                            (br_if $base (i32.eqz (local.get $n)))
                            (call $table (i32.sub (local.get $n) (i32.const 1)))
                            (br_table $out $out (local.get $n)))
                        (call $mark))
                    \(tail(kind)))
                (func $catch (export "catch") (param $n i32)
                    (block $landed
                        (try_table (catch_all $landed)
                            (block $base
                                (br_if $base (i32.eqz (local.get $n)))
                                (call $catch (i32.sub (local.get $n) (i32.const 1)))
                                (throw $e))
                            (call $mark)
                            (throw $e)))
                    \(tail(kind)))
                (func $loop (export "loop") (param $n i32)
                    (if (i32.eqz (local.get $n)) (then (call $mark) (return)))
                    (loop $body
                        (call $loop (i32.sub (local.get $n) (i32.const 1))))
                    \(tail(kind))))
            """, features: .all)
    }

    /// The recursion depth of the merge fixtures.
    private static let depth = 40

    /// Runs `shape` and returns the checks counted after `mark` and the store's budget there.
    private func afterMark(_ wasm: [UInt8], _ shape: String, pollingInterval: UInt32) throws -> (checks: UInt64, budget: UInt64) {
        let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
        let store = try directStore(control)
        let marks = Box(0)
        let checks = Box<UInt64>(0)
        let budget = Box<UInt64>(0)
        var imports = Imports()
        imports.define(
            module: "host", name: "mark",
            Function(store: store, parameters: []) { caller, _ in
                marks.value += 1
                checks.value = control.observedCheckpointCount
                budget.value = caller.store.controlBudget.value
                return []
            })
        let instance = try parseWasm(bytes: wasm, features: .all).instantiate(store: store, imports: imports)
        let function = try #require(instance.exports[function: shape])
        _ = try function([.i32(UInt32(Self.depth))])
        #expect(marks.value == 1)
        return (control.observedCheckpointCount - checks.value, budget.value)
    }

    /// Charges the code after a merge label after the polls that precede it.
    ///
    /// Every operator after `mark` has to be charged after it. With `b` left in the budget at
    /// the mark and `k` polls after it, at most `b + k * interval` operators can be charged, so
    /// `R` operators after the mark need `k >= ceil((R - b) / interval)`. The fixtures run at
    /// least `depth * 40` operators after the mark. The `mark` import sits in the deepest frame, so
    /// its own after-call checkpoint lies on none of the merge labels under test.
    ///
    /// - Parameters:
    ///   - shape: The kind of merge.
    ///   - tail: `arithmetic` or `nops`, the operators that follow the merge label.
    ///   - pollingInterval: The operators allowed between two polls.
    /// - Throws: Fixture construction or invocation failures.
    @Test(
        arguments: ["if", "block", "table", "catch", "loop"],
        [("arithmetic", UInt32(16)), ("arithmetic", 64), ("nops", 16), ("nops", 64)])
    func codeAfterAMergeLabelIsChargedAfterIt(shape: String, configuration: (tail: String, pollingInterval: UInt32)) throws {
        let wasm = try Self.mergeModule(configuration.tail)
        let measured = try afterMark(wasm, shape, pollingInterval: configuration.pollingInterval)
        let baseline = try afterMark(wasm, shape, pollingInterval: .max)
        let polls = measured.checks - baseline.checks
        let interval = UInt64(configuration.pollingInterval)
        let after = UInt64(Self.depth) * Self.tailOperators
        let required = after > measured.budget ? (after - measured.budget + interval - 1) / interval : 0
        #expect(polls >= required, "\(polls) polls for \(after) operators after a budget of \(measured.budget)")
    }

    // MARK: - Memory bounds

    /// Runs the controller's main contract under each bounds strategy a direct engine accepts.
    ///
    /// An out-of-bounds trap, which mprotect raises through a signal, leaves the store live.
    /// Memory growth keeps the results of an uncontrolled store with the same strategy. A spin
    /// stops, the stop retires the store, and straight-line code polls exactly as often as it does
    /// with software bounds.
    ///
    /// - Parameter bounds: `software`, `mprotect`, or `default`. An engine that cannot back
    ///   mprotect bounds falls back to software, which the run prints.
    /// - Throws: Fixture construction or invocation failures.
    @Test(arguments: ["software", "mprotect", "default"])
    func controlWorksUnderEachBoundsStrategy(bounds: String) throws {
        let wasm = try wat2wasm(
            """
            (module (memory 1 64) (global $count (export "count") (mut i32) (i32.const 0))
                (func (export "oob") (result i32) (i32.load (i32.const 70000)))
                (func (export "grow") (param $pages i32) (result i32) (local $i i32) (local $acc i32)
                    (loop $next
                        (drop (memory.grow (i32.const 1)))
                        (i32.store (i32.mul (memory.size) (i32.const 65532)) (local.get $i))
                        (local.set $acc (i32.add (local.get $acc)
                            (i32.load (i32.mul (memory.size) (i32.const 65532)))))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br_if $next (i32.lt_u (local.get $i) (local.get $pages))))
                    (i32.add (local.get $acc) (memory.size)))
                (func (export "spin")
                    (loop $again (global.set $count (i32.add (global.get $count) (i32.const 1))) (br $again)))
                (func (export "answer") (result i32) i32.const 42))
            """)
        let requested: EngineConfiguration.MemoryBoundsChecking? =
            switch bounds {
            case "software": .software
            case "mprotect": .mprotect
            default: nil
            }
        let control = try ExecutionControl(pollingInterval: 64, recordsCheckpoints: true)
        let store = try directStore(control, bounds: requested)
        print("Direct control with \(bounds) bounds runs \(store.engine.configuration.memoryBoundsChecking) bounds")
        let instance = try parseWasm(bytes: wasm).instantiate(store: store)
        let oob = try #require(instance.exports[function: "oob"])
        let grow = try #require(instance.exports[function: "grow"])
        let spin = try #require(instance.exports[function: "spin"])
        let answer = try #require(instance.exports[function: "answer"])
        do {
            _ = try oob()
            Issue.record("The out-of-bounds load returned")
        } catch let trap as Trap {
            #expect(trap.reason.description == TrapReason.memoryOutOfBounds.description)
        }
        #expect(control.termination == nil)
        #expect(try answer() == [.i32(42)])

        let plain = try parseWasm(bytes: wasm).instantiate(
            store: Store(
                engine: Engine(
                    configuration: EngineConfiguration(threadingModel: .direct, memoryBoundsChecking: requested))))
        let plainGrow = try #require(plain.exports[function: "grow"])
        #expect(try grow([.i32(30)]) == plainGrow([.i32(30)]))

        try watchdog {
            try stopAfterProgress(control, reason: .interrupted) {
                #expect(throws: ExecutionTermination.interrupted) { try spin() }
            }
        }
        #expect(throws: ExecutionTermination.interrupted) { try answer() }
        #expect(throws: ExecutionTermination.interrupted) { try oob() }

        // 20,000 operators that fuel prices and the closing `end`, as in the straight-line check.
        let body = Array(repeating: "global.get 0 i32.const 1 i32.add global.set 0", count: 5_000).joined(separator: "\n")
        let straight = try wat2wasm("(module (global (mut i32) (i32.const 0)) (func (export \"work\") \(body)))")
        func checks(_ pollingInterval: UInt32) throws -> UInt64 {
            let control = try ExecutionControl(pollingInterval: pollingInterval, recordsCheckpoints: true)
            let instance = try parseWasm(bytes: straight).instantiate(store: directStore(control, bounds: requested))
            let work = try #require(instance.exports[function: "work"])
            _ = try work()
            return control.observedCheckpointCount
        }
        #expect(try checks(16) - checks(.max) == (20_001 + 15) / 16 - 1)
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

    /// Constructs a direct-threaded store with eager compilation and all parser features.
    ///
    /// - Parameters:
    ///   - control: The unclaimed signal bound to this store.
    ///   - bounds: The memory bounds strategy, nil for the platform default.
    /// - Returns: The store used for one fixture.
    /// - Throws: A reused controller.
    private func directStore(
        _ control: ExecutionControl, bounds: EngineConfiguration.MemoryBoundsChecking? = .software
    ) throws -> Store {
        try Store(
            engine: Engine(
                configuration: EngineConfiguration(
                    threadingModel: .direct, compilationMode: .eager, features: .all,
                    memoryBoundsChecking: bounds
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
