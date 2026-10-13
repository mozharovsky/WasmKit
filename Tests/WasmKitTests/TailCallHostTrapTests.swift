import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Traps from host functions that the guest reaches through a tail call.
///
/// A tail call moves its arguments to the start of the caller's parameter area, and the host
/// function runs in a frame placed above them. The arguments and the new frame's saved slots may
/// land on the caller's saved slots. A trap from the host function is still reported from the
/// caller's frame, so building its backtrace reads those slots.
///
/// Every store checks bounds in software. The fixtures check the configuration that the engine
/// settles on, since a test argument only requests it.
@Suite
struct TailCallHostTrapTests {
    typealias Fixture = ResumableCallTests.Fixture

    /// The guest.
    ///
    /// Each tail caller has one parameter slot, four constant slots and no locals, so its saved
    /// slots are slots 5, 6 and 7 of its parameter area. `spill` passes eight arguments to `wide`,
    /// which cover all three, and `indirect` passes the same arguments through the table.
    /// `partial` passes three arguments to `three`. They stay below the saved slots, but the host
    /// frame's own saved slots then start at slot 3, so its saved SP lands on the caller's saved
    /// function and the caller's saved PC and SP stay in place. `short` passes one argument and
    /// reaches no saved slot, and `plain` calls `wide` without a tail call. Each `run_` export
    /// multiplies its callee's result by three, so its frame stays below the callee's.
    static let wat = """
        (module
          (import "env" "wide" (func $wide (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
          (import "env" "three" (func $three (param i32 i32 i32) (result i32)))
          (import "env" "one" (func $one (param i32) (result i32)))
          (type $wideType (func (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
          (table funcref (elem $wide))
          (tag $t (param i32))
          (func $spill (export "spill") (param i32) (result i32)
            (return_call $wide
              (local.get 0) (i32.const 1) (i32.const 2) (i32.const 3)
              (i32.const 4) (i32.const 5) (i32.const 6) (i32.const 7)))
          (func $indirect (export "indirect") (param i32) (result i32)
            (return_call_indirect (type $wideType)
              (local.get 0) (i32.const 1) (i32.const 2) (i32.const 3)
              (i32.const 4) (i32.const 5) (i32.const 6) (i32.const 7) (i32.const 0)))
          (func $partial (export "partial") (param i32) (result i32)
            (return_call $three (local.get 0) (i32.const 1) (i32.const 2)))
          (func $short (export "short") (param i32) (result i32)
            (return_call $one (local.get 0)))
          (func $plain (export "plain") (param i32) (result i32)
            (call $wide
              (local.get 0) (i32.const 1) (i32.const 2) (i32.const 3)
              (i32.const 4) (i32.const 5) (i32.const 6) (i32.const 7)))
          (func (export "run_spill") (param i32) (result i32) (i32.mul (call $spill (local.get 0)) (i32.const 3)))
          (func (export "run_indirect") (param i32) (result i32) (i32.mul (call $indirect (local.get 0)) (i32.const 3)))
          (func (export "run_partial") (param i32) (result i32) (i32.mul (call $partial (local.get 0)) (i32.const 3)))
          (func (export "run_short") (param i32) (result i32) (i32.mul (call $short (local.get 0)) (i32.const 3)))
          (func (export "run_plain") (param i32) (result i32) (i32.mul (call $plain (local.get 0)) (i32.const 3)))
          (func (export "raise") (param i32) (throw $t (local.get 0)))
          (func (export "caught") (param i32) (result i32)
            (block $h (result i32)
              (try_table (result i32) (catch $t $h)
                (i32.mul (call $spill (local.get 0)) (i32.const 3))))))
        """

    /// A guest that reaches `wide` through `return_call_ref`.
    ///
    /// It stays apart from ``wat`` because typed function references need their own features.
    /// `byRef` has the frame of `spill` and passes the same eight arguments, so they cover all
    /// three of its saved slots. `run_byRef` multiplies the result by three.
    static let byReferenceWAT = """
        (module
          (type $wideType (func (param i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))
          (import "env" "wide" (func $wide (type $wideType)))
          (elem declare func $wide)
          (func $byRef (export "byRef") (param i32) (result i32)
            (return_call_ref $wideType
              (local.get 0) (i32.const 1) (i32.const 2) (i32.const 3)
              (i32.const 4) (i32.const 5) (i32.const 6) (i32.const 7) (ref.func $wide)))
          (func (export "run_byRef") (param i32) (result i32) (i32.mul (call $byRef (local.get 0)) (i32.const 3))))
        """

    /// The features of ``byReferenceWAT``.
    static let byReferenceFeatures: WasmFeatureSet = [.referenceTypes, .tailCall, .functionReferences]

    /// A function of the guest that reaches a host function.
    enum Path: String, CaseIterable, Sendable {
        case spill, indirect, partial, short, plain

        /// The export that calls this function and multiplies its result by three.
        var runner: String { "run_\(rawValue)" }

        /// The import that this function calls.
        var host: String {
            switch self {
            case .spill, .indirect, .plain: "wide"
            case .partial: "three"
            case .short: "one"
            }
        }

        /// The arguments that the host function receives when the runner is called with 9.
        var arguments: [Value] {
            let count =
                switch self {
                case .spill, .indirect, .plain: 8
                case .partial: 3
                case .short: 1
                }
            return [.i32(9)] + (1..<count).map { .i32(UInt32($0)) }
        }
    }

    /// How a test enters the guest.
    enum Entry: String, CaseIterable, Sendable {
        /// A synchronous call of the export.
        case synchronous
        /// A resumable invocation that fails before any pause.
        case resumable
    }

    /// A store configuration together with an entry, so that one argument list covers both.
    struct Variant: Sendable, CustomTestStringConvertible {
        let threadingModel: EngineConfiguration.ThreadingModel
        let controlled: Bool
        let entry: Entry
        var testDescription: String { "\(threadingModel) \(controlled ? "controlled" : "uncontrolled") \(entry)" }
    }

    /// Every tested model, with and without a controller, through either entry.
    static let variants: [Variant] = testedThreadingModels.flatMap { model in
        [true, false].flatMap { controlled in
            Entry.allCases.map { Variant(threadingModel: model, controlled: controlled, entry: $0) }
        }
    }

    /// The trap that the host functions throw.
    static let hostTrap = Trap(TrapReason.Message("host trap"))

    /// Instantiates a guest with the same host function behind every import.
    ///
    /// - Parameters:
    ///   - threadingModel: The dispatch model to request.
    ///   - control: A controller to bind the store to, or nil for a store without one.
    ///   - guest: The guest's text. Most tests use ``wat``.
    ///   - features: The guest's features. The encoder, the parser and the engine all receive them.
    ///   - host: The host function, which receives the fixture and the arguments.
    /// - Returns: The fixture, which records the arguments of every host call.
    /// - Throws: Module, store or instantiation failures.
    static func fixture(
        _ threadingModel: EngineConfiguration.ThreadingModel, control: ExecutionControl?,
        guest: String = wat, features: WasmFeatureSet = [.tailCall, .exceptionHandling],
        host: @escaping (Fixture, [Value]) throws -> [Value]
    ) throws -> Fixture {
        let fixture = try Fixture(
            guest, threadingModel: threadingModel, features: features,
            memoryBoundsChecking: .software, executionControl: control, names: true,
            hosts: ["wide": host, "three": host, "one": host])
        let configuration = fixture.store.engine.configuration
        #expect(configuration.features == features)
        #expect(configuration.threadingModel == threadingModel)
        #expect(configuration.memoryBoundsChecking == .software)
        #expect(fixture.store.hasExecutionControl == (control != nil))
        return fixture
    }

    /// Calls the runner of `path` with 9 and drops what it returns.
    ///
    /// - Throws: The invocation's failure.
    static func enter(_ fixture: Fixture, _ path: Path, _ entry: Entry) throws {
        let runner = try fixture.export(path.runner)
        switch entry {
        case .synchronous: _ = try runner([.i32(9)])
        case .resumable: _ = try runner.invokeResumable([.i32(9)])
        }
    }

    /// The wrapping sum of `values`, which a host function returns when it does not trap.
    static func sum(_ values: [Value]) -> UInt32 {
        values.reduce(0) { $0 &+ $1.i32 }
    }

    /// Checks that `trap` is ``hostTrap`` and that its backtrace names `frames`, innermost first.
    ///
    /// Frames without a name are left out, since the walk can also report the root frame below the
    /// export, which has no function. A missing trap has already been recorded by the caller's
    /// expectation.
    static func expectHostTrap(_ trap: Trap?, frames: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        guard let trap else { return }
        guard case .message(let message) = trap.reason, message.text == "host trap" else {
            Issue.record("Unexpected trap \(trap)", sourceLocation: sourceLocation)
            return
        }
        #expect(trap.backtrace?.symbols.compactMap(\.name) == frames, sourceLocation: sourceLocation)
    }

    /// Confirms the frame layout that the guest's description relies on.
    ///
    /// - Throws: Fixture or translation failures.
    @Test
    func theTailCallersSavedSlotsAreSlotsFiveToSeven() throws {
        let fixture = try Self.fixture(.token, control: nil) { _, _ in [] }
        for path in [Path.spill, .indirect, .partial, .short] {
            let code = try fixture.export(path.rawValue).handle.wasm.ensureCompiled(store: StoreRef(fixture.store))
            #expect(code.entryOffset - StackLayout.numberOfSavingSlots == 5, "\(path)")
        }
    }

    /// Reports the host's trap from the tail caller's frame after eight arguments covered its saved
    /// slots, and leaves the store able to run the same call again.
    ///
    /// - Parameter variant: The dispatch model, whether the store has a controller, and the entry.
    /// - Throws: Fixture or export failures.
    @Test(arguments: variants)
    func aTrapAfterTheArgumentsCoverTheSavedSlotsKeepsTheBacktrace(_ variant: Variant) throws {
        let fixture = try Self.fixture(variant.threadingModel, control: variant.controlled ? ExecutionControl() : nil) {
            fixture, arguments in
            guard fixture.count("wide") > 1 else { throw Self.hostTrap }
            return [.i32(Self.sum(arguments))]
        }
        let trap = #expect(throws: Trap.self) { try Self.enter(fixture, .spill, variant.entry) }
        Self.expectHostTrap(trap, frames: ["spill", "run_spill"])
        #expect(fixture.calls["wide"] == [Path.spill.arguments])
        #expect(fixture.store.resumableStackEnd == nil)
        #expect(try fixture.export("run_spill")([.i32(9)]) == [.i32(111)])
    }

    /// Reports the same trap through the table, after a partial overlap, and through the two calls
    /// that reach no saved slot.
    ///
    /// - Parameters:
    ///   - threadingModel: The dispatch model of the controlled store.
    ///   - path: How the guest reaches the host function.
    /// - Throws: Fixture or export failures.
    @Test(arguments: testedThreadingModels, [Path.indirect, .partial, .short, .plain])
    func otherCallsToATrappingHostKeepTheBacktrace(threadingModel: EngineConfiguration.ThreadingModel, path: Path) throws {
        let fixture = try Self.fixture(threadingModel, control: ExecutionControl()) { _, _ in throw Self.hostTrap }
        let trap = #expect(throws: Trap.self) { try Self.enter(fixture, path, .synchronous) }
        Self.expectHostTrap(trap, frames: [path.rawValue, path.runner])
        #expect(fixture.calls[path.host] == [path.arguments])
    }

    /// Reports the trap of a host function that `return_call_ref` reaches with eight arguments
    /// from the tail caller's frame, and leaves the store able to run the same call again.
    ///
    /// - Parameter variant: The dispatch model, whether the store has a controller, and the entry.
    /// - Throws: Fixture or export failures.
    @Test(arguments: variants)
    func aTrapThroughAFunctionReferenceKeepsTheBacktrace(_ variant: Variant) throws {
        let fixture = try Self.fixture(
            variant.threadingModel, control: variant.controlled ? ExecutionControl() : nil,
            guest: Self.byReferenceWAT, features: Self.byReferenceFeatures
        ) { fixture, arguments in
            guard fixture.count("wide") > 1 else { throw Self.hostTrap }
            return [.i32(Self.sum(arguments))]
        }
        let runner = try fixture.export("run_byRef")
        let trap = #expect(throws: Trap.self) {
            switch variant.entry {
            case .synchronous: _ = try runner([.i32(9)])
            case .resumable: _ = try runner.invokeResumable([.i32(9)])
            }
        }
        Self.expectHostTrap(trap, frames: ["byRef", "run_byRef"])
        #expect(fixture.calls["wide"] == [Path.spill.arguments])
        #expect(fixture.store.resumableStackEnd == nil)
        #expect(try runner([.i32(9)]) == [.i32(111)])
    }

    /// Delivers each host function's result through every path when nothing traps.
    ///
    /// - Parameter threadingModel: The dispatch model of the controlled store.
    /// - Throws: Fixture, export or invocation failures.
    @Test(arguments: testedThreadingModels)
    func everyPathReturnsTheHostsResult(threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Self.fixture(threadingModel, control: ExecutionControl()) { _, arguments in
            [.i32(Self.sum(arguments))]
        }
        for path in Path.allCases {
            #expect(try fixture.export(path.runner)([.i32(9)]) == [.i32(Self.sum(path.arguments) &* 3)], "\(path)")
        }
    }

    /// Continues a tail-called host's pause in the moved frame, once with a result and once with a
    /// trap that names the same frames as a synchronous one.
    ///
    /// - Parameter threadingModel: The dispatch model of the controlled store.
    /// - Throws: Fixture, export or invocation failures.
    @Test(arguments: testedThreadingModels)
    func aPausedTailCallTakesAResultOrATrap(threadingModel: EngineConfiguration.ThreadingModel) throws {
        let fixture = try Self.fixture(threadingModel, control: ExecutionControl(), host: ResumableCallTests.pause)
        let answered = try ResumableCallTests.suspended(try fixture.export("run_spill").invokeResumable([.i32(9)]))
        #expect(answered.arguments == Path.spill.arguments)
        #expect(try ResumableCallTests.finished(try answered.resume(returning: [.i32(14)], in: fixture.store)) == [.i32(42)])
        let failed = try ResumableCallTests.suspended(try fixture.export("run_spill").invokeResumable([.i32(9)]))
        do {
            _ = try failed.resume(throwing: Self.hostTrap, in: fixture.store)
            Issue.record("The delivered trap did not end the invocation.")
        } catch let trap as Trap {
            Self.expectHostTrap(trap, frames: ["spill", "run_spill"])
        }
        #expect(fixture.count("wide") == 2)
        #expect(fixture.store.resumableStackEnd == nil)
    }

    /// Continues a pause after the partial overlap in the moved frame, once with a result and once
    /// with a trap.
    ///
    /// The host frame's saved SP lies on the tail caller's saved function here. Writing the
    /// caller's saved slots back at the pause would replace that saved SP, and the continuation
    /// would return through a broken frame. A pause through `spill` cannot show this, because
    /// that host frame's saved slots lie above the caller's.
    ///
    /// - Parameters:
    ///   - threadingModel: The dispatch model.
    ///   - controlled: Whether the store has a controller.
    /// - Throws: Fixture, export or invocation failures.
    @Test(arguments: testedThreadingModels, [true, false])
    func aPauseAfterThePartialOverlapResumesInTheMovedFrame(
        threadingModel: EngineConfiguration.ThreadingModel, controlled: Bool
    ) throws {
        let fixture = try Self.fixture(
            threadingModel, control: controlled ? ExecutionControl() : nil, host: ResumableCallTests.pause)
        let runner = try fixture.export("run_partial")
        let answered = try ResumableCallTests.suspended(try runner.invokeResumable([.i32(9)]))
        #expect(answered.arguments == Path.partial.arguments)
        #expect(try ResumableCallTests.finished(try answered.resume(returning: [.i32(14)], in: fixture.store)) == [.i32(42)])
        #expect(fixture.calls["three"] == [Path.partial.arguments])
        let failed = try ResumableCallTests.suspended(try runner.invokeResumable([.i32(9)]))
        do {
            _ = try failed.resume(throwing: Self.hostTrap, in: fixture.store)
            Issue.record("The delivered trap did not end the invocation.")
        } catch let trap as Trap {
            Self.expectHostTrap(trap, frames: ["partial", "run_partial"])
        }
        #expect(fixture.count("three") == 2)
        #expect(fixture.store.resumableStackEnd == nil)
    }

    /// Ends the invocation with the stop that the host requested before it trapped.
    ///
    /// - Parameters:
    ///   - threadingModel: The dispatch model of the controlled store.
    ///   - entry: How the test enters the guest.
    /// - Throws: Fixture or controller failures.
    @Test(arguments: testedThreadingModels, Entry.allCases)
    func aStopRequestedBeforeTheTrapOutranksIt(threadingModel: EngineConfiguration.ThreadingModel, entry: Entry) throws {
        let control = try ExecutionControl()
        let fixture = try Self.fixture(threadingModel, control: control) { _, _ in
            control.requestInterruption()
            throw Self.hostTrap
        }
        #expect(throws: ExecutionTermination.interrupted) { try Self.enter(fixture, .spill, entry) }
        #expect(fixture.count("wide") == 1)
        #expect(fixture.store.resumableStackEnd == nil)
    }

    /// Lets a handler below the tail caller catch the exception that the host throws.
    ///
    /// - Parameter threadingModel: The dispatch model of the controlled store.
    /// - Throws: Fixture, export or invocation failures.
    @Test(arguments: testedThreadingModels)
    func aGuestHandlerCatchesTheHostsException(threadingModel: EngineConfiguration.ThreadingModel) throws {
        var exception: WasmKitException?
        let fixture = try Self.fixture(threadingModel, control: ExecutionControl()) { _, _ in
            guard let exception else { throw ResumableCallTests.HostFailure() }
            throw exception
        }
        exception = #expect(throws: WasmKitException.self) { try fixture.export("raise")([.i32(77)]) }
        #expect(try fixture.export("caught")([.i32(9)]) == [.i32(77)])
        #expect(fixture.count("wide") == 1)
    }
}
