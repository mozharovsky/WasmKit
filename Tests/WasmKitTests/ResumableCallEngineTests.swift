import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Pauses that meet other parts of the engine: exceptions, tail calls, memory, reentry and fuel.
@Suite
struct ResumableCallEngineTests {
    typealias Fixture = ResumableCallTests.Fixture

    // MARK: - Exceptions

    static let exceptions = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (tag $t (param i32))
          (func (export "caught") (result i32)
            (block $h (result i32)
              (try_table (result i32) (catch $t $h)
                (throw $t (i32.add (call $pause) (i32.const 1))))))
          (func $inner (result i32) (throw $t (i32.mul (call $pause) (i32.const 3))))
          (func (export "outer") (result i32)
            (block $h (result i32)
              (try_table (result i32) (catch $t $h) (call $inner)))))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func exceptionHandlersSurviveAPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.exceptions, threadingModel: threadingModel, features: [.exceptionHandling],
            hosts: ["pause": ResumableCallTests.pause])
        let caught = try ResumableCallTests.suspended(try fixture.export("caught").invokeResumable())
        #expect(
            try ResumableCallTests.finished(try caught.resume(returning: [.i32(41)], in: fixture.store))
                == [.i32(42)])
        // The handler belongs to the caller's frame and the pause happens in the callee.
        let outer = try ResumableCallTests.suspended(try fixture.export("outer").invokeResumable())
        #expect(
            try ResumableCallTests.finished(try outer.resume(returning: [.i32(5)], in: fixture.store))
                == [.i32(15)])
    }

    static let deliveredFailures = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (tag $t (param i32))
          (func (export "raise") (param i32) (throw $t (local.get 0)))
          (func (export "trap") (unreachable))
          (func (export "guarded") (result i32)
            (block $h (result i32)
              (try_table (result i32) (catch $t $h)
                (i32.add (call $pause) (i32.const 1000)))))
          (func (export "unguarded") (result i32) (call $pause)))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func aResumeDeliversAGuestExceptionOrATrap(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.deliveredFailures, threadingModel: threadingModel, features: [.exceptionHandling],
            hosts: ["pause": ResumableCallTests.pause])
        // The embedder receives the guest's exception and trap from synchronous calls.
        var exception: WasmKitException?
        do { _ = try fixture.export("raise")([.i32(77)]) } catch let error as WasmKitException { exception = error }
        var trap: Trap?
        do { _ = try fixture.export("trap")() } catch let error as Trap { trap = error }
        let raised = try #require(exception)

        // A handler in the paused frame receives the payload, and the addition after the call
        // never runs.
        let guarded = try ResumableCallTests.suspended(try fixture.export("guarded").invokeResumable())
        #expect(
            try ResumableCallTests.finished(try guarded.resume(throwing: raised, in: fixture.store)) == [.i32(77)])

        // Without a handler the exception ends the invocation, and so does a trap.
        let unguarded = try ResumableCallTests.suspended(try fixture.export("unguarded").invokeResumable())
        do {
            _ = try unguarded.resume(throwing: raised, in: fixture.store)
            Issue.record("The exception did not end the invocation.")
        } catch is WasmKitException {}
        let trapped = try ResumableCallTests.suspended(try fixture.export("unguarded").invokeResumable())
        do {
            _ = try trapped.resume(throwing: try #require(trap), in: fixture.store)
            Issue.record("The trap did not end the invocation.")
        } catch let error as Trap {
            guard case .unreachable = error.reason else {
                Issue.record("Unexpected trap \(error)")
                return
            }
        }
        #expect(fixture.store.resumableStackEnd == nil)
    }

    /// A guest whose paused call sits in a `try_table` with a tagged clause before a `catch_all`.
    ///
    /// `ordered` returns the payload when the tagged clause catches and -1 when `catch_all` does.
    /// `exited` pauses again after the catch, outside the `try_table`.
    static let catchClauses = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (tag $t (param i32))
          (func (export "raise") (param i32) (throw $t (local.get 0)))
          (func (export "ordered") (result i32)
            (block $all
              (block $first (result i32)
                (try_table (result i32) (catch $t $first) (catch_all $all)
                  (call $pause)))
              (return))
            (i32.const -1))
          (func (export "exited") (result i32)
            (block $all
              (block $first (result i32)
                (try_table (result i32) (catch $t $first) (catch_all $all)
                  (call $pause)))
              (drop)
              (return (call $pause)))
            (i32.const -1)))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func aDeliveredExceptionFollowsTheCatchClauses(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.catchClauses, threadingModel: threadingModel, features: [.exceptionHandling],
            hosts: ["pause": ResumableCallTests.pause])
        var exception: WasmKitException?
        do { _ = try fixture.export("raise")([.i32(77)]) } catch let error as WasmKitException { exception = error }
        let raised = try #require(exception)

        // The clauses are tried in source order, so the tagged clause catches before catch_all.
        let ordered = try ResumableCallTests.suspended(try fixture.export("ordered").invokeResumable())
        #expect(try ResumableCallTests.finished(try ordered.resume(throwing: raised, in: fixture.store)) == [.i32(77)])

        // A catch exits the whole try_table, so its catch_all no longer handles a later exception.
        let first = try ResumableCallTests.suspended(try fixture.export("exited").invokeResumable())
        let second = try ResumableCallTests.suspended(try first.resume(throwing: raised, in: fixture.store))
        do {
            let results = try ResumableCallTests.finished(try second.resume(throwing: raised, in: fixture.store))
            Issue.record("An exited try_table caught the exception and returned \(results).")
        } catch is WasmKitException {}
        #expect(fixture.store.resumableStackEnd == nil)
    }

    // MARK: - Tail calls

    static let tailCalls = """
        (module
          (import "env" "pause" (func $pause (param i32) (result i32)))
          (func $tail (param i32) (result i32)
            (return_call $pause (i32.add (local.get 0) (i32.const 1))))
          (func (export "tail") (param i32) (result i32)
            (i32.mul (call $tail (local.get 0)) (i32.const 2))))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func aTailCallToTheHostPauses(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.tailCalls, threadingModel: threadingModel, features: [.tailCall],
            hosts: ["pause": ResumableCallTests.pause])
        let paused = try ResumableCallTests.suspended(try fixture.export("tail").invokeResumable([.i32(4)]))
        #expect(paused.arguments == [.i32(5)])
        #expect(
            try ResumableCallTests.finished(try paused.resume(returning: [.i32(50)], in: fixture.store))
                == [.i32(100)])
    }

    // The host's parameter area holds three parameters and two results, and the tail callers'
    // frames are smaller and larger than it, so the frame moves in both directions before the
    // pause. The last host's eight parameters reach past its tail caller's saved slots.
    static let tailCallFrames = """
        (module
          (import "env" "pause" (func $pause (param i32 i64 i32) (result i64 i32)))
          (import "env" "wide" (func $wide (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
          (func $small (param i32) (result i64 i32)
            (return_call $pause (local.get 0) (i64.extend_i32_u (local.get 0)) (i32.const 9)))
          (func $large (param i32) (result i64 i32)
            (local i64 i64 i64 i64 i64 i64)
            (local.set 1 (i64.const 3))
            (return_call $pause
              (local.get 0) (i64.add (local.get 1) (i64.extend_i32_u (local.get 0))) (i32.const 8)))
          (func $sum (param i64 i32) (result i64)
            (i64.add (local.get 0) (i64.extend_i32_u (local.get 1))))
          (func (export "small") (param i32) (result i64)
            (call $sum (call $small (local.get 0))))
          (func (export "large") (param i32) (result i64)
            (call $sum (call $large (local.get 0))))
          (func $spill (param i32) (result i32)
            (return_call $wide
              (local.get 0) (i32.const 1) (i32.const 2) (i32.const 3) (i32.const 4)
              (i32.const 5) (i32.const 6) (i32.const 7)))
          (func (export "spill") (param i32) (result i32)
            (i32.mul (call $spill (local.get 0)) (i32.const 3))))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func aTailCallThatMovesTheFrameResumesInTheMovedFrame(
        _ threadingModel: EngineConfiguration.ThreadingModel
    ) throws {
        let fixture = try Fixture(
            Self.tailCallFrames, threadingModel: threadingModel, features: [.tailCall],
            hosts: ["pause": ResumableCallTests.pause, "wide": ResumableCallTests.pause])
        let small = try ResumableCallTests.suspended(try fixture.export("small").invokeResumable([.i32(5)]))
        #expect(small.arguments == [.i32(5), .i64(5), .i32(9)])
        #expect(small.resultTypes == [.i64, .i32])
        #expect(
            try ResumableCallTests.finished(
                try small.resume(returning: [.i64(1000), .i32(7)], in: fixture.store)) == [.i64(1007)])
        let large = try ResumableCallTests.suspended(try fixture.export("large").invokeResumable([.i32(5)]))
        #expect(large.arguments == [.i32(5), .i64(8), .i32(8)])
        #expect(
            try ResumableCallTests.finished(
                try large.resume(returning: [.i64(2000), .i32(30)], in: fixture.store)) == [.i64(2030)])
        // Eight parameters cover the tail caller's saved slots, so only the moved frame still
        // knows where to return.
        let spill = try ResumableCallTests.suspended(try fixture.export("spill").invokeResumable([.i32(9)]))
        #expect(spill.arguments == [.i32(9), .i32(1), .i32(2), .i32(3), .i32(4), .i32(5), .i32(6), .i32(7)])
        #expect(
            try ResumableCallTests.finished(try spill.resume(returning: [.i32(14)], in: fixture.store))
                == [.i32(42)])
        #expect(fixture.store.resumableStackEnd == nil)
    }

    static let indirectCalls = """
        (module
          (import "env" "pause" (func $pause (param i32) (result i32)))
          (type $unary (func (param i32) (result i32)))
          (table 1 funcref)
          (elem (i32.const 0) func $pause)
          (func $tail (param i32) (result i32)
            (return_call_indirect (type $unary) (local.get 0) (i32.const 0)))
          (func (export "indirect") (param i32) (result i32)
            (i32.add
              (call_indirect (type $unary) (local.get 0) (i32.const 0))
              (call $tail (i32.add (local.get 0) (i32.const 1))))))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func indirectCallsToTheHostPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.indirectCalls, threadingModel: threadingModel, features: [.tailCall],
            hosts: ["pause": ResumableCallTests.pause])
        let first = try ResumableCallTests.suspended(try fixture.export("indirect").invokeResumable([.i32(10)]))
        #expect(first.arguments == [.i32(10)])
        let second = try ResumableCallTests.suspended(try first.resume(returning: [.i32(100)], in: fixture.store))
        // The second pause comes from a tail call through the table.
        #expect(second.arguments == [.i32(11)])
        #expect(
            try ResumableCallTests.finished(try second.resume(returning: [.i32(1000)], in: fixture.store))
                == [.i32(1100)])
        #expect(fixture.count("pause") == 2)
    }

    // MARK: - Memory and reentry

    static let memoryAndReentry = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (import "env" "reenter" (func $reenter (param i32) (result i32)))
          (memory (export "memory") 1)
          (func (export "grow") (result i32) (memory.grow (i32.const 1)))
          (func (export "double") (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))
          (func (export "mem") (result i32)
            (i32.store (i32.const 16) (i32.const 41))
            (drop (call $pause))
            (i32.store (i32.const 65636) (i32.const 5))
            (i32.add
              (i32.add (i32.load (i32.const 16)) (i32.load (i32.const 20)))
              (i32.add (memory.size) (i32.load (i32.const 65636)))))
          (func (export "outer") (param i32) (result i32) (call $reenter (local.get 0)))
          (func (export "nested_pause") (result i32) (call $pause)))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func memoryWrittenAndGrownWhilePausedIsVisible(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.memoryAndReentry, threadingModel: threadingModel,
            hosts: ["pause": ResumableCallTests.pause, "reenter": { _, _ in [.i32(0)] }])
        let paused = try ResumableCallTests.suspended(try fixture.export("mem").invokeResumable())
        let memory = try #require(fixture.instance.exports[memory: "memory"])
        memory.withUnsafeMutableBufferPointer(offset: 20, count: 4) { bytes in
            bytes.storeBytes(of: UInt32(100).littleEndian, as: UInt32.self)
        }
        // The guest grows its memory through a synchronous call while the invocation is paused.
        #expect(try fixture.export("grow")() == [.i32(1)])
        #expect(
            try ResumableCallTests.finished(try paused.resume(returning: [.i32(0)], in: fixture.store))
                == [.i32(41 + 100 + 2 + 5)])
    }

    static let outOfBounds = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (memory 1)
          (func (export "load") (result i32)
            (i32.load (i32.add (call $pause) (i32.const 65528)))))
        """

    @Test(
        arguments: ResumableCallTests.threadingModels,
        [EngineConfiguration.MemoryBoundsChecking.mprotect, .software])
    func anOutOfBoundsAccessAfterAResumeTraps(
        _ threadingModel: EngineConfiguration.ThreadingModel,
        _ memoryBoundsChecking: EngineConfiguration.MemoryBoundsChecking
    ) throws {
        let fixture = try Fixture(
            Self.outOfBounds, threadingModel: threadingModel, memoryBoundsChecking: memoryBoundsChecking,
            hosts: ["pause": ResumableCallTests.pause])
        let inBounds = try ResumableCallTests.suspended(try fixture.export("load").invokeResumable())
        #expect(try ResumableCallTests.finished(try inBounds.resume(returning: [.i32(0)], in: fixture.store)) == [.i32(0)])
        // The continued guest runs under the same bounds checks as a synchronous call, including
        // the guard pages of the mprotect strategy.
        let outside = try ResumableCallTests.suspended(try fixture.export("load").invokeResumable())
        do {
            _ = try outside.resume(returning: [.i32(8)], in: fixture.store)
            Issue.record("The load past the end of memory did not trap.")
        } catch let trap as Trap {
            guard case .memoryOutOfBounds = trap.reason else {
                Issue.record("Unexpected trap \(trap)")
                return
            }
        }
        #expect(fixture.store.resumableStackEnd == nil)
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aHostCallThatReentersTheGuestCanStillPause(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.memoryAndReentry, threadingModel: threadingModel,
            hosts: [
                "pause": ResumableCallTests.pause,
                "reenter": { fixture, arguments in
                    // A synchronous call into the guest finishes before the host pauses.
                    let doubled = try fixture.export("double")([arguments[0]])
                    throw HostCallSuspension(tag: UInt64(doubled[0].i32))
                },
            ])
        let paused = try ResumableCallTests.suspended(try fixture.export("outer").invokeResumable([.i32(21)]))
        #expect(paused.tag == 42)
        #expect(
            try ResumableCallTests.finished(try paused.resume(returning: [.i32(7)], in: fixture.store))
                == [.i32(7)])
        #expect(fixture.store.resumableStackEnd == nil)
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aPauseInsideANestedSynchronousCallIsRefused(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.memoryAndReentry, threadingModel: threadingModel,
            hosts: [
                "pause": ResumableCallTests.pause,
                "reenter": { fixture, _ in
                    // The nested call cannot pause, because this host function's native frames
                    // would have to be kept.
                    try fixture.export("nested_pause")()
                },
            ])
        #expect(throws: ResumableCallError.suspensionUnavailable) {
            _ = try fixture.export("outer").invokeResumable([.i32(1)])
        }
        #expect(fixture.store.resumableStackEnd == nil)
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aDirectCallOfAPausingHostFunctionIsRefused(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let store = Store(engine: Engine(configuration: EngineConfiguration(threadingModel: threadingModel)))
        let pausing = Function(store: store, parameters: [], results: [.i32]) { _, _ in
            throw HostCallSuspension(tag: 1)
        }
        // A host function invoked by the embedder has no guest invocation that could pause.
        #expect(throws: ResumableCallError.suspensionUnavailable) { _ = try pausing() }
        var stack = ExecutionStack(engine: store.engine)
        do {
            _ = try pausing.invoke([], on: &stack)
            Issue.record("The direct call on a caller-owned stack paused.")
        } catch let error as ResumableCallError {
            #expect(error == .suspensionUnavailable)
        }
        #expect(store.resumableStackEnd == nil)
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aPauseDeliveredAsTheHostsFailureIsRefused(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            ResumableCallTests.failures, threadingModel: threadingModel,
            hosts: ["pause": ResumableCallTests.pause, "fail": { _, _ in [.i32(0)] }])
        let paused = try ResumableCallTests.suspended(try fixture.export("fail_after").invokeResumable())
        // The call has already paused, so a request to pause cannot complete it.
        do {
            _ = try paused.resume(throwing: HostCallSuspension(tag: 2), in: fixture.store)
            Issue.record("A request to pause completed the paused call.")
        } catch let error as ResumableCallError {
            #expect(error == .suspensionUnavailable)
        }
        #expect(fixture.count("pause") == 1)
        #expect(fixture.store.resumableStackEnd == nil)
        // The store starts the next invocation normally.
        let next = try ResumableCallTests.suspended(try fixture.export("fail_after").invokeResumable())
        #expect(next.tag == 7)
        next.cancel()
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aNestedResumableInvocationKeepsItsOwnPauses(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Fixture(
            Self.memoryAndReentry, threadingModel: threadingModel,
            hosts: [
                "pause": ResumableCallTests.pause,
                "reenter": { fixture, _ in
                    // The host runs its own resumable invocation to completion inside the call.
                    let nested = try ResumableCallTests.suspended(
                        try fixture.export("nested_pause").invokeResumable())
                    let results = try ResumableCallTests.finished(
                        try nested.resume(returning: [.i32(4)], in: fixture.store))
                    // The outer invocation's own host call then pauses.
                    throw HostCallSuspension(tag: UInt64(results[0].i32))
                },
            ])
        let paused = try ResumableCallTests.suspended(try fixture.export("outer").invokeResumable([.i32(0)]))
        #expect(paused.tag == 4)
        #expect(
            try ResumableCallTests.finished(try paused.resume(returning: [.i32(9)], in: fixture.store))
                == [.i32(9)])
    }

    @Test(arguments: ResumableCallTests.threadingModels)
    func aResumableInvocationInsideASynchronousCallPausesAndFinishes(
        _ threadingModel: EngineConfiguration.ThreadingModel
    ) throws {
        var pausesSeen: [UInt64] = []
        let fixture = try Fixture(
            Self.memoryAndReentry, threadingModel: threadingModel,
            hosts: [
                "pause": ResumableCallTests.pause,
                "reenter": { fixture, arguments in
                    // A synchronous guest call reaches this host function, which runs a resumable
                    // invocation of its own on the same thread and answers each of its pauses.
                    var call = try fixture.export("nested_pause").invokeResumable()
                    while true {
                        switch consume call {
                        case .finished(let results):
                            guard arguments[0] == .i32(1) else { return results }
                            // The synchronous call cannot pause once the nested invocation ended.
                            throw HostCallSuspension(tag: 3)
                        case .suspended(let paused):
                            pausesSeen.append(paused.tag)
                            #expect(fixture.store.resumableStackEnd == nil)
                            let resumed = try paused.resume(returning: [.i32(21)], in: fixture.store)
                            switch consume resumed {
                            case .finished(let results): call = .finished(results)
                            case .suspended(let next): call = .suspended(next)
                            case .rejected(_, let reason): throw reason
                            }
                        }
                    }
                },
            ])
        #expect(try fixture.export("outer")([.i32(0)]) == [.i32(21)])
        #expect(pausesSeen == [7])
        #expect(fixture.store.resumableStackEnd == nil)
        do {
            _ = try fixture.export("outer")([.i32(1)])
            Issue.record("The synchronous call paused.")
        } catch let error as ResumableCallError {
            #expect(error == .suspensionUnavailable)
        }
        #expect(pausesSeen == [7, 7])
        #expect(fixture.store.resumableStackEnd == nil)
    }

    // MARK: - Fuel

    static let fuel = """
        (module
          (import "env" "pause" (func $pause (result i32)))
          (func (export "f") (param $n i32) (result i32)
            (local $i i32)
            (drop (call $pause))
            (block $done
              (loop $l
                (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $l)))
            (local.get $i)))
        """

    @Test(arguments: ResumableCallTests.threadingModels)
    func aPauseConsumesNoFuelAndOutOfFuelStillTraps(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
        let budget: UInt64 = 1_000_000
        let synchronous = try Fixture(
            Self.fuel, threadingModel: threadingModel, fuel: budget,
            hosts: ["pause": { _, _ in [.i32(0)] }])
        #expect(try synchronous.export("f")([.i32(100)]) == [.i32(100)])
        let synchronousCost = budget - (synchronous.store.fuel?.remaining ?? 0)

        let resumable = try Fixture(
            Self.fuel, threadingModel: threadingModel, fuel: budget,
            hosts: ["pause": ResumableCallTests.pause])
        let paused = try ResumableCallTests.suspended(try resumable.export("f").invokeResumable([.i32(100)]))
        #expect(
            try ResumableCallTests.finished(try paused.resume(returning: [.i32(0)], in: resumable.store))
                == [.i32(100)])
        #expect(budget - (resumable.store.fuel?.remaining ?? 0) == synchronousCost)

        // A budget that reaches the pause but not the end of the loop traps after the resume.
        let starved = try Fixture(
            Self.fuel, threadingModel: threadingModel, fuel: 50,
            hosts: ["pause": ResumableCallTests.pause])
        let starving = try ResumableCallTests.suspended(try starved.export("f").invokeResumable([.i32(1000)]))
        do {
            _ = try starving.resume(returning: [.i32(0)], in: starved.store)
            Issue.record("The invocation finished without fuel.")
        } catch let trap as Trap {
            guard case .outOfFuel = trap.reason else {
                Issue.record("Unexpected trap \(trap)")
                return
            }
        }
    }
}
