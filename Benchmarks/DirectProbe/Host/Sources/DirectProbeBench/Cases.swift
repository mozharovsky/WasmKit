import WasmKit

/// The sizes of the warm workloads, chosen once per run and shared by every variant.
struct Sizes {
    var scale: Int32 = 4
    var batch: Int = 2_000
    var chatter: Int32 = 100_000
    var actionRounds: Int32 = 12
    var seed: Int32 = 17

    /// The unit of the growing action, 64 KiB, and of its translation pass, which does not grow.
    static let growingUnit: Int32 = 65_536
    static let translatingUnit: Int32 = 1_024
}

/// The outcome of one timed sample.
struct SampleResult {
    let nanoseconds: UInt64
    /// How many calls or imports the sample performed, for the per-unit column.
    let units: Int
    let ok: Bool
    let detail: String
}

/// A warm measurement that runs the same work on every variant and checks every answer.
protocol WarmCase {
    var name: String { get }
    func sample(_ guest: GuestInstance, context: CaseContext) throws -> SampleResult
}

/// What a case may need besides its instance: the module and engine for a fresh instance.
struct CaseContext {
    let module: Module
    let engine: Engine
}

/// A single long call of a computational export whose answer the native build predicts.
struct LongCallCase: WarmCase {
    let name: String
    let export: ProbeExport
    let arguments: [Value]
    let expected: UInt64

    init(name: String, export: ProbeExport, scale: Int32, seed: Int32, reference: (Int32, Int32) -> UInt64) {
        self.name = name
        self.export = export
        arguments = [Value(signed: scale), Value(signed: seed)]
        expected = reference(scale, seed)
    }

    func sample(_ guest: GuestInstance, context: CaseContext) throws -> SampleResult {
        let function = guest.function(export)
        let started = MonotonicTime.now()
        let results = try guest.call(function, arguments)
        let elapsed = MonotonicTime.now() - started
        let actual = results.first?.i64
        let ok = results.count == 1 && actual == expected
        return SampleResult(
            nanoseconds: elapsed, units: 1, ok: ok,
            detail: ok ? "" : "\(name): got \(String(describing: actual)), expected \(expected)")
    }
}

/// Many short calls into a small export, timed as one batch.
struct TinyBatchCase: WarmCase {
    let name: String
    let arguments: [[Value]]
    let expected: UInt64
    /// Whether each call allocates its own stack through `invoke(_:)`, as Hako's bridge does.
    let allocatesStack: Bool

    init(name: String, batch: Int, seed: Int32, allocatesStack: Bool) {
        self.name = name
        self.allocatesStack = allocatesStack
        var state = ProbeMath.seed(seed)
        var arguments: [[Value]] = []
        var expected: UInt64 = 0
        arguments.reserveCapacity(batch)
        for _ in 0..<batch {
            let a = UInt32(truncatingIfNeeded: ProbeMath.next(&state))
            let b = UInt32(truncatingIfNeeded: ProbeMath.next(&state))
            arguments.append([.i32(a), .i32(b)])
            expected = ProbeMath.fold(expected, UInt64(tinyWorkload(a, b)))
        }
        self.arguments = arguments
        self.expected = expected
    }

    func sample(_ guest: GuestInstance, context: CaseContext) throws -> SampleResult {
        let function = guest.function(.tiny)
        var checksum: UInt64 = 0
        var calls = 0
        let started = MonotonicTime.now()
        if allocatesStack {
            for arguments in self.arguments {
                let results = try function.invoke(arguments)
                checksum = ProbeMath.fold(checksum, UInt64(results[0].i32))
                calls &+= 1
            }
        } else {
            for arguments in self.arguments {
                let results = try guest.call(function, arguments)
                checksum = ProbeMath.fold(checksum, UInt64(results[0].i32))
                calls &+= 1
            }
        }
        let elapsed = MonotonicTime.now() - started
        let ok = checksum == expected && calls == arguments.count
        return SampleResult(
            nanoseconds: elapsed, units: arguments.count, ok: ok,
            detail: ok ? "" : "\(name): checksum \(checksum) after \(calls) calls, expected \(expected)")
    }
}

/// The same batch loop around a native closure, which prices the harness itself.
struct HarnessOverhead {
    let arguments: [[Value]]
    let answer: [Value] = [.i32(7)]

    init(batch: Int) {
        arguments = Array(repeating: [.i32(1), .i32(2)], count: batch)
    }

    @inline(never)
    func sample(_ body: ([Value]) throws -> [Value]) rethrows -> UInt64 {
        var checksum: UInt64 = 0
        let started = MonotonicTime.now()
        for arguments in self.arguments {
            let results = try body(arguments)
            checksum = ProbeMath.fold(checksum, UInt64(results[0].i32))
        }
        let elapsed = MonotonicTime.now() - started
        if checksum == 0x5EED { print("unreachable") }
        return elapsed
    }
}

/// Expected answers of a host-calling workload, from the native reference.
struct HostCallExpectation {
    let result: UInt64
    let noteChecksum: UInt64
    let noteCount: UInt64

    func check(_ guest: GuestInstance, results: [Value], name: String) -> (Bool, String) {
        let actual = results.first?.i64
        let ok = results.count == 1 && actual == result
            && guest.state.noteChecksum == noteChecksum && guest.state.noteCount == noteCount
        let detail =
            ok
            ? ""
            : "\(name): result \(String(describing: actual)) notes \(guest.state.noteCount)/\(guest.state.noteChecksum),"
                + " expected \(result) notes \(noteCount)/\(noteChecksum)"
        return (ok, detail)
    }
}

/// A guest loop that calls a pure import and a recording import many times.
struct ChatterCase: WarmCase {
    let name = "chatter"
    let count: Int32
    let seed: Int32
    let expectation: HostCallExpectation

    init(count: Int32, seed: Int32) {
        self.count = count
        self.seed = seed
        let host = NativeHost()
        let result = chatterWorkload(host, count: count, seed: seed)
        expectation = HostCallExpectation(result: result, noteChecksum: host.noteChecksum, noteCount: host.noteCount)
    }

    func sample(_ guest: GuestInstance, context: CaseContext) throws -> SampleResult {
        let function = guest.function(.chatter)
        let arguments = [Value(signed: count), Value(signed: seed)]
        guest.state.reset()
        let started = MonotonicTime.now()
        let results = try guest.call(function, arguments)
        let elapsed = MonotonicTime.now() - started
        var (ok, detail) = expectation.check(guest, results: results, name: name)
        let imports = UInt64(count) + expectation.noteCount
        if guest.state.importCalls != imports {
            ok = false
            detail += " imports \(guest.state.importCalls), expected \(imports)"
        }
        return SampleResult(nanoseconds: elapsed, units: Int(imports), ok: ok, detail: detail)
    }
}

/// The longer action with several imports, either on a reused instance or on a fresh one.
struct LongActionCase: WarmCase {
    let name: String
    let rounds: Int32
    let seed: Int32
    let fresh: Bool
    let expectation: HostCallExpectation

    init(rounds: Int32, seed: Int32, fresh: Bool) {
        name = fresh ? "long-action-fresh" : "long-action-warm"
        self.rounds = rounds
        self.seed = seed
        self.fresh = fresh
        let host = NativeHost()
        let result = longActionWorkload(host, rounds: rounds, seed: seed, unit: Sizes.growingUnit)
        expectation = HostCallExpectation(result: result, noteChecksum: host.noteChecksum, noteCount: host.noteCount)
    }

    func sample(_ guest: GuestInstance, context: CaseContext) throws -> SampleResult {
        let target: GuestInstance
        if fresh {
            // A new instance translates the action with a unit that does not grow memory, so the
            // timed call pays for growth and imports rather than for translation.
            target = try GuestInstance(module: context.module, variant: guest.variant, engine: context.engine)
            let warmup = [Value(signed: 10), Value(signed: seed &+ 1), Value(signed: Sizes.translatingUnit)]
            _ = try target.call(target.function(.longAction), warmup)
        } else {
            target = guest
        }
        let function = target.function(.longAction)
        let arguments = [Value(signed: rounds), Value(signed: seed), Value(signed: Sizes.growingUnit)]
        let pagesBefore = target.memoryPages
        target.state.reset()
        let started = MonotonicTime.now()
        let results = try target.call(function, arguments)
        let elapsed = MonotonicTime.now() - started
        var (ok, detail) = expectation.check(target, results: results, name: name)
        let pagesAfter = target.memoryPages
        if fresh && pagesAfter <= pagesBefore {
            ok = false
            detail += " memory did not grow (\(pagesBefore) -> \(pagesAfter) pages)"
        }
        return SampleResult(nanoseconds: elapsed, units: 1, ok: ok, detail: detail)
    }
}

enum Cases {
    static func warm(_ sizes: Sizes) -> [any WarmCase] {
        [
            LongCallCase(name: "compute", export: .compute, scale: sizes.scale, seed: sizes.seed) {
                computeWorkload(scale: $0, seed: $1)
            },
            LongCallCase(name: "collections", export: .collections, scale: sizes.scale, seed: sizes.seed) {
                collectionsWorkload(scale: $0, seed: $1)
            },
            LongCallCase(name: "text", export: .text, scale: sizes.scale, seed: sizes.seed) {
                textWorkload(scale: $0, seed: $1)
            },
            TinyBatchCase(name: "tiny-batch", batch: sizes.batch, seed: sizes.seed, allocatesStack: false),
            TinyBatchCase(name: "tiny-invoke-alloc", batch: sizes.batch, seed: sizes.seed, allocatesStack: true),
            ChatterCase(count: sizes.chatter, seed: sizes.seed),
            LongActionCase(rounds: sizes.actionRounds, seed: sizes.seed, fresh: false),
            LongActionCase(rounds: sizes.actionRounds, seed: sizes.seed, fresh: true),
        ]
    }
}
