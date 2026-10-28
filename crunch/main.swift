import Foundation
import LychrelKit

let defaultLowerBound = 1
let defaultUpperBound = 1_000_000
let defaultMaxIterations = 1000
let defaultCSVPath = "results.csv"

func intArg(named name: String, default defaultValue: Int) -> Int {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: name), flagIndex + 1 < args.count else {
        return defaultValue
    }
    return Int(args[flagIndex + 1]) ?? defaultValue
}

func stringArg(named name: String, default defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: name), flagIndex + 1 < args.count else {
        return defaultValue
    }
    return args[flagIndex + 1]
}

let lowerBound = intArg(named: "-lower", default: defaultLowerBound)
let upperBound = intArg(named: "-bound", default: defaultUpperBound)
let maxIterations = intArg(named: "-max", default: defaultMaxIterations)
let csvPath = stringArg(named: "-csv", default: defaultCSVPath)
let algorithm = Algorithm(rawValue: stringArg(named: "-algo", default: Algorithm.packedBCD.rawValue)) ?? .packedBCD

let clock = ContinuousClock()

var outcome: RunOutcome!
let calcDuration = clock.measure {
    outcome = runChecks(lowerBound: lowerBound, upperBound: upperBound, maxIterations: maxIterations, algorithm: algorithm) { p in
        let bar = renderProgressBar(completed: p.completed, total: p.total)
        print("\rChecking \(p.currentNumber) \(bar) exceeded maxiter: \(p.exceeded)", terminator: "")
        fflush(stdout)
    }
}
print("")

var results = outcome.results

let sortDuration = clock.measure {
    results.sort { $0.number < $1.number }
}

let writeDuration = clock.measure {
    try? writeCSV(results, toPath: csvPath)
}

print("Checked \(outcome.completed) numbers from \(lowerBound) to \(upperBound) (max \(maxIterations) iterations each).")
print("Algorithm: \(algorithm.displayName)")
print("Palindromes found: \(outcome.palindromes)")
print("Exceeded max iterations: \(outcome.exceeded)")
print("Calc phase: \(formatDuration(calcDuration))")
print("Sort phase: \(formatDuration(sortDuration))")
print("Write phase: \(formatDuration(writeDuration))")
print("Results written to \(csvPath)")
