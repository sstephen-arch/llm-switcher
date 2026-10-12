import AppKit
import SwiftUI

/// Settings → Review loop: a fast writer drafts, a different model reviews adversarially, the
/// writer fixes, optional tests decide, and the best version is kept.
struct ReviewLoopView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var loop: ReviewLoop
    @AppStorage("loop.writer") private var writer = ""
    @AppStorage("loop.reviewer") private var reviewer = ""
    @AppStorage("loop.rounds") private var rounds = 3
    @AppStorage("loop.reviewerEffort") private var reviewerEffort = "high"
    @AppStorage("loop.autoReview") private var autoReview = true
    @AppStorage("loop.folder") private var folder = ""
    @AppStorage("loop.file") private var fileName = "solution.py"
    @AppStorage("loop.command") private var command = ""
    @AppStorage("loop.task") private var task = ""

    var body: some View {
        Form {
            Section("Task") {
                TextEditor(text: $task)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if task.isEmpty {
                            Text("Describe what to build, as you would to a colleague.").foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            }
            Section("Models") {
                modelPicker("Writer (thinking off, fast)", $writer)
                modelPicker("Reviewer (adversarial)", $reviewer)
                Picker("Reviewer thinking", selection: $reviewerEffort) {
                    Text("Low").tag("low")
                    Text("Medium (fast, ~1 min per review)").tag("medium")
                    Text("High (most thorough, 4–9 min per review)").tag("high")
                }
                Stepper("Review rounds: \(rounds)", value: $rounds, in: 1...6)
                Text("A writer that thinks at length can't be the fast drafter: on hard tasks it never stops thinking. Use a different model as the reviewer; a model checking itself misses its own mistakes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                Toggle("Review Claude Code's local work automatically", isOn: $autoReview)
                Text("When a local Claude Code session (terminal, or Claude Desktop in local mode) finishes changing files in a git repo, the reviewer above checks the changes and the writer fixes what it finds, up to 3 rounds. Cloud sessions are never reviewed. Optional per-repo settings, including a test command, go in .llm-review.json at the repo root.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tests (optional, recommended)") {
                HStack {
                    Text(folder.isEmpty ? "No folder" : folder).lineLimit(1).truncationMode(.middle).foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose folder…", action: chooseFolder)
                    if !folder.isEmpty { Button("Clear") { folder = "" } }
                }
                TextField("Save the code as", text: $fileName)
                TextField("Test command, e.g. python3 -m pytest -q", text: $command)
                Text("Each version is saved to the file and the command runs in the folder. Exit code 0 means pass; pytest-style \"N passed, M failed\" scores partial passes, so a fix that makes things worse is thrown away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if loop.running {
                        ProgressView().controlSize(.small)
                        Button("Stop") { loop.cancel() }
                    } else {
                        Button("Run review loop") { start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || writer.isEmpty || reviewer.isEmpty)
                    }
                    Spacer()
                    if !loop.summary.isEmpty { Text(loop.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                }
                ForEach(loop.steps) { s in
                    HStack(alignment: .top) {
                        Image(systemName: s.ok == nil ? "circle.dotted" : (s.ok! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(s.ok == nil ? Color.secondary : (s.ok! ? Color.green : Color.red))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.callout.weight(.medium))
                            Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if s.seconds > 0 {
                            Text(String(format: "%.0fs%@", s.seconds, s.tokens > 0 ? " · \(s.tokens) tok" : ""))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !loop.finalCode.isEmpty {
                Section("Result") {
                    ScrollView {
                        Text(loop.finalCode).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(loop.finalCode, forType: .string)
                        }
                        Button("Save as…", action: save)
                        if !folder.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder).appendingPathComponent(fileName)]) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: defaults)
    }

    private func modelPicker(_ label: String, _ binding: Binding<String>) -> some View {
        Picker(label, selection: binding) {
            Text("Choose…").tag("")
            ForEach(state.models, id: \.self) { Text($0).tag($0) }
            if !binding.wrappedValue.isEmpty && !state.models.contains(binding.wrappedValue) {
                Text("\(binding.wrappedValue) (not loaded)").tag(binding.wrappedValue)
            }
        }
    }

    /// First run: the Sonnet 5 slot writes (the fast model), the Fable slot reviews.
    private func defaults() {
        if writer.isEmpty { writer = state.config.slots["claude-sonnet-5"] ?? state.models.first ?? "" }
        if reviewer.isEmpty { reviewer = state.config.slots["claude-fable-5"] ?? state.models.last ?? "" }
    }

    private func start() {
        loop.start(.init(task: task, writer: writer, reviewer: reviewer, rounds: rounds, reviewerEffort: reviewerEffort, folder: folder,
                         fileName: fileName.trimmingCharacters(in: .whitespaces), testCommand: command))
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Use folder"
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }

    private func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = fileName.isEmpty ? "solution.txt" : fileName
        if p.runModal() == .OK, let u = p.url { try? loop.finalCode.write(to: u, atomically: true, encoding: .utf8) }
    }
}
