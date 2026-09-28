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
