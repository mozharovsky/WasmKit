#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import WasmKit

// The harness of the direct-execution probe. See ../../README.md for the modes and the output.

struct Options {
    var mode = ""
    var wasm = ""
    var variants: [Variant] = [.token, .tokenControl, .direct]
    var rounds = 12
    var warmup = 2
    var samples = 5
    var seconds = 4.0
    var sizes = Sizes()

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        guard let mode = iterator.next() else { throw ProbeError(usage) }
        options.mode = mode
        func value(_ flag: String) throws -> String {
            guard let value = iterator.next() else { throw ProbeError("\(flag) needs a value") }
            return value
        }
        func number<T: FixedWidthInteger>(_ flag: String) throws -> T {
            guard let parsed = T(try value(flag)) else { throw ProbeError("\(flag) needs an integer") }
            return parsed
        }
        while let argument = iterator.next() {
            switch argument {
            case "--wasm": options.wasm = try value(argument)
            case "--variants": options.variants = try value(argument).split(separator: ",").map { try Variant.named(String($0)) }
            case "--variant": options.variants = [try Variant.named(try value(argument))]
            case "--rounds": options.rounds = try number(argument)
            case "--warmup": options.warmup = try number(argument)
            case "--samples": options.samples = try number(argument)
            case "--seconds": options.seconds = Double(try value(argument)) ?? 4
            case "--scale": options.sizes.scale = try number(argument)
            case "--batch": options.sizes.batch = try number(argument)
            case "--chatter": options.sizes.chatter = try number(argument)
            case "--action-rounds": options.sizes.actionRounds = try number(argument)
            case "--seed": options.sizes.seed = try number(argument)
            default: throw ProbeError("unknown argument \(argument)\n\(usage)")
            }
        }
        guard !options.wasm.isEmpty else { throw ProbeError("--wasm is required\n\(usage)") }
        return options
    }

    static let usage = """
        usage: DirectProbeBench <verify|warm|cold|spin> --wasm <ProbeGuest.wasm> [options]
          --variants a,b,c     token, token-control, direct, direct-mprotect (warm, verify)
          --variant v          one variant (cold, spin)
          --rounds n           paired rounds of the warm measurement
          --warmup n           discarded samples before each case in each turn
          --samples n          timed samples of each case in each turn
          --scale n --batch n --chatter n --action-rounds n --seed n
          --seconds s          duration of the spin mode
        """
}

func readModule(_ path: String) throws -> [UInt8] {
    guard let file = fopen(path, "rb") else { throw ProbeError("cannot open \(path)") }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let count = fread(&chunk, 1, chunk.count, file)
        if count == 0 { break }
        bytes.append(contentsOf: chunk[0..<count])
    }
    return bytes
}

func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

func report(_ line: String) {
    fputs(line + "\n", stderr)
}

/// Rotations of the variant order and their reversals, so that every variant takes every
/// position equally often across rounds.
func orders(_ variants: [Variant]) -> [[Variant]] {
    var result: [[Variant]] = []
    for shift in 0..<variants.count {
        let rotated = Array(variants[shift...] + variants[..<shift])
        result.append(rotated)
        result.append(rotated.reversed())
    }
    return result
}

// MARK: - Modes

func runWarm(_ options: Options, module: Module) throws -> Bool {
    let cases = Cases.warm(options.sizes)
    var engines: [Variant: Engine] = [:]
    var guests: [Variant: GuestInstance] = [:]
    for variant in options.variants {
        let engine = variant.makeEngine()
        engines[variant] = engine
        let guest = try GuestInstance(module: module, variant: variant, engine: engine)
        guests[variant] = guest
        emit("# variant,\(variant.name),\(Variant.describe(engine, control: guest.control))")
    }
    let overhead = HarnessOverhead(batch: options.sizes.batch)
    let stub: ([Value]) -> [Value] = { _ in overhead.answer }
    emit("kind,round,position,variant,case,sample,nanoseconds,units,ok")
    var allOK = true
    let schedule = orders(options.variants)
    for round in 0..<options.rounds {
        for _ in 0..<options.warmup { _ = overhead.sample(stub) }
        for index in 0..<options.samples {
            let elapsed = overhead.sample(stub)
            emit("sample,\(round),0,harness,harness-overhead,\(index),\(elapsed),\(options.sizes.batch),1")
        }
        for (position, variant) in schedule[round % schedule.count].enumerated() {
            let guest = guests[variant].unsafelyUnwrapped
            let context = CaseContext(module: module, engine: engines[variant].unsafelyUnwrapped)
            for warmCase in cases {
                for _ in 0..<options.warmup {
                    let result = try warmCase.sample(guest, context: context)
                    if !result.ok {
                        allOK = false
                        report("MISMATCH warmup \(variant.name) \(result.detail)")
                    }
                }
                for index in 0..<options.samples {
                    let result = try warmCase.sample(guest, context: context)
                    if !result.ok {
                        allOK = false
                        report("MISMATCH \(variant.name) round \(round) \(result.detail)")
                    }
                    emit(
                        "sample,\(round),\(position),\(variant.name),\(warmCase.name),\(index),"
                            + "\(result.nanoseconds),\(result.units),\(result.ok ? 1 : 0)")
                }
            }
        }
        report("round \(round + 1)/\(options.rounds) done")
    }
    for variant in options.variants {
        let guest = guests[variant].unsafelyUnwrapped
        emit("# memory,\(variant.name),\(guest.memoryPages) pages")
    }
    return allOK
}

/// Measures one fresh process: parse, instantiate, initialize, and the first and second call of
/// every export at a small size. The first call includes lazy translation.
func runCold(_ options: Options, bytes: [UInt8]) throws -> Bool {
    let variant = options.variants[0]
    let parseStarted = MonotonicTime.now()
    let module = try parseWasm(bytes: bytes)
    let parsed = MonotonicTime.now() - parseStarted
    let engine = variant.makeEngine()
    let guest = try GuestInstance(module: module, variant: variant, engine: engine)
    emit("# variant,\(variant.name),\(Variant.describe(engine, control: guest.control))")
    emit("kind,variant,step,nanoseconds,ok")
    emit("cold,\(variant.name),parse,\(parsed),1")
    emit("cold,\(variant.name),instantiate,\(guest.instantiateNanoseconds),1")
    emit("cold,\(variant.name),initialize,\(guest.initializeNanoseconds),1")
    var sizes = Sizes()
    sizes.scale = 1
    sizes.batch = 200
    sizes.chatter = 5_000
    sizes.actionRounds = 10
    let cases: [any WarmCase] = Cases.warm(sizes).filter { $0.name != "long-action-fresh" }
    let context = CaseContext(module: module, engine: engine)
    var allOK = true
    for pass in ["first", "second"] {
        for warmCase in cases {
            let result = try warmCase.sample(guest, context: context)
            if !result.ok {
                allOK = false
                report("MISMATCH cold \(variant.name) \(result.detail)")
            }
            emit("cold,\(variant.name),\(pass)-\(warmCase.name),\(result.nanoseconds),\(result.ok ? 1 : 0)")
        }
    }
    return allOK
}

/// Checks every export against the native reference across inputs, on every requested variant.
func runVerify(_ options: Options, module: Module) throws -> Bool {
    var allOK = true
    var checks = 0
    var answers: [String: [String: String]] = [:]
    func check(_ ok: Bool, _ variant: Variant, _ detail: @autoclosure () -> String) {
        checks += 1
        if !ok {
            allOK = false
            report("MISMATCH verify \(variant.name) \(detail())")
        }
    }
    for variant in options.variants {
        let engine = variant.makeEngine()
        // Two instances in turn, so a second store sees the same answers after the first one ran.
        for generation in 0..<2 {
            let guest = try GuestInstance(module: module, variant: variant, engine: engine)
            if generation == 0 {
                emit("# variant,\(variant.name),\(Variant.describe(engine, control: guest.control))")
            }
            for scale: Int32 in [1, 2, 3] {
                for seed: Int32 in [1, 7, -5, .max] {
                    let inputs = [Value(signed: scale), Value(signed: seed)]
                    let pairs: [(ProbeExport, (Int32, Int32) -> UInt64)] = [
                        (.compute, { computeWorkload(scale: $0, seed: $1) }),
                        (.collections, { collectionsWorkload(scale: $0, seed: $1) }),
                        (.text, { textWorkload(scale: $0, seed: $1) }),
                    ]
                    for (export, reference) in pairs {
                        let expected = reference(scale, seed)
                        let results = try guest.call(guest.function(export), inputs)
                        let actual = results.first?.i64
                        check(
                            actual == expected, variant,
                            "\(export.rawValue)(\(scale), \(seed)) = \(String(describing: actual)), expected \(expected)")
                        answers["\(export.rawValue)(\(scale),\(seed))", default: [:]][variant.name] = "\(String(describing: actual))"
                    }
                }
            }
            var state = ProbeMath.seed(99)
            var edges: [(UInt32, UInt32)] = [(0, 0), (.max, .max), (0x8000_0000, 1), (63, 64), (64, 0x7FFF_FFFF)]
            for _ in 0..<4_096 {
                edges.append((UInt32(truncatingIfNeeded: ProbeMath.next(&state)), UInt32(truncatingIfNeeded: ProbeMath.next(&state))))
            }
            for (a, b) in edges {
                let results = try guest.call(guest.function(.tiny), [.i32(a), .i32(b)])
                let expected = tinyWorkload(a, b)
                check(results.count == 1 && results[0].i32 == expected, variant, "tiny(\(a), \(b)) = \(results), expected \(expected)")
            }
            for count: Int32 in [0, 1, 15, 16, 17, 1_000, 50_000] {
                let host = NativeHost()
                let expected = chatterWorkload(host, count: count, seed: 3)
                guest.state.reset()
                let results = try guest.call(guest.function(.chatter), [Value(signed: count), Value(signed: 3)])
                let ok = results.first?.i64 == expected && guest.state.noteCount == host.noteCount
                    && guest.state.noteChecksum == host.noteChecksum
                    && guest.state.importCalls == UInt64(count) + host.noteCount
                check(ok, variant, "chatter(\(count)) = \(results) notes \(guest.state.noteCount), expected \(expected) notes \(host.noteCount)")
            }
            for (rounds, unit) in [(Int32(0), Sizes.translatingUnit), (1, Sizes.translatingUnit), (9, Sizes.translatingUnit), (24, Sizes.growingUnit), (24, Sizes.growingUnit)] {
                let host = NativeHost()
                let expected = longActionWorkload(host, rounds: rounds, seed: 5, unit: unit)
                guest.state.reset()
                let pagesBefore = guest.memoryPages
                let results = try guest.call(guest.function(.longAction), [Value(signed: rounds), Value(signed: 5), Value(signed: unit)])
                let ok = results.first?.i64 == expected && guest.state.noteCount == host.noteCount
                    && guest.state.noteChecksum == host.noteChecksum
                check(ok, variant, "long_action(\(rounds), unit \(unit)) = \(results), expected \(expected)")
                emit("# pages,\(variant.name),\(generation),long_action(\(rounds);\(unit)),\(pagesBefore),\(guest.memoryPages)")
            }
        }
    }
    // Every variant has to agree with every other one, not only with the reference.
    for (input, byVariant) in answers.sorted(by: { $0.key < $1.key }) where Set(byVariant.values).count != 1 {
        allOK = false
        report("DISAGREEMENT \(input): \(byVariant)")
    }
    emit("# verify,checks=\(checks),ok=\(allOK)")
    return allOK
}

/// Keeps one variant busy for a fixed time, so a sampler can see which dispatch loop runs.
func runSpin(_ options: Options, module: Module) throws -> Bool {
    let variant = options.variants[0]
    let engine = variant.makeEngine()
    let guest = try GuestInstance(module: module, variant: variant, engine: engine)
    emit("# variant,\(variant.name),\(Variant.describe(engine, control: guest.control))")
    emit("# pid,\(getpid())")
    let expected = computeWorkload(scale: options.sizes.scale, seed: options.sizes.seed)
    let arguments = [Value(signed: options.sizes.scale), Value(signed: options.sizes.seed)]
    let deadline = MonotonicTime.now() + UInt64(options.seconds * 1e9)
    var calls = 0
    var allOK = true
    while MonotonicTime.now() < deadline {
        let results = try guest.call(guest.function(.compute), arguments)
        if results.first?.i64 != expected { allOK = false }
        calls += 1
    }
    emit("# spin,\(variant.name),calls=\(calls),ok=\(allOK)")
    return allOK
}

do {
    let options = try Options.parse(CommandLine.arguments)
    let bytes = try readModule(options.wasm)
    let ok: Bool
    switch options.mode {
    case "warm": ok = try runWarm(options, module: try parseWasm(bytes: bytes))
    case "cold": ok = try runCold(options, bytes: bytes)
    case "verify": ok = try runVerify(options, module: try parseWasm(bytes: bytes))
    case "spin": ok = try runSpin(options, module: try parseWasm(bytes: bytes))
    default: throw ProbeError(Options.usage)
    }
    exit(ok ? 0 : 1)
} catch {
    report("error: \(error)")
    exit(2)
}
