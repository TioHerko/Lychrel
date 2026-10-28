//
//  ContentView.swift
//  LychrelGUI
//
//  Created by Peter Whysall on 14/10/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LychrelKit

private func defaultCSVPath() -> String {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    return documents.appendingPathComponent("lychrel-results.csv").path
}

private func parsedPositiveInt(_ text: String) -> Int? {
    let cleaned = text.filter { !" ,_".contains($0) }
    guard let value = Int(cleaned), value > 0 else { return nil }
    return value
}

private func isValidCSVPath(_ text: String) -> Bool {
    let expanded = (text as NSString).expandingTildeInPath
    return !expanded.isEmpty && expanded.hasPrefix("/")
}

// Groups a run of digits with comma thousands separators, e.g. "1000000" -> "1,000,000".
private func groupedWithCommas(_ digits: String) -> String {
    var result = ""
    for (i, char) in digits.reversed().enumerated() {
        if i > 0 && i % 3 == 0 { result.append(",") }
        result.append(char)
    }
    return String(result.reversed())
}

private let rowLabelWidth: CGFloat = 100
private let statLabelWidth: CGFloat = 170

// A right-aligned numeric text field that optionally displays comma thousands
// separators. `digits` is always the canonical, comma-free value; the caret is
// tracked by "digit count before cursor" rather than raw character offset, so
// it stays put through reformatting instead of jumping to the end on every
// keystroke (which is what a plain SwiftUI TextField + onChange would do).
private struct GroupedNumberField: NSViewRepresentable {
    @Binding var digits: String
    var useCommas: Bool

    private func displayString(for digits: String) -> String {
        useCommas ? groupedWithCommas(digits) : digits
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.alignment = .right
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.stringValue = displayString(for: digits)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        let display = displayString(for: digits)
        if nsView.stringValue != display {
            nsView.stringValue = display
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GroupedNumberField
        init(_ parent: GroupedNumberField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let fieldEditor = field.currentEditor() as? NSTextView
            let caretLocation = fieldEditor?.selectedRange().location ?? field.stringValue.count

            let rawText = field.stringValue
            let prefix = String(rawText.prefix(caretLocation))
            let digitsBeforeCaret = prefix.filter { $0.isNumber }.count

            let newDigits = rawText.filter { $0.isNumber }
            parent.digits = newDigits

            let displayText = parent.displayString(for: newDigits)
            if field.stringValue != displayText {
                field.stringValue = displayText
            }

            var newLocation = displayText.count
            if digitsBeforeCaret == 0 {
                newLocation = 0
            } else {
                var count = 0
                for (idx, char) in displayText.enumerated() {
                    if char.isNumber {
                        count += 1
                        if count == digitsBeforeCaret {
                            newLocation = idx + 1
                            break
                        }
                    }
                }
            }
            fieldEditor?.setSelectedRange(NSRange(location: newLocation, length: 0))
        }
    }
}

struct ContentView: View {
    @AppStorage("lowerBound") private var lowerText = "1"
    @AppStorage("upperBound") private var boundText = "1000000"
    @AppStorage("maxIterations") private var maxText = "1000"
    @AppStorage("csvPath") private var csvPath = defaultCSVPath()
    @AppStorage("useThousandsSeparators") private var useCommas = false
    @AppStorage("algorithm") private var algorithmRaw = Algorithm.packedBCD.rawValue

    @State private var model = RunModel()

    private var lowerDigits: Binding<String> {
        Binding(get: { lowerText.filter { $0.isNumber } }, set: { lowerText = $0 })
    }
    private var boundDigits: Binding<String> {
        Binding(get: { boundText.filter { $0.isNumber } }, set: { boundText = $0 })
    }
    private var maxDigits: Binding<String> {
        Binding(get: { maxText.filter { $0.isNumber } }, set: { maxText = $0 })
    }

    private var algorithm: Binding<Algorithm> {
        Binding(
            get: { Algorithm(rawValue: algorithmRaw) ?? .packedBCD },
            set: { algorithmRaw = $0.rawValue }
        )
    }

    private var lowerBound: Int? { parsedPositiveInt(lowerText) }
    private var upperBound: Int? { parsedPositiveInt(boundText) }
    private var maxIterations: Int? { parsedPositiveInt(maxText) }
    private var csvPathValid: Bool { isValidCSVPath(csvPath) }

    private var rangeValid: Bool {
        guard let lower = lowerBound, let upper = upperBound else { return false }
        return lower <= upper
    }

    private var canStart: Bool {
        !model.isRunning && rangeValid && maxIterations != nil && csvPathValid
    }

    private var statusLabel: String {
        if model.isCancelling { return "Cancelling…" }
        if model.isRunning { return "Checking \(model.currentNumber)…" }
        if let summary = model.summary { return summary.wasCancelled ? "Cancelled" : "Done" }
        return "Ready"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Parameters").font(.headline)

                    Toggle("Use commas (1,000,000)", isOn: $useCommas)

                    HStack(spacing: 8) {
                        Text("Bounds").frame(width: rowLabelWidth, alignment: .leading)
                        GroupedNumberField(digits: lowerDigits, useCommas: useCommas)
                            .frame(width: 100)
                        Text("to").foregroundStyle(.secondary)
                        GroupedNumberField(digits: boundDigits, useCommas: useCommas)
                            .frame(width: 100)
                    }
                    if lowerBound == nil || upperBound == nil {
                        Text("Enter positive whole numbers").font(.caption).foregroundStyle(.red)
                            .padding(.leading, rowLabelWidth + 8)
                    } else if !rangeValid {
                        Text("Lower bound must not exceed upper bound").font(.caption).foregroundStyle(.red)
                            .padding(.leading, rowLabelWidth + 8)
                    }

                    HStack(spacing: 8) {
                        Text("Max iterations").frame(width: rowLabelWidth, alignment: .leading)
                        GroupedNumberField(digits: maxDigits, useCommas: useCommas)
                            .frame(width: 100)
                    }
                    if maxIterations == nil {
                        Text("Enter a positive whole number").font(.caption).foregroundStyle(.red)
                            .padding(.leading, rowLabelWidth + 8)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Algorithm").frame(width: rowLabelWidth, alignment: .leading)
                        Picker("Algorithm", selection: algorithm) {
                            ForEach(Algorithm.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        Text("CSV output").frame(width: rowLabelWidth, alignment: .leading)
                        TextField("Path", text: $csvPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseCSVPath() }
                    }
                    if !csvPathValid {
                        Text("Enter an absolute file path").font(.caption).foregroundStyle(.red)
                            .padding(.leading, rowLabelWidth + 8)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isRunning)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Progress").font(.headline)
                    ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                    HStack {
                        Text(statusLabel)
                        Spacer()
                        Text("\(model.completed) / \(model.total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    statRow("Lychrel numbers found", "\(model.exceeded)")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Start") { model.start(lowerBound: lowerBound!, upperBound: upperBound!, maxIterations: maxIterations!, algorithm: algorithm.wrappedValue, csvPath: csvPath) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)

                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.isRunning || model.isCancelling)
            }

            if let summary = model.summary {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Summary").font(.headline)
                        summaryView(summary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .frame(minWidth: 480)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func summaryView(_ summary: RunSummary) -> some View {
        if summary.wasCancelled {
            Text("Cancelled after \(summary.checked) of \(summary.total) — no CSV written.")
        } else {
            Text("Checked \(summary.total) numbers from \(summary.lowerBound) to \(summary.upperBound) (max \(summary.maxIterations) iterations each).")
            statRow("Algorithm", summary.algorithm.displayName)
            statRow("Palindromes found", "\(summary.palindromes)")
            statRow("Lychrel numbers found", "\(summary.exceeded)")
            statRow("Calc phase", formatDuration(summary.calc))
            if let sort = summary.sort {
                statRow("Sort phase", formatDuration(sort))
            }
            if let write = summary.write {
                statRow("Write phase", formatDuration(write))
            }
            if let error = summary.csvError {
                Text("Failed to write CSV: \(error)").foregroundStyle(.red)
            } else if let path = summary.csvPath {
                Text("Results written to \(path)")
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: statLabelWidth, alignment: .leading)
            Text(value).monospacedDigit()
        }
    }

    private func chooseCSVPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let current = URL(fileURLWithPath: (csvPath as NSString).expandingTildeInPath)
        panel.directoryURL = current.deletingLastPathComponent()
        panel.nameFieldStringValue = current.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            csvPath = url.path
        }
    }
}

#Preview {
    ContentView()
}
