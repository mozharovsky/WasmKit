// Runs the guest from Guest/resumable_guest.swift on a worker actor. Each `measure` call in the
// guest pauses the invocation while the main actor produces the reading.
//
// Usage: swift run resumable-host-call [path/to/resumable_guest.wasm]

import Foundation
import ResumableEmbedding

/// The main actor's way to reach the worker, which exists only after its measurement closure.
@MainActor
final class WorkerReference {
    var worker: GuestWorker?
    /// A checkpoint that the next measurement waits for before it answers.
    var holdNextMeasurement: (entered: Checkpoint, release: Checkpoint)?
}

@main
struct Demo {
    @MainActor
    static func main() async throws {
        let path = CommandLine.arguments.dropFirst().first ?? ".build/guest/resumable_guest.wasm"
        let wasm = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        let log = EventLog()
        let instrument = Instrument()
        let reference = WorkerReference()
        let worker = try GuestWorker(wasm: wasm, log: log) { input in
            if let hold = reference.holdNextMeasurement {
                reference.holdNextMeasurement = nil
                hold.entered.open()
                try? await hold.release.wait()
            }
            // The worker waits for this closure without blocking, so it can answer here.
            if let worker = reference.worker {
                _ = try? await withDeadline { try await worker.completedSteps() }
            }
            let reading = instrument.measure(input)
            log.record(.measured(input: input, reading: reading))
            return reading
        }
        reference.worker = worker

        print("1. evaluate(3) pauses at each measure call and continues with the main actor's reading")
        let result = try await withDeadline { try await worker.evaluate(3) }
        print(describe(log.snapshot))
        print("result \(result), native reference \(referenceEvaluation(3))")
        print("guest completed steps \(try await worker.completedSteps()), main actor measured \(instrument.measuredInputs)")

        print("\n2. A cancelled invocation cannot take the reading meant for it after another one pauses")
        let first = (entered: Checkpoint(), release: Checkpoint())
        reference.holdNextMeasurement = first
        let before = log.snapshot.count
        let cancelled = Task { try await worker.evaluate(2) }
        try await withDeadline { try await first.entered.wait() }
        print("cancel paused invocation: \(await worker.cancelPausedInvocation())")
        let second = (entered: Checkpoint(), release: Checkpoint())
        reference.holdNextMeasurement = second
        let next = Task { try await worker.evaluate(1) }
        try await withDeadline { try await second.entered.wait() }
        first.release.open()
        do {
            _ = try await withDeadline { try await cancelled.value }
            print("the cancelled invocation finished, which is wrong")
        } catch {
            print("late reading: \(error)")
        }
        second.release.open()
        let nextResult = try await withDeadline { try await next.value }
        print(describe(Array(log.snapshot[before...])))
        print("next invocation result \(nextResult), native reference \(referenceEvaluation(1))")
        print("guest completed steps \(try await worker.completedSteps()), main actor measured \(instrument.measuredInputs)")
    }

    static func describe(_ events: [Event]) -> String {
        events.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}
