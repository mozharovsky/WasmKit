import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Pausing a guest at a host call and continuing the same invocation later.
///
/// Every test runs under both dispatch models, without the debugger. The host functions count
/// their own executions, so a test can tell a continued invocation from a replayed one.
@Suite
struct ResumableCallTests {
    /// The dispatch models every test runs under.
    static let threadingModels: [EngineConfiguration.ThreadingModel] = [.token, .direct]

    /// A module with its store and the host functions' records.
    final class Fixture {
        let store: Store
        let instance: Instance
        /// The arguments of each call to a host function, in call order, keyed by import name.
        var calls: [String: [[Value]]] = [:]

        /// Instantiates `wat` with host functions that either pause or compute synchronously.
        ///
        /// - Parameters:
        ///   - wat: The module.
        ///   - threadingModel: The dispatch model.
        ///   - features: The features the module needs.
        ///   - fuel: A fuel budget, which also enables fuel metering.
        ///   - memoryBoundsChecking: The bounds checking strategy, or nil for the platform's default.
        ///   - hosts: The host functions keyed by import name. Each receives the fixture and the
        ///     arguments and returns results, or throws ``HostCallSuspension`` to pause.
        init(
            _ wat: String,
            threadingModel: EngineConfiguration.ThreadingModel,
            features: WasmFeatureSet = .default,
            fuel: UInt64? = nil,
            memoryBoundsChecking: EngineConfiguration.MemoryBoundsChecking? = nil,
            hosts: [String: (Fixture, [Value]) throws -> [Value]]
        ) throws {
            let module = try parseWasm(bytes: wat2wasm(wat, features: features), features: features)
            let engine = Engine(
                configuration: EngineConfiguration(
                    threadingModel: threadingModel, features: features,
                    memoryBoundsChecking: memoryBoundsChecking, fuelMetering: fuel != nil))
            let store = Store(engine: engine)
            if let fuel { store.fuel = Fuel(remaining: fuel) }
            self.store = store
            var imports = Imports()
            var pending: [(Import, FunctionType, (Fixture, [Value]) throws -> [Value])] = []
            for entry in module.imports {
                guard case .function(let index) = entry.descriptor, let host = hosts[entry.name]
                else { continue }
                pending.append((entry, try module.resolveFunctionType(index), host))
            }
            // The host functions reach the fixture through this box, which is filled below.
            let box = FixtureBox()
            for (entry, type, host) in pending {
                let name = entry.name
                let function = Function(store: store, type: type) { _, arguments in
                    guard let fixture = box.fixture else { throw HostFailure() }
                    fixture.calls[name, default: []].append(arguments)
                    return try host(fixture, arguments)
                }
                imports.define(entry, .function(function))
            }
            instance = try module.instantiate(store: store, imports: imports)
            box.fixture = self
        }

        /// The exported function `name`.
        func export(_ name: String) throws -> Function {
            try #require(instance.exports[function: name])
        }

        /// The number of calls to the host function `name`.
        func count(_ name: String) -> Int { calls[name]?.count ?? 0 }
    }

    /// A late-bound reference from host closures to their fixture.
    final class FixtureBox {
        weak var fixture: Fixture?
    }

    /// A host failure that a test recognizes.
    struct HostFailure: Error, Equatable {}

    /// A host function that always pauses.
    static func pause(_: Fixture, _: [Value]) throws -> [Value] {
        throw HostCallSuspension(tag: 7)
    }

    /// A refused resume with the continuation it returned intact.
    struct Rejection: ~Copyable {
        let call: SuspendedCall
        let reason: ResumeRejection
    }

    /// Unwraps a pause.
    static func suspended(
        _ call: consuming ResumableCall, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SuspendedCall {
        switch consume call {
        case .suspended(let suspended): return suspended
        case .finished(let results):
            Issue.record("Expected a pause, finished with \(results)", sourceLocation: sourceLocation)
            throw HostFailure()
        }
    }

    /// Unwraps a pause after a resume.
    static func suspended(
        _ result: consuming ResumeResult, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SuspendedCall {
        switch consume result {
        case .suspended(let suspended): return suspended
        case .finished(let results):
            Issue.record("Expected a pause, finished with \(results)", sourceLocation: sourceLocation)
            throw HostFailure()
        case .rejected(_, let rejection):
            Issue.record("Expected a pause, rejected with \(rejection)", sourceLocation: sourceLocation)
            throw HostFailure()
        }
    }

    /// Unwraps finished results after a resume.
    static func finished(
        _ result: consuming ResumeResult, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [Value] {
        switch consume result {
        case .finished(let results): return results
        case .suspended(let suspended):
            Issue.record("Expected results, paused at \(suspended.arguments)", sourceLocation: sourceLocation)
            throw HostFailure()
        case .rejected(_, let rejection):
            Issue.record("Expected results, rejected with \(rejection)", sourceLocation: sourceLocation)
            throw HostFailure()
        }
    }

    /// Unwraps a refusal after a resume and returns the intact continuation.
    static func rejected(
        _ result: consuming ResumeResult, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Rejection {
        switch consume result {
        case .rejected(let suspended, let rejection): return Rejection(call: suspended, reason: rejection)
        case .finished(let results):
            Issue.record("Expected a refusal, finished with \(results)", sourceLocation: sourceLocation)
            throw HostFailure()
        case .suspended(let suspended):
            Issue.record("Expected a refusal, paused at \(suspended.arguments)", sourceLocation: sourceLocation)
            throw HostFailure()
        }
    }

    // MARK: - Guest state across pauses

    /// Nested frames with locals, two pauses, and synchronous side effects on both sides.
    static let nested = """
        (module
          (import "env" "pause" (func $pause (param i32) (result i32)))
          (import "env" "effect" (func $effect (param i32)))
          (global $writes (mut i32) (i32.const 0))
          (func $inner (param $x i32) (result i32)
            (local $a i32) (local $b i32)
            (local.set $a (i32.mul (local.get $x) (i32.const 10)))
            (call $effect (i32.const 1))
            (global.set $writes (i32.add (global.get $writes) (i32.const 1)))
            (local.set $b (call $pause (local.get $a)))
            (call $effect (i32.const 2))
            (local.set $b
              (i32.add (local.get $b) (call $pause (i32.add (local.get $a) (local.get $b)))))
            (global.set $writes (i32.add (global.get $writes) (i32.const 1)))
            (i32.add (local.get $a) (local.get $b)))
          (func (export "run") (param $x i32) (result i32)
            (local $keep i32)
            (local.set $keep (i32.add (local.get $x) (i32.const 1000)))
            (i32.add (local.get $keep) (call $inner (local.get $x))))
          (func (export "writes") (result i32) (global.get $writes)))
        """

    /// The host's answer to the first pause of ``nested``.
    static func firstAnswer(_ argument: Int32) -> Int32 { argument + 5 }
    /// The host's answer to the second pause of ``nested``.
    static func secondAnswer(_ argument: Int32) -> Int32 { argument * 2 }

    /// Runs ``nested`` synchronously with the same answers, as the reference result.
    static func nestedReference(_ x: Int32, threadingModel: EngineConfiguration.ThreadingModel) throws -> Int32 {
        var answered = 0
        let fixture = try Fixture(
            nested, threadingModel: threadingModel,
            hosts: [
                "pause": { _, arguments in
                    answered += 1
                    let argument = Int32(bitPattern: arguments[0].i32)
                    let answer = answered == 1 ? firstAnswer(argument) : secondAnswer(argument)
                    return [.i32(UInt32(bitPattern: answer))]
                },
                "effect": { _, _ in [] },
            ])
        let results = try fixture.export("run")([.i32(3)])
        return Int32(bitPattern: results[0].i32)
    }

    @Test(arguments: threadingModels)
    func nestedFramesAndLocalsSurviveTwoPauses(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.nested, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "effect": { _, _ in [] }])
        let first = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
        #expect(first.tag == 7)
        #expect(first.arguments == [.i32(30)])
        #expect(first.resultTypes == [.i32])
        #expect(fixture.calls["effect"] == [[.i32(1)]])
        let firstID = first.id
        let second = try Self.suspended(
            try first.resume(returning: [.i32(35)], in: fixture.store))
        #expect(second.arguments == [.i32(65)])
        #expect(second.id != firstID)
        let results = try Self.finished(
            try second.resume(returning: [.i32(130)], in: fixture.store))
        #expect(results == [.i32(1198)])
        #expect(try Int32(bitPattern: results[0].i32) == Self.nestedReference(3, threadingModel: threadingModel))
        // Each step ran once: two effects, two pauses, and two global writes.
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(2)]])
        #expect(fixture.count("pause") == 2)
        #expect(try fixture.export("writes")() == [.i32(2)])
    }

    // MARK: - Result shapes

    static let shapes = """
        (module
          (import "env" "wait" (func $wait))
          (import "env" "triple" (func $triple (param i32) (result i32 i64 f64)))
          (func (export "void") (result i32) (call $wait) (i32.const 7))
          (func (export "multi") (param i32) (result f64)
            (local $a i32) (local $b i64) (local $c f64)
            (call $triple (local.get 0))
            (local.set $c) (local.set $b) (local.set $a)
            (f64.add
              (f64.add (f64.convert_i32_s (local.get $a)) (f64.convert_i64_s (local.get $b)))
              (local.get $c))))
        """

    @Test(arguments: threadingModels)
    func voidAndMultipleResults(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.shapes, threadingModel: threadingModel,
            hosts: ["wait": Self.pause, "triple": Self.pause])
        let wait = try Self.suspended(try fixture.export("void").invokeResumable())
        #expect(wait.resultTypes.isEmpty)
        #expect(try Self.finished(try wait.resume(returning: [], in: fixture.store)) == [.i32(7)])

        let triple = try Self.suspended(try fixture.export("multi").invokeResumable([.i32(4)]))
        #expect(triple.resultTypes == [.i32, .i64, .f64])
        let results = try Self.finished(
            try triple.resume(
                returning: [.i32(1), .i64(20), .f64(Double(0.5).bitPattern)], in: fixture.store))
        #expect(results == [.f64(Double(21.5).bitPattern)])
    }

    @Test(arguments: threadingModels)
    func invalidResultsAreRefusedBeforeTheGuestRuns(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.shapes, threadingModel: threadingModel,
            hosts: ["wait": Self.pause, "triple": Self.pause])
        let triple = try Self.suspended(try fixture.export("multi").invokeResumable([.i32(4)]))
        let id = triple.id
        let afterCount = try Self.rejected(
            try triple.resume(returning: [.i32(1)], completing: id, in: fixture.store))
        #expect(afterCount.reason == .resultCount(expected: 3, actual: 1))
        let afterType = try Self.rejected(
            try afterCount.call.resume(
                returning: [.i32(1), .i32(2), .f64(Double(0).bitPattern)], completing: id, in: fixture.store))
        #expect(afterType.reason == .resultType(index: 1, expected: .i64))
        // The same pause resumes once the results are right.
        let results = try Self.finished(
            try afterType.call.resume(
                returning: [.i32(1), .i64(2), .f64(Double(3).bitPattern)], completing: id, in: fixture.store))
        #expect(results == [.f64(Double(6).bitPattern)])
    }

    // MARK: - Traps and host failures

    static let failures = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (import "env" "fail" (func $fail (result i32)))
          (func (export "trap_after") (drop (call $pause)) (drop (call $pause)) unreachable)
          (func (export "fail_after") (result i32) (drop (call $pause)) (call $pause))
          (func (export "sync_fail") (result i32) (drop (call $pause)) (call $fail)))
        """

    @Test(arguments: threadingModels)
    func guestTrapAfterEarlierPauses(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.failures, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "fail": { _, _ in throw HostFailure() }])
        let first = try Self.suspended(try fixture.export("trap_after").invokeResumable())
        let second = try Self.suspended(
            try first.resume(returning: [.i32(0)], in: fixture.store))
        do {
            _ = try second.resume(returning: [.i32(0)], in: fixture.store)
            Issue.record("The guest did not trap.")
        } catch let trap as Trap {
            guard case .unreachable = trap.reason else {
                Issue.record("Unexpected trap \(trap)")
                return
            }
            #expect(trap.backtrace != nil)
        }
    }

    @Test(arguments: threadingModels)
    func hostFailuresEndTheInvocationAfterAPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.failures, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "fail": { _, _ in throw HostFailure() }])
        // A failure reported through resume.
        let first = try Self.suspended(try fixture.export("fail_after").invokeResumable())
        let second = try Self.suspended(
            try first.resume(returning: [.i32(0)], in: fixture.store))
        do {
            _ = try second.resume(throwing: HostFailure(), in: fixture.store)
            Issue.record("The host failure did not end the invocation.")
        } catch is HostFailure {}
        // A synchronous host failure after an earlier pause.
        let paused = try Self.suspended(try fixture.export("sync_fail").invokeResumable())
        do {
            _ = try paused.resume(returning: [.i32(0)], in: fixture.store)
            Issue.record("The synchronous host failure did not end the invocation.")
        } catch is HostFailure {}
    }

    @Test(arguments: threadingModels)
    func synchronousInvocationRefusesAPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.failures, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "fail": { _, _ in throw HostFailure() }])
        #expect(throws: ResumableCallError.suspensionUnavailable) {
            _ = try fixture.export("fail_after")()
        }
        #expect(fixture.count("pause") == 1)
    }

    // MARK: - Ownership, cancellation, and late completions

    @Test(arguments: threadingModels)
    func cancelAndDropReleaseTheInvocation(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.nested, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "effect": { _, _ in [] }])
        weak var cancelled: ResumableExecutionState?
        do {
            let paused = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
            cancelled = paused.state
            #expect(cancelled != nil)
            paused.cancel()
        }
        #expect(cancelled == nil)
        weak var dropped: ResumableExecutionState?
        do {
            let paused = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
            dropped = paused.state
            _ = consume paused
        }
        #expect(dropped == nil)
        // Neither invocation continued past its first pause.
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(1)]])
        #expect(try fixture.export("writes")() == [.i32(2)])
    }

    @Test(arguments: threadingModels)
    func aLateCompletionCannotResumeAnotherPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.nested, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "effect": { _, _ in [] }])
        let cancelled = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
        let lateID = cancelled.id
        cancelled.cancel()

        let current = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
        // The cancelled invocation's result arrives late and is refused.
        let late = try Self.rejected(
            try current.resume(returning: [.i32(999)], completing: lateID, in: fixture.store))
        #expect(late.reason == .staleSuspension)
        // A completion of an earlier pause of the same invocation is refused too.
        let intact = late.call
        let firstID = intact.id
        let second = try Self.suspended(
            try intact.resume(returning: [.i32(35)], completing: firstID, in: fixture.store))
        let stale = try Self.rejected(
            try second.resume(returning: [.i32(130)], completing: firstID, in: fixture.store))
        #expect(stale.reason == .staleSuspension)
        let stillIntact = stale.call
        let results = try Self.finished(
            try stillIntact.resume(returning: [.i32(130)], in: fixture.store))
        #expect(results == [.i32(1198)])
        #expect(fixture.calls["effect"] == [[.i32(1)], [.i32(1)], [.i32(2)]])
    }

    @Test(arguments: threadingModels)
    func aForeignStoreIsRefused(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let hosts: [String: (Fixture, [Value]) throws -> [Value]] = [
            "pause": Self.pause, "effect": { _, _ in [] },
        ]
        let paused = try Fixture(Self.nested, threadingModel: threadingModel, hosts: hosts)
        let other = try Fixture(Self.nested, threadingModel: threadingModel, hosts: hosts)
        let first = try Self.suspended(try paused.export("run").invokeResumable([.i32(3)]))
        let id = first.id
        let foreign = try Self.rejected(
            try first.resume(returning: [.i32(35)], completing: id, in: other.store))
        #expect(foreign.reason == .foreignStore)
        _ = try Self.suspended(try foreign.call.resume(returning: [.i32(35)], completing: id, in: paused.store))
    }

    @Test(arguments: threadingModels)
    func independentWorkWhileAnInvocationIsPaused(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let answering: [String: (Fixture, [Value]) throws -> [Value]] = [
            "pause": { _, arguments in [.i32(arguments[0].i32 &+ 5)] }, "effect": { _, _ in [] },
        ]
        let paused = try Fixture(
            Self.nested, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "effect": { _, _ in [] }])
        let independent = try Fixture(Self.nested, threadingModel: threadingModel, hosts: answering)
        let first = try Self.suspended(try paused.export("run").invokeResumable([.i32(3)]))
        // Another store runs a whole invocation.
        _ = try independent.export("run")([.i32(2)])
        // The paused store runs another export synchronously on its own stack.
        #expect(try paused.export("writes")() == [.i32(1)])
        let second = try Self.suspended(
            try first.resume(returning: [.i32(35)], in: paused.store))
        #expect(
            try Self.finished(try second.resume(returning: [.i32(130)], in: paused.store))
                == [.i32(1198)])
    }

    @Test(arguments: threadingModels)
    func repeatedCyclesReleaseEveryInvocation(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.nested, threadingModel: threadingModel,
            hosts: ["pause": Self.pause, "effect": { _, _ in [] }])
        var states: [() -> ResumableExecutionState?] = []
        for round in 0..<60 {
            let first = try Self.suspended(try fixture.export("run").invokeResumable([.i32(3)]))
            weak let state = first.state
            states.append { state }
            switch round % 3 {
            case 0:
                let second = try Self.suspended(
                    try first.resume(returning: [.i32(35)], in: fixture.store))
                let results = try Self.finished(
                    try second.resume(returning: [.i32(130)], in: fixture.store))
                #expect(results == [.i32(1198)])
            case 1:
                do {
                    _ = try first.resume(throwing: HostFailure(), in: fixture.store)
                    Issue.record("The host failure did not end the invocation.")
                } catch is HostFailure {}
            default:
                first.cancel()
            }
        }
        #expect(states.allSatisfy { $0() == nil })
        #expect(fixture.store.resumableStackEnd == nil)
    }
}
