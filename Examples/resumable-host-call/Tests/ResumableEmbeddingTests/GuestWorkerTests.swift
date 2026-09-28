import Foundation
import ResumableEmbedding
import Testing
import WasmKit

/// A worker actor pausing the Swift guest while the main actor measures.
///
/// The guest is the optimized WebAssembly module that `Guest/build.sh` builds. Set
/// `RESUMABLE_GUEST_WASM` to use another path. Every test runs under both dispatch models and
/// bounds each wait with a deadline.
@Suite(.timeLimit(.minutes(1)))
struct GuestWorkerTests {
    static let threadingModels: [EngineConfiguration.ThreadingModel] = [.token, .direct]

    /// The failure of a test whose guest module has not been built.
    struct MissingGuest: Error, CustomStringConvertible {
        let path: String
        var description: String { "No guest at \(path). Run Guest/build.sh first." }
    }

    static func guest() throws -> [UInt8] {
        let path =
            ProcessInfo.processInfo.environment["RESUMABLE_GUEST_WASM"]
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/guest/resumable_guest.wasm").path
        guard let data = FileManager.default.contents(atPath: path) else { throw MissingGuest(path: path) }
        return [UInt8](data)
    }

    /// Barriers that upcoming measurements wait at before they answer.
    @MainActor
    final class Holds {
        var pending: [(entered: Checkpoint, release: Checkpoint)] = []
    }

    /// A worker whose measurements can be held at a barrier.
    @MainActor
    final class Harness {
        let log = EventLog()
        let instrument = Instrument()
        let holds = Holds()
        let worker: GuestWorker

        init(_ threadingModel: EngineConfiguration.ThreadingModel) throws {
            let (log, instrument, holds) = (log, instrument, holds)
            worker = try GuestWorker(wasm: try GuestWorkerTests.guest(), threadingModel: threadingModel, log: log) { input in
                if !holds.pending.isEmpty {
                    let hold = holds.pending.removeFirst()
                    hold.entered.open()
                    try? await hold.release.wait()
                }
                let reading = instrument.measure(input)
                log.record(.measured(input: input, reading: reading))
                return reading
            }
        }

        /// Makes the next measurement open `entered` and wait until `release` opens.
        func holdNextMeasurement() -> (entered: Checkpoint, release: Checkpoint) {
            let hold = (entered: Checkpoint(), release: Checkpoint())
            holds.pending.append(hold)
            return hold
        }
    }

    @Test(arguments: threadingModels)
    func theSameInvocationContinuesWithMainActorReadings(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let result = try await withDeadline { try await worker.evaluate(3) }
        #expect(result == referenceEvaluation(3))
        #expect(result == 8842)
        #expect(
            harness.log.snapshot == [
                .started(count: 3),
                .paused(input: 30), .measured(input: 30, reading: 907), .delivering(reading: 907), .noted(step: 0),
                .paused(input: 31), .measured(input: 31, reading: 968), .delivering(reading: 968), .noted(step: 1),
                .paused(input: 32), .measured(input: 32, reading: 1031), .delivering(reading: 1031), .noted(step: 2),
                .finished(result: 8842),
            ])
        // Each step ran once in the guest and once on the main actor.
        #expect(try await worker.completedSteps() == 3)
        #expect(await harness.instrument.measuredInputs == [30, 31, 32])
    }

    @Test(arguments: threadingModels)
    func theWorkerAnswersWhileTheMainActorMeasures(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let hold = await harness.holdNextMeasurement()
        let evaluation = Task { try await worker.evaluate(2) }
        try await withDeadline { try await hold.entered.wait() }

        // The invocation is paused and the main actor holds the measurement, yet the worker
        // runs a synchronous guest call to completion.
        #expect(try await withDeadline { try await worker.completedSteps() } == 0)
        #expect(await harness.instrument.measuredInputs.isEmpty)
        hold.release.open()

        #expect(try await withDeadline { try await evaluation.value } == referenceEvaluation(2))
        #expect(
            Array(harness.log.snapshot.prefix(5)) == [
                .started(count: 2), .paused(input: 20), .answeredWhilePaused(completedSteps: 0),
                .measured(input: 20, reading: 407), .delivering(reading: 407),
            ])
    }

    @Test(arguments: threadingModels)
    func aCancelledInvocationRefusesItsLateReading(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let hold = await harness.holdNextMeasurement()
        let evaluation = Task { try await worker.evaluate(3) }
        try await withDeadline { try await hold.entered.wait() }
        #expect(await worker.cancelPausedInvocation())
        #expect(await !worker.cancelPausedInvocation())
        hold.release.open()

        await #expect(throws: GuestWorker.Failure.cancelled) {
            try await withDeadline { try await evaluation.value }
        }
        // The main actor finished the measurement that had started, and the guest never
        // continued past its pause.
        #expect(await harness.instrument.measuredInputs == [30])
        #expect(try await worker.completedSteps() == 0)
        #expect(
            harness.log.snapshot == [
                .started(count: 3), .paused(input: 30), .cancelled(input: 30),
                .measured(input: 30, reading: 907), .refusedLateReading(reading: 907),
            ])
        // The worker stays usable.
        #expect(try await withDeadline { try await worker.evaluate(1) } == referenceEvaluation(1))
    }

    @Test(arguments: threadingModels)
    func aLateReadingCannotContinueTheNextPausedInvocation(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let first = await harness.holdNextMeasurement()
        let cancelled = Task { try await worker.evaluate(2) }
        try await withDeadline { try await first.entered.wait() }
        #expect(await worker.cancelPausedInvocation())

        let second = await harness.holdNextMeasurement()
        let next = Task { try await worker.evaluate(1) }
        try await withDeadline { try await second.entered.wait() }
        first.release.open()
        // WasmKit refuses the reading because the paused invocation now waits for another pause.
        await #expect(throws: GuestWorker.Failure.refused(.staleSuspension)) {
            try await withDeadline { try await cancelled.value }
        }
        #expect(try await worker.completedSteps() == 0)

        second.release.open()
        #expect(try await withDeadline { try await next.value } == referenceEvaluation(1))
        #expect(try await worker.completedSteps() == 1)
        #expect(await harness.instrument.measuredInputs == [20, 10])
    }

    @Test(arguments: threadingModels)
    func cancellingTheTaskReleasesThePausedInvocation(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let hold = await harness.holdNextMeasurement()
        let evaluation = Task { try await worker.evaluate(2) }
        try await withDeadline { try await hold.entered.wait() }
        evaluation.cancel()
        // The cancellation handler releases the invocation from a separate task.
        try await withDeadline {
            while !harness.log.snapshot.contains(.cancelled(input: 20)) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await !worker.cancelPausedInvocation())
        hold.release.open()
        await #expect(throws: GuestWorker.Failure.cancelled) {
            try await withDeadline { try await evaluation.value }
        }
        #expect(try await worker.completedSteps() == 0)
    }

    @Test(arguments: threadingModels)
    func aSecondInvocationIsRefusedWhileOneIsPaused(_ threadingModel: EngineConfiguration.ThreadingModel) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let hold = await harness.holdNextMeasurement()
        let evaluation = Task { try await worker.evaluate(1) }
        try await withDeadline { try await hold.entered.wait() }
        await #expect(throws: GuestWorker.Failure.busy) {
            try await worker.evaluate(1)
        }
        hold.release.open()
        #expect(try await withDeadline { try await evaluation.value } == referenceEvaluation(1))
    }
}
