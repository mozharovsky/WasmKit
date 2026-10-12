#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import WASI
import WasmKit
import WasmKitWASI

/// One engine configuration that the probe compares.
///
/// Every main variant translates lazily, uses the default stack, and runs without fuel. Only the
/// dispatch model and the presence of an execution controller differ. The mprotect variant and
/// the fuel variants are reported separately. Fuel charges sit where a checkpoint of a
/// controlled direct store would sit, so their cost estimates that design.
struct Variant: Sendable, Hashable {
    let name: String
    let threadingModel: EngineConfiguration.ThreadingModel
    let memoryBoundsChecking: EngineConfiguration.MemoryBoundsChecking
    let controlled: Bool
    var fuel = false

    static let token = Variant(name: "token", threadingModel: .token, memoryBoundsChecking: .software, controlled: false)
    static let tokenControl = Variant(
        name: "token-control", threadingModel: .token, memoryBoundsChecking: .software, controlled: true)
    static let direct = Variant(name: "direct", threadingModel: .direct, memoryBoundsChecking: .software, controlled: false)
    static let directControl = Variant(
        name: "direct-control", threadingModel: .direct, memoryBoundsChecking: .software, controlled: true)
    static let directMprotect = Variant(
        name: "direct-mprotect", threadingModel: .direct, memoryBoundsChecking: .mprotect, controlled: false)

    static let tokenFuel = Variant(
        name: "token-fuel", threadingModel: .token, memoryBoundsChecking: .software, controlled: false, fuel: true)
    static let directFuel = Variant(
        name: "direct-fuel", threadingModel: .direct, memoryBoundsChecking: .software, controlled: false, fuel: true)

    /// The polling interval of every controlled variant in this process.
    static var pollingInterval: UInt32 = 1024

    static let all: [Variant] = [.token, .tokenControl, .direct, .directControl, .directMprotect, .tokenFuel, .directFuel]

    static func named(_ name: String) throws -> Variant {
        guard let variant = all.first(where: { $0.name == name }) else {
            throw ProbeError("unknown variant \(name)")
        }
        return variant
    }

    func makeEngine(compilationMode: EngineConfiguration.CompilationMode = .lazy) -> Engine {
        Engine(
            configuration: EngineConfiguration(
                threadingModel: threadingModel,
                compilationMode: compilationMode,
                memoryBoundsChecking: memoryBoundsChecking,
                fuelMetering: fuel
            ))
    }

    /// The configuration the engine actually chose, which can differ from the request.
    static func describe(_ engine: Engine, control: ExecutionControl?) -> String {
        let configuration = engine.configuration
        let threading = configuration.threadingModel == .direct ? "direct" : "token"
        let bounds = configuration.memoryBoundsChecking == .mprotect ? "mprotect" : "software"
        let compilation = configuration.compilationMode == .lazy ? "lazy" : "eager"
        let polling = control.map { "\($0.pollingInterval)" } ?? "none"
        return "threading=\(threading) bounds=\(bounds) compilation=\(compilation) stack=\(configuration.stackSize)"
            + " fuel=\(configuration.fuelMetering) control=\(control != nil) polling=\(polling)"
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A fixed byte stream for the guest's random requests, so every instance hashes the same way.
struct FixedRandom: RandomBufferGenerator {
    var state: UInt64 = 0x1234_5678_9ABC_DEF1

    mutating func fill(buffer: UnsafeMutableBufferPointer<UInt8>) {
        for index in buffer.indices {
            buffer[index] = UInt8(truncatingIfNeeded: ProbeMath.next(&state))
        }
    }
}

/// The host side of the probe imports, with the counters the harness checks after each call.
final class HostState {
    var noteChecksum: UInt64 = 0
    var noteCount: UInt64 = 0
    var importCalls: UInt64 = 0
    var memory: Memory?

    func reset() {
        noteChecksum = 0
        noteCount = 0
        importCalls = 0
    }
}

/// The native reference that answers the same services without an interpreter.
final class NativeHost: ProbeHost {
    var noteChecksum: UInt64 = 0
    var noteCount: UInt64 = 0

    func mix(_ a: UInt32, _ b: UInt32) -> UInt32 { ProbeMath.mix(a, b) }
    func digest(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 { ProbeMath.fnv1a(bytes) }
    func lookup(_ key: UInt64) -> UInt64 { ProbeMath.lookup(key) }
    func note(_ value: UInt64) {
        noteChecksum = ProbeMath.fold(noteChecksum, value)
        noteCount &+= 1
    }
}

/// An instantiated and initialized guest for one variant.
final class GuestInstance {
    let variant: Variant
    let engine: Engine
    let store: Store
    let control: ExecutionControl?
    let instance: Instance
    let state: HostState
    let memory: Memory
    var stack: ExecutionStack
    private let functions: [String: Function]
    /// The WASI bridge, which has to be closed before it is released.
    private let wasi: WASIBridgeToHost

    /// Durations of the steps, in nanoseconds, for the cold measurement.
    let instantiateNanoseconds: UInt64
    let initializeNanoseconds: UInt64

    init(module: Module, variant: Variant, engine: Engine) throws {
        let started = MonotonicTime.now()
        let control: ExecutionControl?
        let store: Store
        if variant.controlled {
            let created = try ExecutionControl(pollingInterval: Variant.pollingInterval)
            control = created
            store = try Store(engine: engine, executionControl: created)
        } else {
            control = nil
            store = Store(engine: engine)
        }
        if variant.fuel {
            // Unlimited in practice. The charges are what the fuel variants measure.
            store.fuel = Fuel(remaining: .max)
        }
        let state = HostState()
        let wasi = try WASIBridgeToHost(
            args: ["probe"],
            environment: ["SWIFT_DETERMINISTIC_HASHING": "1"],
            fileSystem: .host().withStdio(),
            randomGenerator: FixedRandom()
        )
        let instance: Instance
        let memory: Memory
        var functions: [String: Function] = [:]
        let instantiated: UInt64
        let initialized: UInt64
        do {
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            Self.defineProbeImports(&imports, store: store, state: state)
            instance = try module.instantiate(store: store, imports: imports)
            guard let exported = instance.exports[memory: "memory"] else {
                throw ProbeError("the guest exports no memory")
            }
            memory = exported
            state.memory = memory
            for name in ProbeExport.allCases {
                guard let function = instance.exports[function: name.rawValue] else {
                    throw ProbeError("the guest does not export \(name.rawValue)")
                }
                functions[name.rawValue] = function
            }
            instantiated = MonotonicTime.now()
            try wasi.initialize(instance)
            initialized = MonotonicTime.now()
        } catch {
            try? wasi.close()
            throw error
        }

        self.variant = variant
        self.engine = engine
        self.store = store
        self.control = control
        self.state = state
        self.instance = instance
        self.memory = memory
        self.functions = functions
        self.wasi = wasi
        self.stack = ExecutionStack(engine: engine)
        instantiateNanoseconds = instantiated - started
        initializeNanoseconds = initialized - instantiated
    }

    deinit {
        // The imports capture the state, and the memory keeps the store's allocator, which owns
        // the imports. Dropping the memory here breaks that cycle, so a released instance frees
        // its store.
        state.memory = nil
        try? wasi.close()
    }

    func function(_ name: ProbeExport) -> Function {
        functions[name.rawValue].unsafelyUnwrapped
    }

    /// Calls an export on the instance's own stack, which the warm measurements use.
    @inline(__always)
    func call(_ function: Function, _ arguments: [Value]) throws -> [Value] {
        try function.invoke(arguments, on: &stack)
    }

    var memoryPages: Int { memory.byteCount / 65_536 }

    private static func defineProbeImports(_ imports: inout Imports, store: Store, state: HostState) {
        imports.define(
            module: "probe", name: "mix",
            Function(store: store, parameters: [.i32, .i32], results: [.i32], raw: { _, parameters, results in
                state.importCalls &+= 1
                results[0] = .i32(ProbeMath.mix(parameters[0].i32, parameters[1].i32))
            }))
        imports.define(
            module: "probe", name: "digest",
            Function(store: store, parameters: [.i32, .i32], results: [.i32], raw: { _, parameters, results in
                state.importCalls &+= 1
                guard let memory = state.memory else { throw ProbeError("digest before instantiation") }
                let offset = UInt(parameters[0].i32)
                let count = Int(parameters[1].i32)
                guard Int(offset) + count <= memory.byteCount else {
                    throw ProbeError("digest outside guest memory")
                }
                let hash = memory.withUnsafeBufferPointer(offset: offset, count: count) { raw in
                    ProbeMath.fnv1a(raw.assumingMemoryBound(to: UInt8.self))
                }
                results[0] = .i32(hash)
            }))
        imports.define(
            module: "probe", name: "lookup",
            Function(store: store, parameters: [.i64], results: [.i64], raw: { _, parameters, results in
                state.importCalls &+= 1
                results[0] = .i64(ProbeMath.lookup(parameters[0].i64))
            }))
        imports.define(
            module: "probe", name: "block",
            Function(store: store, parameters: [.i32], results: [], raw: { _, parameters, _ in
                state.importCalls &+= 1
                usleep(parameters[0].i32)
            }))
        imports.define(
            module: "probe", name: "note",
            Function(store: store, parameters: [.i64], results: [], raw: { _, parameters, _ in
                state.importCalls &+= 1
                state.noteChecksum = ProbeMath.fold(state.noteChecksum, parameters[0].i64)
                state.noteCount &+= 1
            }))
    }
}

enum ProbeExport: String, CaseIterable {
    case compute = "probe_compute"
    case collections = "probe_collections"
    case text = "probe_text"
    case tiny = "probe_tiny"
    case chatter = "probe_chatter"
    case longAction = "probe_long_action"
    case spin = "probe_spin"
    case blocking = "probe_blocking"
}

/// A monotonic clock in nanoseconds.
enum MonotonicTime {
    @inline(__always)
    static func now() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &time)
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
    }
}
