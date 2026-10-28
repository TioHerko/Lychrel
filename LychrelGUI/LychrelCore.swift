// Duplicate of crunch/LychrelCore.swift — keep both copies in sync.
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

nonisolated struct CheckResult: Sendable {
    let number: Int
    let palindrome: String
    let steps: Int
    let overflowed: Bool
    let exceededMaxIter: Bool

    static let placeholder = CheckResult(number: 0, palindrome: "", steps: 0, overflowed: false, exceededMaxIter: false)
}

// Selectable implementation of the reverse-and-add loop.
nonisolated enum Algorithm: String, CaseIterable, Identifiable, Sendable {
    case digitArray
    case packedBCD

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .digitArray: "Digit array"
        case .packedBCD: "Packed BCD"
        }
    }
}

nonisolated func check(_ x: Int, maxIterations: Int, algorithm: Algorithm = .packedBCD) -> CheckResult {
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
// word is always non-zero (except for the number 0).

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

// Writes the digit-reversal of `src` (`count` words) into `dst` (`count` words).
// Reversing the whole 16*count-nibble field and shifting right by the unused
// top nibbles gives the reversal of the actual number; the original's trailing
// zeros become high zeros, so no separate trimming is needed.
@inline(__always)
private nonisolated func reverseBCD(_ src: UnsafePointer<UInt64>, count: Int, into dst: UnsafeMutablePointer<UInt64>) {
    let shift = src[count - 1].leadingZeroBitCount / 4 * 4
    for j in 0..<count {
        let low = nibbleReversed(src[count - 1 - j])
        let high = j + 1 < count ? nibbleReversed(src[count - 2 - j]) : 0
        dst[j] = (low >> shift) | (high << (64 - shift))
    }
}

nonisolated func checkPackedBCD(_ x: Int, maxIterations: Int) -> CheckResult {
    // Each add grows the number by at most one digit, and Int has at most 19.
    let capacity = (19 + maxIterations) / 16 + 2

    return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: capacity * 2) { buffer in
        let current = buffer.baseAddress!
        let reversed = current + capacity

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
        while true {
            reverseBCD(current, count: count, into: reversed)

            var isPalindrome = true
            for j in 0..<count where current[j] != reversed[j] {
                isPalindrome = false
                break
            }
            if isPalindrome { break }

            iterations += 1
            if iterations > maxIterations {
                return CheckResult(number: x, palindrome: "", steps: iterations, overflowed: false, exceededMaxIter: true)
            }

            var carry: UInt64 = 0
            for j in 0..<count {
                (current[j], carry) = bcdAdd(current[j], reversed[j], carryIn: carry)
            }
            if carry != 0 {
                current[count] = 1
                count += 1
            }
        }

        var text = String(current[count - 1], radix: 16)
        for j in stride(from: count - 2, through: 0, by: -1) {
            let word = String(current[j], radix: 16)
            text += String(repeating: "0", count: 16 - word.count) + word
        }
        return CheckResult(number: x, palindrome: text, steps: iterations, overflowed: false, exceededMaxIter: false)
    }
}

nonisolated func renderProgressBar(completed: Int, total: Int, width: Int = 30) -> String {
    let fraction = total > 0 ? Double(completed) / Double(total) : 1.0
    let filled = Int(fraction * Double(width))
    let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled)
    let percent = Int(fraction * 100)
    return "[\(bar)] \(percent)%"
}

// Thread-safe cancellation signal: read from many concurrent background
// closures, written once from whichever thread owns the Cancel action.
nonisolated final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

nonisolated struct RunProgress: Sendable {
    let completed: Int
    let total: Int
    let currentNumber: Int
    let exceeded: Int
}

nonisolated struct RunOutcome: Sendable {
    let results: [CheckResult]
    let completed: Int
    let exceeded: Int
    let wasCancelled: Bool
    var palindromes: Int { completed - exceeded }
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
nonisolated func runChecks(
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

nonisolated func writeCSV(_ results: [CheckResult], toPath path: String) throws {
    try csvString(for: results).write(toFile: path, atomically: true, encoding: .utf8)
}

// Formats a Duration to 5 significant digits, picking a unit (s/ms/µs/ns) so the
// value stays readable instead of falling into scientific notation or a long
// string of leading zeros.
nonisolated func formatDuration(_ duration: Duration) -> String {
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
