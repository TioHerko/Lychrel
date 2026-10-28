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

nonisolated func check(_ x: Int, maxIterations: Int) -> CheckResult {
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
            let result = check(x, maxIterations: maxIterations)
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
