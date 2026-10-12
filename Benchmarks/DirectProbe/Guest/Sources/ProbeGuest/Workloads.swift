// The workloads of the direct-execution probe.
//
// This file is compiled twice. The guest package builds it for wasm32 in Release, and the host
// harness builds the same file natively to compute the expected answer of every call. Everything
// here therefore uses fixed-width integers, wrapping arithmetic, and order-independent or sorted
// aggregates, so that a 32-bit guest and a 64-bit host agree bit for bit.

/// The services a workload needs from its host.
///
/// The guest answers them through imports, and the native reference answers them directly.
protocol ProbeHost {
    /// Mixes two words, standing in for a pure host computation.
    func mix(_ a: UInt32, _ b: UInt32) -> UInt32
    /// Hashes bytes that the host reads from the caller's memory.
    func digest(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32
    /// Looks a key up in a host table.
    func lookup(_ key: UInt64) -> UInt64
    /// Records a value in host state without answering.
    func note(_ value: UInt64)
}

/// The pure functions that both sides of a host call share.
enum ProbeMath {
    /// One xorshift64* step, used as the deterministic input source of every workload.
    @inline(__always)
    static func next(_ state: inout UInt64) -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// A seed that is never zero, because xorshift stays at zero forever.
    static func seed(_ value: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: value)) &* 0x9E37_79B9_7F4A_7C15) | 1
    }

    static func mix(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var x = a ^ (b &* 0x85EB_CA6B)
        x ^= x >> 13
        x = x &* 0xC2B2_AE35
        x ^= x >> 16
        return x &+ b
    }

    static func fnv1a(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return hash
    }

    static func lookup(_ key: UInt64) -> UInt64 {
        var x = key &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// Folds a value into a running checksum.
    @inline(__always)
    static func fold(_ checksum: UInt64, _ value: UInt64) -> UInt64 {
        (checksum ^ value) &* 0x0000_0100_0000_01B3
    }
}

// MARK: - Computation and branches

/// A register machine whose program counts primes by trial division.
///
/// An interpreter inside the interpreter gives a dense mix of data-dependent branches, small
/// array reads and integer arithmetic, which is what guest-side control flow looks like.
struct RegisterMachine {
    enum Op: UInt8 {
        case loadImmediate, add, addImmediate, multiply, remainder, branchLess, branchEqual, jump, halt
    }

    struct Instruction {
        var op: Op
        var a: UInt8
        var b: UInt8
        var c: UInt8
        var immediate: Int32
    }

    /// r0 is the limit, r1 the candidate, r2 the divisor, r3 the prime count, r4 a scratch value.
    static let primeCounter: [Instruction] = [
        Instruction(op: .loadImmediate, a: 1, b: 0, c: 0, immediate: 2),  // 0: candidate = 2
        Instruction(op: .loadImmediate, a: 3, b: 0, c: 0, immediate: 0),  // 1: count = 0
        Instruction(op: .branchLess, a: 1, b: 0, c: 0, immediate: 4),  // 2: candidate < limit -> 4
        Instruction(op: .halt, a: 0, b: 0, c: 0, immediate: 0),  // 3
        Instruction(op: .loadImmediate, a: 2, b: 0, c: 0, immediate: 2),  // 4: divisor = 2
        Instruction(op: .multiply, a: 4, b: 2, c: 2, immediate: 0),  // 5: scratch = divisor^2
        Instruction(op: .branchLess, a: 1, b: 4, c: 0, immediate: 12),  // 6: candidate < d^2 -> prime
        Instruction(op: .remainder, a: 4, b: 1, c: 2, immediate: 0),  // 7: scratch = cand % d
        Instruction(op: .loadImmediate, a: 5, b: 0, c: 0, immediate: 0),  // 8
        Instruction(op: .branchEqual, a: 4, b: 5, c: 0, immediate: 13),  // 9: divisible -> next
        Instruction(op: .addImmediate, a: 2, b: 2, c: 0, immediate: 1),  // 10: divisor += 1
        Instruction(op: .jump, a: 0, b: 0, c: 0, immediate: 5),  // 11
        Instruction(op: .addImmediate, a: 3, b: 3, c: 0, immediate: 1),  // 12: count += 1
        Instruction(op: .addImmediate, a: 1, b: 1, c: 0, immediate: 1),  // 13: candidate += 1
        Instruction(op: .jump, a: 0, b: 0, c: 0, immediate: 2),  // 14
    ]

    var registers = [Int64](repeating: 0, count: 8)
    var steps: UInt64 = 0

    mutating func run(_ program: [Instruction], limit: Int64) -> Int64 {
        registers[0] = limit
        var pc = 0
        while true {
            let instruction = program[pc]
            steps &+= 1
            pc += 1
            switch instruction.op {
            case .loadImmediate:
                registers[Int(instruction.a)] = Int64(instruction.immediate)
            case .add:
                registers[Int(instruction.a)] = registers[Int(instruction.b)] &+ registers[Int(instruction.c)]
            case .addImmediate:
                registers[Int(instruction.a)] = registers[Int(instruction.b)] &+ Int64(instruction.immediate)
            case .multiply:
                registers[Int(instruction.a)] = registers[Int(instruction.b)] &* registers[Int(instruction.c)]
            case .remainder:
                registers[Int(instruction.a)] = registers[Int(instruction.b)] % registers[Int(instruction.c)]
            case .branchLess:
                if registers[Int(instruction.a)] < registers[Int(instruction.b)] { pc = Int(instruction.immediate) }
            case .branchEqual:
                if registers[Int(instruction.a)] == registers[Int(instruction.b)] { pc = Int(instruction.immediate) }
            case .jump:
                pc = Int(instruction.immediate)
            case .halt:
                return registers[3]
            }
        }
    }
}

/// Classifies generated bytes with a small tokenizer state machine.
func tokenize(_ bytes: [UInt8]) -> UInt64 {
    enum State { case space, word, number, symbol }
    var state = State.space
    var words: UInt64 = 0
    var numbers: UInt64 = 0
    var symbols: UInt64 = 0
    var value: UInt64 = 0
    var checksum: UInt64 = 0
    for byte in bytes {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            if state != .word { words &+= 1 }
            state = .word
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            if state != .number {
                numbers &+= 1
                value = 0
            }
            value = value &* 10 &+ UInt64(byte - UInt8(ascii: "0"))
            state = .number
        case UInt8(ascii: " "), UInt8(ascii: "\n"):
            if state == .number { checksum = ProbeMath.fold(checksum, value) }
            state = .space
        default:
            symbols &+= 1
            state = .symbol
        }
    }
    return ProbeMath.fold(ProbeMath.fold(ProbeMath.fold(checksum, words), numbers), symbols)
}

/// Counts Collatz steps, a loop whose trip count depends on the data.
func collatz(below limit: UInt32) -> UInt64 {
    var longest: UInt64 = 0
    var total: UInt64 = 0
    var n: UInt32 = 1
    while n < limit {
        var x = UInt64(n)
        var steps: UInt64 = 0
        while x != 1 {
            x = (x & 1) == 0 ? x >> 1 : 3 &* x &+ 1
            steps &+= 1
        }
        total &+= steps
        if steps > longest { longest = steps }
        n += 1
    }
    return ProbeMath.fold(total, longest)
}

/// Runs the three computational kernels at a size proportional to `scale`.
func computeWorkload(scale: Int32, seed: Int32) -> UInt64 {
    let scale = max(1, Int(scale))
    var machine = RegisterMachine()
    let primes = machine.run(RegisterMachine.primeCounter, limit: Int64(2_000 * scale))

    var state = ProbeMath.seed(seed)
    let alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyz0123456789 ,.;+-*/()\n".utf8)
    var text = [UInt8]()
    text.reserveCapacity(4_000 * scale)
    for _ in 0..<(4_000 * scale) {
        text.append(alphabet[Int(ProbeMath.next(&state) % UInt64(alphabet.count))])
    }
    let tokens = tokenize(text)
    let steps = collatz(below: UInt32(1_500 * scale))
    return ProbeMath.fold(ProbeMath.fold(ProbeMath.fold(UInt64(primes), machine.steps), tokens), steps)
}

// MARK: - Collections, generics and memory

protocol Shape {
    func area() -> Double
    var corners: UInt32 { get }
}

struct Rectangle: Shape {
    var width: Double
    var height: Double
    func area() -> Double { width * height }
    var corners: UInt32 { 4 }
}

struct Triangle: Shape {
    var base: Double
    var height: Double
    func area() -> Double { base * height / 2 }
    var corners: UInt32 { 3 }
}

struct Polygon: Shape {
    var points: [Double]
    func area() -> Double {
        var sum = 0.0
        for point in points { sum += point * point }
        return sum.squareRoot()
    }
    var corners: UInt32 { UInt32(points.count) }
}

struct Record: Comparable {
    var key: UInt32
    var id: UInt32
    var weight: Double
    var tags: [UInt16]

    static func < (lhs: Record, rhs: Record) -> Bool {
        (lhs.key, lhs.id) < (rhs.key, rhs.id)
    }

    static func == (lhs: Record, rhs: Record) -> Bool {
        lhs.key == rhs.key && lhs.id == rhs.id
    }
}

/// A generic fold that the optimizer specializes for each element type it sees.
@inline(never)
func checksum<S: Sequence>(_ sequence: S, _ project: (S.Element) -> UInt64) -> UInt64 {
    var value: UInt64 = 0
    for element in sequence { value = ProbeMath.fold(value, project(element)) }
    return value
}

/// A generic container that keeps its elements sorted, to exercise generic method dispatch.
struct SortedBag<Element: Comparable> {
    private(set) var storage: [Element] = []

    mutating func insert(_ element: Element) {
        var low = 0
        var high = storage.count
        while low < high {
            let middle = (low + high) / 2
            if storage[middle] < element { low = middle + 1 } else { high = middle }
        }
        storage.insert(element, at: low)
    }
}

func collectionsWorkload(scale: Int32, seed: Int32) -> UInt64 {
    let count = 1_500 * max(1, Int(scale))
    var state = ProbeMath.seed(seed)

    var records: [Record] = []
    records.reserveCapacity(count)
    for index in 0..<count {
        let key = UInt32(truncatingIfNeeded: ProbeMath.next(&state) % 997)
        var tags: [UInt16] = []
        for _ in 0..<Int(ProbeMath.next(&state) % 5) {
            tags.append(UInt16(truncatingIfNeeded: ProbeMath.next(&state)))
        }
        let weight = Double(ProbeMath.next(&state) % 10_000) / 100
        records.append(Record(key: key, id: UInt32(index), weight: weight, tags: tags))
    }
    records.sort()

    var groups: [UInt32: [UInt32]] = [:]
    for record in records { groups[record.key, default: []].append(record.id) }
    let groupSummary = checksum(groups.keys.sorted()) { key in
        UInt64(key) &* 31 &+ UInt64(groups[key]?.count ?? 0)
    }

    var seen = Set<UInt64>()
    for record in records {
        for tag in record.tags { seen.insert(UInt64(tag) &* UInt64(record.key)) }
    }

    var shapes: [any Shape] = []
    for record in records.prefix(count / 2) {
        switch record.id % 3 {
        case 0: shapes.append(Rectangle(width: record.weight, height: Double(record.key)))
        case 1: shapes.append(Triangle(base: record.weight, height: Double(record.tags.count)))
        default: shapes.append(Polygon(points: record.tags.map { Double($0 % 128) }))
        }
    }
    var corners: UInt64 = 0
    var area = 0.0
    for shape in shapes {
        corners &+= UInt64(shape.corners)
        area += shape.area()
    }

    var bag = SortedBag<UInt32>()
    for record in records.prefix(count / 4) { bag.insert(record.key ^ record.id) }

    let filtered = records.lazy.filter { $0.weight > 50 }.map { UInt64($0.id) &* 3 }
    let recordSummary = checksum(records) { UInt64($0.key) << 32 | UInt64($0.id) }

    var result = ProbeMath.fold(recordSummary, groupSummary)
    result = ProbeMath.fold(result, UInt64(seen.count))
    result = ProbeMath.fold(result, corners)
    result = ProbeMath.fold(result, UInt64(area.rounded()))
    result = ProbeMath.fold(result, checksum(bag.storage) { UInt64($0) })
    result = ProbeMath.fold(result, checksum(filtered) { $0 })
    return result
}

// MARK: - Strings

let probeWords: [String] = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
    "lambda", "mu", "café", "naïve", "über", "straße", "Ωmega", "σigma", "日本", "🦊fox",
]

func textWorkload(scale: Int32, seed: Int32) -> UInt64 {
    let sentences = 120 * max(1, Int(scale))
    var state = ProbeMath.seed(seed)
    var document = ""
    for index in 0..<sentences {
        let length = 4 + Int(ProbeMath.next(&state) % 9)
        var words: [String] = []
        for _ in 0..<length {
            words.append(probeWords[Int(ProbeMath.next(&state) % UInt64(probeWords.count))])
        }
        let number = ProbeMath.next(&state) % 1_000
        document += "\(index): \(words.joined(separator: " ")) [\(number)].\n"
    }

    var counts: [String: UInt64] = [:]
    var characters: UInt64 = 0
    var longest: Substring = ""
    for line in document.split(separator: "\n") {
        for token in line.split(separator: " ") {
            let word = token.lowercased()
            counts[word, default: 0] += 1
            characters &+= UInt64(token.count)
            if token.count > longest.count || (token.count == longest.count && token < longest) {
                longest = token
            }
        }
    }

    let summary = checksum(counts.keys.sorted()) { key in
        var hash: UInt64 = UInt64(counts[key] ?? 0)
        for unit in key.utf8 { hash = ProbeMath.fold(hash, UInt64(unit)) }
        return hash
    }
    let reversed = String(document.reversed().prefix(64))
    var tail: UInt64 = 0
    for scalar in reversed.unicodeScalars { tail = ProbeMath.fold(tail, UInt64(scalar.value)) }

    var result = ProbeMath.fold(summary, characters)
    result = ProbeMath.fold(result, UInt64(document.utf8.count))
    result = ProbeMath.fold(result, UInt64(longest.utf8.count))
    result = ProbeMath.fold(result, tail)
    result = ProbeMath.fold(result, document.contains("🦊fox") ? 1 : 0)
    return result
}

// MARK: - Short calls

let tinyTable: [UInt32] = (0..<64).map { UInt32($0) &* 0x9E37_79B9 }

/// A short export with a little work and a global read, called many times by the host.
func tinyWorkload(_ a: UInt32, _ b: UInt32) -> UInt32 {
    let entry = tinyTable[Int(a & 63)]
    return (a &* 31 &+ b) ^ entry
}

// MARK: - Host calls

/// Calls a pure import in a tight loop and records every sixteenth value in host state.
func chatterWorkload<Host: ProbeHost>(_ host: Host, count: Int32, seed: Int32) -> UInt64 {
    var value = UInt32(truncatingIfNeeded: ProbeMath.seed(seed))
    var notes: UInt64 = 0
    for index in 0..<UInt32(max(0, count)) {
        value = host.mix(value, index)
        if index & 15 == 0 {
            host.note(UInt64(value))
            notes &+= 1
        }
    }
    return ProbeMath.fold(UInt64(value), notes)
}

/// A longer action that grows memory, passes buffers to the host and folds its answers.
///
/// Up to eight buffers stay alive at once, with sizes from `unit` to 32 times `unit` bytes. With a
/// unit of 64 KiB a fresh instance has to grow its linear memory while the action runs. A small
/// unit runs every code path without growing, which the harness uses to translate a fresh
/// instance before it times the growing call.
func longActionWorkload<Host: ProbeHost>(_ host: Host, rounds: Int32, seed: Int32, unit: Int32) -> UInt64 {
    var state = ProbeMath.seed(seed)
    var live: [[UInt8]] = []
    var result: UInt64 = 0
    for round in 0..<Int(max(0, rounds)) {
        let size = max(8, Int(unit)) << (round % 6)
        var buffer = [UInt8](repeating: 0, count: size)
        buffer.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset + 8 <= raw.count {
                raw.storeBytes(of: ProbeMath.next(&state).littleEndian, toByteOffset: offset, as: UInt64.self)
                offset += 8
            }
        }
        let digest = buffer.withUnsafeBufferPointer { host.digest($0) }
        let answer = host.lookup(UInt64(digest) ^ UInt64(round))
        result = ProbeMath.fold(result, answer)
        live.append(buffer)
        if live.count > 8 { live.removeFirst() }
        host.note(result)
    }
    var tail: UInt64 = 0
    for buffer in live { tail = ProbeMath.fold(tail, UInt64(buffer[buffer.count / 2])) }
    return ProbeMath.fold(result, tail)
}
