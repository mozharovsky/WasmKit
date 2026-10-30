import Testing
import WAT
import WasmParser

@testable import WasmKit

/// Suspensions at host calls that the guest reaches through a tail call.
///
/// The guest is ``TailCallHostTrapTests/wat``. A tail call to a host function moves its arguments
/// and runs the host function in a frame above them. A suspended call resumes in that moved frame,
/// so the suspension must not write back the saved slots of the caller as a trap does.
@Suite
struct ResumableHostCallTailTests {
    typealias Path = TailCallHostTrapTests.Path

    /// An engine configuration for one run of the guest.
    struct Configuration: Sendable, CustomTestStringConvertible {
        let threadingModel: EngineConfiguration.ThreadingModel
        let epochInterruption: Bool
        var testDescription: String {
            "\(threadingModel) \(epochInterruption ? "epoch" : "no epoch")"
        }
    }

    /// Every tested threading model, with and without epoch interruption.
    static let configurations: [Configuration] = testedThreadingModels.flatMap { model in
        [false, true].map { Configuration(threadingModel: model, epochInterruption: $0) }
    }

    /// Controls the host functions of the guest. While `suspends` is true they suspend. Otherwise
    /// they throw `failure` if it is set, or return the sum of their arguments.
    final class Host {
        var suspends = true
        var failure: (any Error)?
    }

    static func makeGuest(_ configuration: Configuration, host: Host) throws -> TailCallHostTrapTests.Guest {
        try TailCallHostTrapTests.makeGuest(
            configuration.threadingModel, epochInterruption: configuration.epochInterruption
        ) { arguments, call in
            if host.suspends { throw SuspensionRequest(id: UInt64(call)) }
            if let failure = host.failure { throw failure }
            return [.i32(TailCallHostTrapTests.sum(arguments))]
        }
    }

    /// Starts a resumable call of `path`'s runner and checks that it suspends once at the host
    /// call, with the path's arguments.
    static func suspend(
        _ guest: TailCallHostTrapTests.Guest, path: Path, on stack: consuming ExecutionStack? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ResumableCall {
        let runner = try guest.export(path.runner)
        let count = guest.calls.arguments[path.host]?.count ?? 0
        let call: ResumableCall
        if let stack = consume stack {
            call = try ResumableCall(function: runner, arguments: [.i32(9)], on: stack)
        } else {
            call = try ResumableCall(function: runner, arguments: [.i32(9)])
        }
        let suspension = try ResumableHostCallTests.suspension(try call.resume(), sourceLocation: sourceLocation)
        #expect(
            suspension.reason == .hostCall(id: UInt64(count + 1), arguments: path.arguments),
            sourceLocation: sourceLocation)
        #expect(guest.calls.arguments[path.host]?.count == count + 1, sourceLocation: sourceLocation)
        return call
    }

    /// Resumes a suspension on every path, and runs the next call on the same stack.
    @Test(arguments: configurations, Path.allCases)
    func resultsContinueInMovedFrame(_ configuration: Configuration, path: Path) throws {
        let guest = try Self.makeGuest(configuration, host: Host())
        let sum = TailCallHostTrapTests.sum(path.arguments)
        let call = try Self.suspend(guest, path: path)
        let results = try ResumableHostCallTests.results(
            try call.resume(returning: [.i32(sum)]))
        #expect(results == [.i32(sum &* 3)])
        #expect(guest.calls.arguments[path.host] == [path.arguments])
        // The finished call hands its stack to the next one, which suspends and finishes there too.
        guard let stack = call.takeStack() else {
            Issue.record("expected the stack of the finished call")
            return
        }
        let next = try Self.suspend(guest, path: path, on: stack)
        #expect(
            try ResumableHostCallTests.results(try next.resume(returning: [.i32(1)]))
                == [.i32(3)])
        #expect(guest.calls.arguments[path.host]?.count == 2)
    }

    /// On the `partial` path, the saved SP of the host frame overlaps the saved function slot of
    /// the caller. The saved PC and SP of the caller stay in place. If the suspension wrote back
    /// the slots of the caller, it would overwrite that saved SP, and the resumed call would return
    /// through a broken frame. `spill` cannot show this, because the saved slots of its host
    /// frame lie above those of the caller.
    @Test(arguments: configurations)
    func partialPathResumesInMovedFrame(_ configuration: Configuration) throws {
        let host = Host()
        let guest = try Self.makeGuest(configuration, host: host)
        let resumed = try Self.suspend(guest, path: .partial)
        #expect(
            try ResumableHostCallTests.results(try resumed.resume(returning: [.i32(14)]))
                == [.i32(42)])
        let failed = try Self.suspend(guest, path: .partial)
        let trap = #expect(throws: Trap.self) {
            try failed.resume(failing: TailCallHostTrapTests.hostTrap)
        }
        TailCallHostTrapTests.expectHostTrap(trap, frames: ["partial", "run_partial"])
        #expect(guest.calls.arguments["three"]?.count == 2)
        // The store still runs the same call synchronously.
        host.suspends = false
        #expect(try guest.export("run_partial")([.i32(9)]) == [.i32(36)])
    }

    /// A trap thrown into a suspended host call, or a cancellation with a trap, is reported like
    /// the trap of a synchronous host function at that call.
    ///
    /// The frames and the trap site match. Only the address of the outermost frame differs,
    /// because the called function returns to different code in `invoke` and in a resumable call.
    @Test(arguments: configurations, Path.allCases)
    func trapAtSuspensionHasSynchronousBacktrace(_ configuration: Configuration, path: Path) throws {
        let host = Host()
        let guest = try Self.makeGuest(configuration, host: host)
        let runner = try guest.export(path.runner)
        host.suspends = false
        host.failure = TailCallHostTrapTests.hostTrap
        let synchronousTrap = #expect(throws: Trap.self) { try runner([.i32(9)]) }
        TailCallHostTrapTests.expectHostTrap(synchronousTrap, frames: [path.rawValue, path.runner])
        let synchronous = try #require(synchronousTrap?.backtrace)
        host.suspends = true
        for cancels in [false, true] {
            let call = try Self.suspend(guest, path: path)
            let trap = #expect(throws: Trap.self) {
                if cancels {
                    try call.resume(throwing: TailCallHostTrapTests.hostTrap)
                } else {
                    _ = try call.resume(failing: TailCallHostTrapTests.hostTrap)
                }
            }
            TailCallHostTrapTests.expectHostTrap(trap, frames: [path.rawValue, path.runner])
            let backtrace = try #require(trap?.backtrace)
            #expect(backtrace.trapSite == synchronous.trapSite, "cancels: \(cancels)")
            #expect(backtrace.symbols.dropLast().map(\.address) == synchronous.symbols.dropLast().map(\.address))
            #expect(call.isFinished)
            let tookStack = !ResumableHostCallTests.isNone(call.takeStack())
            #expect(tookStack)
        }
        #expect(guest.calls.arguments[path.host]?.count == 3)
    }

    /// An exception thrown into a host call suspended in `spill` reaches the handler below the
    /// tail caller, as the exception of a synchronous host function does. Other errors pass
    /// through unchanged.
    @Test(arguments: configurations)
    func exceptionAtSuspensionReachesHandlerBelowTailCaller(_ configuration: Configuration) throws {
        let host = Host()
        let guest = try Self.makeGuest(configuration, host: host)
        let exception = #expect(throws: WasmKitException.self) { try guest.export("raise")([.i32(77)]) }
        let raised = try #require(exception)

        let caught = try ResumableCall(function: try guest.export("caught"), arguments: [.i32(9)])
        let suspension = try ResumableHostCallTests.suspension(try caught.resume())
        #expect(suspension.reason == .hostCall(id: 1, arguments: Path.spill.arguments))
        #expect(try ResumableHostCallTests.results(try caught.resume(failing: raised)) == [.i32(77)])

        let failed = try Self.suspend(guest, path: .spill)
        #expect(throws: TailCallHostTrapTests.HostFailure()) {
            try failed.resume(failing: TailCallHostTrapTests.HostFailure())
        }
        #expect(failed.isFinished)
        // A synchronous run gets the same exception to the same handler.
        host.suspends = false
        host.failure = raised
        #expect(try guest.export("caught")([.i32(9)]) == [.i32(77)])
        #expect(guest.calls.arguments["wide"]?.count == 3)
    }
}
