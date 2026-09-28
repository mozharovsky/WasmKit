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
        /// Whether each measurement cancels the task that awaits it just before it returns.
        var cancelsBeforeReturning = false
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
                    // A held measurement stands for native work that does not observe
                    // cancellation, so only the test's release ends it.
                    let hold = holds.pending.removeFirst()
                    hold.entered.open()
                    await hold.release.waitIgnoringCancellation()
                }
                let reading = instrument.measure(input)
                log.record(.measured(input: input, reading: reading))
                if holds.cancelsBeforeReturning {
                    // The measurement is awaited by the evaluating task, so this cancels that
                    // evaluation and returns the reading at once, without waiting for the
                    // worker to handle the cancellation.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
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
        let released = harness.log.checkpoint(for: .cancelled(input: 20))
        evaluation.cancel()
        // The cancellation handler releases the invocation from a separate task while the
        // measurement is still held.
        try await withDeadline { try await released.wait() }
        #expect(await !worker.cancelPausedInvocation())
        hold.release.open()
        await #expect(throws: GuestWorker.Failure.cancelled) {
            try await withDeadline { try await evaluation.value }
        }
        #expect(try await worker.completedSteps() == 0)
        #expect(
            harness.log.snapshot == [
                .started(count: 2), .paused(input: 20), .cancelled(input: 20),
                .measured(input: 20, reading: 407), .refusedLateReading(reading: 407),
            ])
    }

    @Test(arguments: threadingModels)
    func aTaskCancelledJustBeforeAFastReadingDoesNotContinueTheGuest(
        _ threadingModel: EngineConfiguration.ThreadingModel
    ) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        await MainActor.run { harness.holds.cancelsBeforeReturning = true }
        // Each measurement cancels its evaluation and returns at once, which races the
        // cancellation handler's task to the worker. Nothing here waits for that task.
        let rounds = 40
        for round in 1...rounds {
            let evaluation = Task { try await worker.evaluate(1) }
            await #expect(throws: GuestWorker.Failure.cancelled, "round \(round)") {
                try await withDeadline { try await evaluation.value }
            }
            // The guest did not run past its import, and the worker holds no paused invocation.
            #expect(try await worker.completedSteps() == 0, "round \(round)")
            #expect(await !worker.cancelPausedInvocation(), "round \(round)")
        }
        let events = harness.log.snapshot
        #expect(events.count == rounds * 5)
        for round in 0..<rounds {
            #expect(
                Array(events[(round * 5)..<(round * 5 + 5)]) == [
                    .started(count: 1), .paused(input: 10), .measured(input: 10, reading: 107),
                    .cancelled(input: 10), .refusedLateReading(reading: 107),
                ],
                "round \(round + 1)")
        }
        // The native measurement ran each time, because cancellation does not undo it.
        #expect(await harness.instrument.measuredInputs == Array(repeating: 10, count: rounds))

        // The released worker still continues an evaluation that is not cancelled.
        await MainActor.run { harness.holds.cancelsBeforeReturning = false }
        #expect(try await withDeadline { try await worker.evaluate(1) } == referenceEvaluation(1))
        #expect(try await worker.completedSteps() == 1)
    }

    @Test(arguments: threadingModels)
    func anOldCancellationNeitherReleasesNorContinuesTheSuccessor(
        _ threadingModel: EngineConfiguration.ThreadingModel
    ) async throws {
        let harness = try await Harness(threadingModel)
        let worker = harness.worker
        let first = await harness.holdNextMeasurement()
        let cancelled = Task { try await worker.evaluate(2) }
        try await withDeadline { try await first.entered.wait() }
        let released = harness.log.checkpoint(for: .cancelled(input: 20))
        cancelled.cancel()
        try await withDeadline { try await released.wait() }

        // A successor pauses while the cancelled evaluation still waits for its measurement.
        let second = await harness.holdNextMeasurement()
        let next = Task { try await worker.evaluate(1) }
        try await withDeadline { try await second.entered.wait() }
        first.release.open()
        await #expect(throws: GuestWorker.Failure.cancelled) {
            try await withDeadline { try await cancelled.value }
        }
        // The old evaluation's cancellation and reading left the successor paused.
        #expect(try await worker.completedSteps() == 0)

        second.release.open()
        #expect(try await withDeadline { try await next.value } == referenceEvaluation(1))
        #expect(try await worker.completedSteps() == 1)
        #expect(
            harness.log.snapshot == [
                .started(count: 2), .paused(input: 20), .cancelled(input: 20),
                .started(count: 1), .paused(input: 10),
                .measured(input: 20, reading: 407), .refusedLateReading(reading: 407),
                .answeredWhilePaused(completedSteps: 0),
                .measured(input: 10, reading: 107), .delivering(reading: 107), .noted(step: 0),
                .finished(result: 214),
            ])
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
