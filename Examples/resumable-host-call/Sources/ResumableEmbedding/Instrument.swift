/// A main-actor model that produces the readings the guest asks for.
///
/// It stands for state that only the main actor may touch, such as an object of a UI framework.
@MainActor
public final class Instrument {
    /// The inputs measured so far, in call order.
    public private(set) var measuredInputs: [Int32] = []

    public init() {}

    /// Returns the reading for `input` and remembers that it was measured.
    ///
    /// - Parameter input: The value the guest asks about.
    /// - Returns: The reading, which is ``reading(for:)`` of `input`.
    public func measure(_ input: Int32) -> Int32 {
        MainActor.preconditionIsolated()
        measuredInputs.append(input)
        return Self.reading(for: input)
    }

    /// Returns the reading for `input` without recording it.
    ///
    /// - Parameter input: The value the guest asks about.
    /// - Returns: `input * input + 7` with wrapping arithmetic.
    public nonisolated static func reading(for input: Int32) -> Int32 {
        input &* input &+ 7
    }
}

/// Returns what the guest's `evaluate(count)` returns, computed natively.
///
/// The arithmetic mirrors `Guest/resumable_guest.swift`, with each reading taken directly from
/// ``Instrument/reading(for:)``.
///
/// - Parameter count: The number of steps.
/// - Returns: The expected guest result.
public func referenceEvaluation(_ count: Int32) -> Int32 {
    var readings: [Int32] = []
    var weighted: Int32 = 0
    for step in 0..<count {
        let reading = Instrument.reading(for: count &* 10 &+ step)
        readings.append(reading)
        weighted &+= reading &* (step &+ 1)
    }
    return weighted &+ readings.reduce(0, &+)
}
