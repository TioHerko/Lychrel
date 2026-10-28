import Foundation
import os

// Arbitrary-precision decimal digits, least-significant digit first.
typealias Digits = [UInt8]

nonisolated func digits(of number: Int) -> Digits {
    if number == 0 { return [0] }
    var n = number
    var result = Digits()
    while n > 0 {
        result.append(UInt8(n % 10))
        n /= 10
    }
    return result
}

nonisolated func decimalString(from d: Digits) -> String {
    let zero = UInt8(ascii: "0")
    return String(d.reversed().map { Character(UnicodeScalar(zero + $0)) })
}

nonisolated func isPalindrome(_ d: Digits) -> Bool {
    var i = d.startIndex
    var j = d.index(before: d.endIndex)
    while i < j {
        if d[i] != d[j] { return false }
        d.formIndex(after: &i)
        d.formIndex(before: &j)
    }
    return true
}

// Reverses the digit order; a trailing zero here is a leading zero on the
// new number (e.g. 310 -> 013), so it gets dropped from the end.
nonisolated func reversed(_ d: Digits) -> Digits {
    var r: Digits = d.reversed()
    while r.count > 1 && r[r.count - 1] == 0 {
        r.removeLast()
    }
    return r
}

// Reads up to 4 digits starting at `i` (LSB-first) as a single base-10000 value,
// treating missing positions past the end of `d` as 0.
nonisolated func chunk4(_ d: Digits, at i: Int) -> UInt16 {
    let d0 = i < d.count ? UInt16(d[i]) : 0
    let d1 = i + 1 < d.count ? UInt16(d[i + 1]) : 0
    let d2 = i + 2 < d.count ? UInt16(d[i + 2]) : 0
    let d3 = i + 3 < d.count ? UInt16(d[i + 3]) : 0
    return d0 + d1 * 10 + d2 * 100 + d3 * 1000
}

// Adds in base 10000 (4 decimal digits at a time) to cut the number of carry
// propagation steps roughly 4x versus adding one decimal digit at a time.
nonisolated func add(_ a: Digits, _ b: Digits) -> Digits {
    var result = Digits()
    let maxCount = max(a.count, b.count)
    result.reserveCapacity(maxCount + 1)
    var i = 0
    var carry: UInt16 = 0
    while i + 4 <= maxCount {
        let sum = chunk4(a, at: i) + chunk4(b, at: i) + carry
        let rem = sum % 10000
        carry = sum / 10000
        result.append(UInt8(rem % 10))
        result.append(UInt8(rem / 10 % 10))
        result.append(UInt8(rem / 100 % 10))
        result.append(UInt8(rem / 1000 % 10))
        i += 4
    }
    while i < maxCount || carry > 0 {
        let da: UInt16 = i < a.count ? UInt16(a[i]) : 0
        let db: UInt16 = i < b.count ? UInt16(b[i]) : 0
        let sum = da + db + carry
        result.append(UInt8(sum % 10))
        carry = sum / 10
        i += 1
    }
    return result
}

public nonisolated struct CheckResult: Sendable {
    public let number: Int
    public let palindrome: String
    public let steps: Int
    public let overflowed: Bool
    public let exceededMaxIter: Bool

    static let placeholder = CheckResult(number: 0, palindrome: "", steps: 0, overflowed: false, exceededMaxIter: false)
}

// Selectable implementation of the reverse-and-add loop.
public nonisolated enum Algorithm: String, CaseIterable, Identifiable, Sendable {
    case digitArray
    case packedBCD

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .digitArray: "Digit array"
        case .packedBCD: "Packed BCD"
        }
    }
}

public nonisolated func check(_ x: Int, maxIterations: Int, algorithm: Algorithm = .packedBCD) -> CheckResult {
    switch algorithm {
    case .digitArray: checkDigitArray(x, maxIterations: maxIterations)
    case .packedBCD: checkPackedBCD(x, maxIterations: maxIterations)
    }
}

nonisolated func checkDigitArray(_ x: Int, maxIterations: Int) -> CheckResult {
    var current = digits(of: x)
    var iterations = 0
    while !isPalindrome(current)
    {
        iterations += 1
        if iterations > maxIterations
        {
            return CheckResult(number: x, palindrome: "", steps: iterations, overflowed: false, exceededMaxIter: true)
        }
        current = add(current, reversed(current))
    }
    return CheckResult(number: x, palindrome: decimalString(from: current), steps: iterations, overflowed: false, exceededMaxIter: false)
}

// MARK: - Packed BCD
//
// Numbers are stored as UInt64 words, least-significant word first, with 16
// decimal digits per word (one per nibble, digit 0 in the low nibble). The top
// word is always non-zero (except for the number 0), and every word past the top
// is zero. The hot loop works on SIMD2<UInt64> pairs of words, so each vector op
// handles 32 digits in one 128-bit NEON register.

private nonisolated let bcdSixes: UInt64 = 0x6666_6666_6666_6666
private nonisolated let bcdNibbleLows: UInt64 = 0x1111_1111_1111_1110
private nonisolated let bcdByteLows: UInt64 = 0x0F0F_0F0F_0F0F_0F0F

// Reverses the order of the 16 nibbles in a word.
@inline(__always)
private nonisolated func nibbleReversed(_ x: UInt64) -> UInt64 {
    let s = x.byteSwapped
    return ((s & bcdByteLows) << 4) | ((s >> 4) & bcdByteLows)
}

// Adds two 16-digit BCD words plus a carry-in (0 or 1) with a handful of
// integer ops: pre-add 6 to every digit so decimal carries become binary
// carries, then take the 6 back off the digits that didn't carry.
@inline(__always)
private nonisolated func bcdAdd(_ a: UInt64, _ b: UInt64, carryIn: UInt64) -> (sum: UInt64, carryOut: UInt64) {
    let (t1, o1) = a.addingReportingOverflow(bcdSixes)
    let (t2a, o2) = t1.addingReportingOverflow(b)
    let (t2, o3) = t2a.addingReportingOverflow(carryIn)
    let carryOut: UInt64 = (o1 || o2 || o3) ? 1 : 0
    // Bit 4i set => no carry into nibble i => nibble i-1 needs its 6 removed.
    let noCarry = ~(t2 ^ t1 ^ b) & bcdNibbleLows
    var correction = (noCarry >> 2) | (noCarry >> 3)
    if carryOut == 0 { correction |= 0x6000_0000_0000_0000 }
    return (t2 &- correction, carryOut)
}

// Number of zero words that must sit below `src` for reverseAndAddBCD's reads.
private nonisolated let bcdPadWords = 4

// Numbers up to this many words take the scalar path: a vector pass has a fixed
// latency that only pays off once there are enough pairs to fill it. Measured
// on an M4 Max, scalar wins up to 6 words and SIMD from about 10.
private nonisolated let bcdScalarMaxWords = 6

// Scalar version of reverseAndAddBCD, with the same contract. Reversing the
// whole 16*count-nibble field and shifting right by the unused top nibbles
// gives the reversal of the actual number; the original's trailing zeros become
// high zeros, so no separate trimming is needed.
@inline(__always)
private nonisolated func reverseAndAddScalar(_ src: UnsafeMutablePointer<UInt64>, count: Int, into dst: UnsafeMutablePointer<UInt64>) -> Bool {
    let shift = src[count - 1].leadingZeroBitCount / 4 * 4
    var difference: UInt64 = 0
    var carry: UInt64 = 0
    var low = nibbleReversed(src[count - 1])
    for j in 0..<count {
        // Word j of the reversal is nibble-reversed word count-1-j shifted down,
        // topped up from word count-2-j (the zero pad word below src for the last).
        let high = nibbleReversed(src[count - 2 - j])
        let a = src[j]
        let b = (low >> shift) | (high << (64 - shift))
        difference |= a ^ b
        (dst[j], carry) = bcdAdd(a, b, carryIn: carry)
        low = high
    }
    dst[count] = carry
    return difference == 0
}

// Reverses all 32 nibbles of a word pair, so lane 0 gets the nibble-reversal of
// lane 1 and vice versa. Compiles to rev64 + ext + shl + usra.
@inline(__always)
private nonisolated func nibbleReversedPair(_ v: SIMD2<UInt64>) -> SIMD2<UInt64> {
    let b = unsafeBitCast(v, to: SIMD16<UInt8>.self)
    let r = SIMD16(b[15], b[14], b[13], b[12], b[11], b[10], b[9], b[8], b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0])
    return unsafeBitCast((r &<< 4) | (r &>> 4), to: SIMD2<UInt64>.self)
}

// One fused pass that checks whether `src` (`count` words) is a palindrome and
// writes src + reverse(src) to `dst` (`count` + 1 words, the top one 0 or 1),
// two words per SIMD op. `src` and `dst` must be 16-byte aligned, with
// `bcdPadWords` zero words below `src` and zeros in src[count] and
// src[count + 1]; writes up to dst[count + 1]. Numbers of up to
// `bcdScalarMaxWords` words go through reverseAndAddScalar instead.
//
// Each word's carry-in is taken to be the carry-out the word below would have
// with no carry-in of its own, which lets every pair be added independently.
// That only goes wrong when a word's digit sums are all exactly 9 and a carry
// arrives, which is detected and the pass redone with reverseAndAddScalar.
private nonisolated func reverseAndAddBCD(_ src: UnsafeMutablePointer<UInt64>, count: Int, into dst: UnsafeMutablePointer<UInt64>) -> Bool {
    if count <= bcdScalarMaxWords {
        return reverseAndAddScalar(src, count: count, into: dst)
    }
    return count & 1 == 0
        ? reverseAndAddPairs(src, count: count, into: dst, parity: EvenWordCount.self)
        : reverseAndAddPairs(src, count: count, into: dst, parity: OddWordCount.self)
}

// The word count's parity as a type, so reverseAndAddPairs gets a specialized
// copy for each with `isOdd` folded to a constant. (Passing a Bool literal to
// each call instead lets the compiler merge them into one unspecialized call.)
private nonisolated protocol WordCountParity {
    static var isOdd: Bool { get }
}
private nonisolated enum EvenWordCount: WordCountParity {
    static var isOdd: Bool { false }
}
private nonisolated enum OddWordCount: WordCountParity {
    static var isOdd: Bool { true }
}

// reverseAndAddBCD's loop.
private nonisolated func reverseAndAddPairs<Parity: WordCountParity>(_ src: UnsafeMutablePointer<UInt64>, count: Int, into dst: UnsafeMutablePointer<UInt64>, parity: Parity.Type) -> Bool {
    let oddCount = Parity.isOdd
    let rawSrc = UnsafeRawPointer(src)
    let rawDst = UnsafeMutableRawPointer(dst)
    @inline(__always) func pair(at i: Int) -> SIMD2<UInt64> {
        rawSrc.loadUnaligned(fromByteOffset: i &* 8, as: SIMD2<UInt64>.self)
    }

    // Same reversal as reverseAndAddScalar: word j of the reversal is the
    // nibble-reversed word count-1-j shifted right by the unused top nibbles,
    // topped up from word count-2-j. The left shift is split as 1 + (63 - shift)
    // so that a shift of 0 clears the high part instead of wrapping to 0.
    let shift = UInt64(src[count - 1].leadingZeroBitCount / 4 * 4)
    let lowShift = SIMD2(repeating: shift)
    let highShift = SIMD2(repeating: 63 &- shift)
    let sixes = SIMD2(repeating: bcdSixes)
    let nibbleLows = SIMD2(repeating: bcdNibbleLows)
    let topSixes = SIMD2<UInt64>(repeating: 0x6000_0000_0000_0000)
    let zero = SIMD2<UInt64>()

    // Pair p covers words 2p and 2p+1, and the pairs reach word `count`, which
    // takes the carry-out. Word j of the reversal is built from nibble-reversed
    // words count-1-j, count-2-j and count-3-j, read only as aligned pairs so
    // each load lines up with a single store from the previous pass and can be
    // forwarded from it. With an odd count the words needed straddle aligned
    // pairs and are stitched together with an ext.
    let pairs = count / 2 + 1
    let top = (count - 1) & ~1
    @inline(__always) func reversalSource(_ p: Int) -> SIMD2<UInt64> {
        nibbleReversedPair(pair(at: top &- 2 &* p))
    }
    // Reversal words 2p and 2p+1, from reversalSource(p) and reversalSource(p + 1).
    @inline(__always) func reversedPair(upper: SIMD2<UInt64>, lower: SIMD2<UInt64>) -> SIMD2<UInt64> {
        let between = SIMD2(upper[1], lower[0])
        let low = oddCount ? between : upper
        let high = oddCount ? lower : between
        return (low &>> lowShift) | ((high &<< 1) &<< highShift)
    }

    // bcdAdd, lane-wise, split in two so a pair's generate (its carry-out with
    // no carry-in) is known before its own carry-in is.
    typealias Partial = (a: SIMD2<UInt64>, b: SIMD2<UInt64>, t1: SIMD2<UInt64>, t2: SIMD2<UInt64>, generate: SIMD2<UInt64>)
    @inline(__always) func begin(_ p: Int, reversed b: SIMD2<UInt64>) -> Partial {
        let a = pair(at: 2 &* p)
        let t1 = a &+ sixes
        let t2 = t1 &+ b
        return (a, b, t1, t2, zero.replacing(with: .max, where: t2 .< t1))
    }
    var difference = zero
    var missedCarries = zero
    // Neither operand nor the sum can reach 0xFFFF..., so a lane carried out
    // exactly when its result is below t1.
    @inline(__always) func finish(_ p: Int, _ x: Partial, generateBelow: SIMD2<UInt64>) {
        let carryIn = SIMD2(generateBelow[1], x.generate[0])
        let sum = x.t2 &- carryIn
        let carryOut = zero.replacing(with: .max, where: sum .< x.t1)
        missedCarries |= carryOut ^ x.generate
        difference |= x.a ^ x.b
        let noCarry = nibbleLows & ~(sum ^ x.t1 ^ x.b)
        let correction = (noCarry &>> 2) | (noCarry &>> 3) | (topSixes & ~carryOut)
        rawDst.storeBytes(of: sum &- correction, toByteOffset: p &* 16, as: SIMD2<UInt64>.self)
    }

    // The next pass starts from this one's outermost pairs (the top word sets
    // its shift, and each end is reversed from the other end), so pairs are
    // finished from both ends inwards to get those done first. The top end runs
    // one pair ahead so it has the generate of the word below.
    var bottomUpper = reversalSource(0)
    var bottomGenerate = zero
    var topUpper = reversalSource(pairs - 1)
    var topPartial = begin(pairs - 1, reversed: reversedPair(upper: topUpper, lower: reversalSource(pairs)))
    for i in 0..<pairs / 2 {
        let q = pairs &- 1 &- i
        let nextUpper = reversalSource(q &- 1)
        let next = begin(q &- 1, reversed: reversedPair(upper: nextUpper, lower: topUpper))
        finish(q, topPartial, generateBelow: next.generate)
        topPartial = next
        topUpper = nextUpper

        let bottomLower = reversalSource(i &+ 1)
        let bottom = begin(i, reversed: reversedPair(upper: bottomUpper, lower: bottomLower))
        finish(i, bottom, generateBelow: bottomGenerate)
        bottomGenerate = bottom.generate
        bottomUpper = bottomLower
    }
    if pairs & 1 == 1 {
        finish(pairs / 2, topPartial, generateBelow: bottomGenerate)
    }

    if missedCarries != zero {
        _ = reverseAndAddScalar(src, count: count, into: dst)
    }
    return difference == zero
}

nonisolated func checkPackedBCD(_ x: Int, maxIterations: Int) -> CheckResult {
    // Each kept add grows the number by at most one digit, and Int has at most
    // 19; reverseAndAddBCD touches 2 words past the top. Rounded up to whole
    // pairs to keep each buffer 16-byte aligned.
    let capacity = ((19 + max(maxIterations, 0)) / 16 + 3 + 1) & ~1
    let bufferWords = bcdPadWords + capacity

    return withUnsafeTemporaryAllocation(byteCount: 2 * bufferWords * 8, alignment: 16) { raw in
        let buffer = raw.bindMemory(to: UInt64.self)
        buffer.initialize(repeating: 0)
        var current = buffer.baseAddress! + bcdPadWords
        var next = current + bufferWords

        var count = 0
        var value = x
        repeat {
            var word: UInt64 = 0
            for k in 0..<16 {
                word |= UInt64(value % 10) << UInt64(4 * k)
                value /= 10
            }
            current[count] = word
            count += 1
        } while value > 0

        var iterations = 0
        while !reverseAndAddBCD(current, count: count, into: next) {
            iterations += 1
            if iterations > maxIterations {
                return CheckResult(number: x, palindrome: "", steps: iterations, overflowed: false, exceededMaxIter: true)
            }
            if next[count] != 0 { count += 1 }
            swap(&current, &next)
        }

        var text = String(current[count - 1], radix: 16)
        for j in stride(from: count - 2, through: 0, by: -1) {
            let word = String(current[j], radix: 16)
            text += String(repeating: "0", count: 16 - word.count) + word
        }
        return CheckResult(number: x, palindrome: text, steps: iterations, overflowed: false, exceededMaxIter: false)
    }
}

public nonisolated func renderProgressBar(completed: Int, total: Int, width: Int = 30) -> String {
    let fraction = total > 0 ? Double(completed) / Double(total) : 1.0
    let filled = Int(fraction * Double(width))
    let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled)
    let percent = Int(fraction * 100)
    return "[\(bar)] \(percent)%"
}

// Thread-safe cancellation signal: read from many concurrent background
// closures, written once from whichever thread owns the Cancel action.
public nonisolated final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public var isCancelled: Bool { state.withLock { $0 } }
    public func cancel() { state.withLock { $0 = true } }
}

public nonisolated struct RunProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentNumber: Int
    public let exceeded: Int
}

public nonisolated struct RunOutcome: Sendable {
    public let results: [CheckResult]
    public let completed: Int
    public let exceeded: Int
    public let wasCancelled: Bool
    public var palindromes: Int { completed - exceeded }
}

fileprivate nonisolated struct ProgressCounts: Sendable {
    var completed = 0
    var exceeded = 0
}

// Safe because each index is written by exactly one concurrentPerform
// iteration, and the buffer outlives the call.
fileprivate nonisolated struct ResultSink: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<CheckResult>
}

// Runs the Lychrel check for every number in lowerBound...upperBound across
// all available cores, reporting throttled progress and honoring cancellation.
public nonisolated func runChecks(
    lowerBound: Int,
    upperBound: Int,
    maxIterations: Int,
    algorithm: Algorithm = .packedBCD,
    progressStride: Int? = nil,
    cancellation: CancellationFlag? = nil,
    onProgress: @escaping @Sendable (RunProgress) -> Void
) -> RunOutcome {
    let count = upperBound - lowerBound + 1
    let stride = progressStride ?? max(1, count / 500)
    let counts = OSAllocatedUnfairLock(initialState: ProgressCounts())

    var results = [CheckResult](repeating: .placeholder, count: count)
    results.withUnsafeMutableBufferPointer { buffer in
        let sink = ResultSink(base: buffer)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            if cancellation?.isCancelled == true { return }

            let x = lowerBound + i
            let result = check(x, maxIterations: maxIterations, algorithm: algorithm)
            sink.base[i] = result

            counts.withLock { c in
                c.completed += 1
                if result.exceededMaxIter { c.exceeded += 1 }
                if c.completed % stride == 0 || c.completed == count {
                    onProgress(RunProgress(completed: c.completed, total: count, currentNumber: x, exceeded: c.exceeded))
                }
            }
        }
    }

    let final = counts.withLock { $0 }
    let wasCancelled = (cancellation?.isCancelled == true) && final.completed < count
    return RunOutcome(results: results, completed: final.completed, exceeded: final.exceeded, wasCancelled: wasCancelled)
}

nonisolated let csvHeader = "number,palindrome,steps,overflowed,exceeded_maxiter"

nonisolated func csvString(for results: [CheckResult]) -> String {
    var lines = [csvHeader]
    lines.reserveCapacity(results.count + 1)
    for result in results {
        lines.append("\(result.number),\(result.palindrome),\(result.steps),\(result.overflowed ? 1 : 0),\(result.exceededMaxIter ? 1 : 0)")
    }
    return lines.joined(separator: "\n") + "\n"
}

public nonisolated func writeCSV(_ results: [CheckResult], toPath path: String) throws {
    try csvString(for: results).write(toFile: path, atomically: true, encoding: .utf8)
}

// Formats a Duration to 5 significant digits, picking a unit (s/ms/µs/ns) so the
// value stays readable instead of falling into scientific notation or a long
// string of leading zeros.
public nonisolated func formatDuration(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    if seconds >= 1 {
        return String(format: "%.5g s", seconds)
    } else if seconds * 1_000 >= 1 {
        return String(format: "%.5g ms", seconds * 1_000)
    } else if seconds * 1_000_000 >= 1 {
        return String(format: "%.5g µs", seconds * 1_000_000)
    } else {
        return String(format: "%.5g ns", seconds * 1_000_000_000)
    }
}
