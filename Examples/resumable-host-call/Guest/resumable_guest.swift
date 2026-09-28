// A guest whose synchronous import is answered by work that the host finishes later.
//
// Build it with `Guest/build.sh`, which records the exact compiler command.

/// Asks the host for a reading of `input`.
///
/// The guest sees an ordinary synchronous call. The host may pause the invocation here and
/// continue it once the reading is available.
@_extern(wasm, module: "native", name: "measure")
@_extern(c)
func measure(_ input: Int32) -> Int32

/// Tells the host that step `step` finished. The host answers synchronously.
@_extern(wasm, module: "native", name: "note")
@_extern(c)
func note(_ step: Int32)

/// The number of steps finished by every call to `evaluate` in this instance.
nonisolated(unsafe) var completedSteps: Int32 = 0

/// Combines `count` readings, weighting each by its position.
///
/// The readings live in a heap array and the running totals in locals, so a paused invocation
/// has to keep both until it continues.
@_expose(wasm, "evaluate")
@_cdecl("evaluate")
public func evaluate(_ count: Int32) -> Int32 {
    var readings: [Int32] = []
    var weighted: Int32 = 0
    for step in 0..<count {
        let reading = measure(count &* 10 &+ step)
        readings.append(reading)
        weighted &+= reading &* (step &+ 1)
        completedSteps &+= 1
        note(step)
    }
    return weighted &+ readings.reduce(0, &+)
}

/// Returns the number of steps finished so far.
@_expose(wasm, "completed_steps")
@_cdecl("completed_steps")
public func completedStepCount() -> Int32 {
    completedSteps
}
