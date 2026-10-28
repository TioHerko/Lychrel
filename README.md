# Lychrel

Searches a range of numbers for Lychrel candidates using the reverse-and-add process: reverse a number's digits, add the result to the original, and repeat until you hit a palindrome. Numbers that don't reach one within a set number of steps are flagged as likely Lychrel numbers (196 is the famous smallest candidate).

Arithmetic is arbitrary-precision (decimal digit arrays added in base-10000 chunks), so values can grow as large as they need to. The range is checked in parallel across all CPU cores.

## Targets

- **lychrel**: command-line tool (`crunch/`)
- **LychrelGUI**: SwiftUI macOS app (`LychrelGUI/`)

Both link the shared core logic from **LychrelKit** (`LychrelKit/`), a local Swift package. Its `Package.swift` builds the core optimized even in Debug, since the SIMD code is several times slower unoptimized.

## Command-line usage

```
lychrel [-lower N] [-bound N] [-max N] [-csv PATH]
```

| Flag | Default | Meaning |
|---|---|---|
| `-lower` | `1` | First number to check |
| `-bound` | `1000000` | Last number to check |
| `-max` | `1000` | Reverse-and-add steps before giving up on a number |
| `-csv` | `results.csv` | Output file |

It shows a live progress bar while running, then prints a summary (palindromes found, Lychrel candidates, and calc/sort/write timings).

## GUI

Set the bounds, max iterations and CSV path, then press Start. The window shows live progress and a running count of Lychrel candidates, and finishes with a summary and a Reveal in Finder button. Cancel stops a run early and writes no CSV.

- "Use commas" displays the number fields with thousands separators.
- Settings are remembered between launches.

## CSV output

One row per number checked:

```
number,palindrome,steps,overflowed,exceeded_maxiter
```

- `palindrome`: the palindrome reached, blank if none was found
- `steps`: reverse-and-add iterations performed
- `overflowed`: always `0` now that arithmetic is arbitrary-precision (kept for schema compatibility)
- `exceeded_maxiter`: `1` if the number hit the `-max` limit

## Building

Open `Lychrel.xcodeproj` in Xcode and build either scheme (Release for the CLI, LychrelGUI for the app). Requires macOS 26.3 or later.

## Licence

MIT. See [LICENSE](LICENSE).
