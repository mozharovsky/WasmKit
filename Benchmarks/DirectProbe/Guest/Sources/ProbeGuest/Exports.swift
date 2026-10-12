// The guest side of the probe: host imports and the exported entry points.

@_extern(wasm, module: "probe", name: "mix")
@_extern(c)
func _probeMix(_ a: UInt32, _ b: UInt32) -> UInt32

@_extern(wasm, module: "probe", name: "digest")
@_extern(c)
func _probeDigest(_ pointer: UInt32, _ count: UInt32) -> UInt32

@_extern(wasm, module: "probe", name: "lookup")
@_extern(c)
func _probeLookup(_ key: UInt64) -> UInt64

@_extern(wasm, module: "probe", name: "note")
@_extern(c)
func _probeNote(_ value: UInt64)

@_extern(wasm, module: "probe", name: "block")
@_extern(c)
func _probeBlock(_ microseconds: UInt32)

/// Answers workload host services through the module's imports.
struct ImportedHost: ProbeHost {
    @inline(__always)
    func mix(_ a: UInt32, _ b: UInt32) -> UInt32 { _probeMix(a, b) }

    @inline(__always)
    func digest(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let address = UInt32(truncatingIfNeeded: UInt(bitPattern: bytes.baseAddress))
        return _probeDigest(address, UInt32(truncatingIfNeeded: bytes.count))
    }

    @inline(__always)
    func lookup(_ key: UInt64) -> UInt64 { _probeLookup(key) }

    @inline(__always)
    func note(_ value: UInt64) { _probeNote(value) }
}

@_expose(wasm, "probe_compute")
@_cdecl("probe_compute")
public func probeCompute(_ scale: Int32, _ seed: Int32) -> Int64 {
    Int64(bitPattern: computeWorkload(scale: scale, seed: seed))
}

@_expose(wasm, "probe_collections")
@_cdecl("probe_collections")
public func probeCollections(_ scale: Int32, _ seed: Int32) -> Int64 {
    Int64(bitPattern: collectionsWorkload(scale: scale, seed: seed))
}

@_expose(wasm, "probe_text")
@_cdecl("probe_text")
public func probeText(_ scale: Int32, _ seed: Int32) -> Int64 {
    Int64(bitPattern: textWorkload(scale: scale, seed: seed))
}

@_expose(wasm, "probe_tiny")
@_cdecl("probe_tiny")
public func probeTiny(_ a: Int32, _ b: Int32) -> Int32 {
    Int32(bitPattern: tinyWorkload(UInt32(bitPattern: a), UInt32(bitPattern: b)))
}

@_expose(wasm, "probe_chatter")
@_cdecl("probe_chatter")
public func probeChatter(_ count: Int32, _ seed: Int32) -> Int64 {
    Int64(bitPattern: chatterWorkload(ImportedHost(), count: count, seed: seed))
}

@_expose(wasm, "probe_long_action")
@_cdecl("probe_long_action")
public func probeLongAction(_ rounds: Int32, _ seed: Int32, _ unit: Int32) -> Int64 {
    Int64(bitPattern: longActionWorkload(ImportedHost(), rounds: rounds, seed: seed, unit: unit))
}

/// The value the spin exports read on every iteration, so the optimizer keeps their loops.
nonisolated(unsafe) var probeSpinLimit: UInt64 = .max

/// Calls a blocking import in a loop until the host stops the store, so a stop arrives while
/// native code runs. Used only by interruption checks.
@_expose(wasm, "probe_blocking")
@_cdecl("probe_blocking")
public func probeBlocking(_ microseconds: Int32) -> Int64 {
    var calls: UInt64 = 0
    while calls < probeSpinLimit {
        _probeBlock(UInt32(bitPattern: microseconds))
        calls &+= 1
    }
    return Int64(bitPattern: calls)
}

/// Loops until the host stops the store. Used only by interruption checks.
@_expose(wasm, "probe_spin")
@_cdecl("probe_spin")
public func probeSpin(_ seed: Int32) -> Int64 {
    var state = ProbeMath.seed(seed)
    var count: UInt64 = 0
    while count < probeSpinLimit {
        state = ProbeMath.next(&state)
        count &+= 1
    }
    return Int64(bitPattern: state)
}
