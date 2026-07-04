import SwiftUI

/// Review screen for the self-evolving loop (§7.5). Surfaces mined proposals — rule
/// phrases and LLM guidance — for human approval, with a precision delta so a regressing
/// phrase is flagged before it goes live. Reached via a link from Settings.
struct LearnedPatternsView: View {
    @Bindable var model: LearnedPatternsModel

    var body: some View {
        Form {
            introSection
            if !model.proposedPatterns.isEmpty { proposedPatternsSection }
            if !model.proposedGuidance.isEmpty { proposedGuidanceSection }
            if !model.approvedPatterns.isEmpty { approvedPatternsSection }
            activeGuidanceSection
            if model.hasAnything { revertSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Learned patterns")
        .task { await model.load() }
    }

    private var introSection: some View {
        Section {
            Text("As you triage items, Slacker learns your team's language and proposes new detection phrases and AI guidance. Nothing affects detection until you approve it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.hasAnything {
                Text("No proposals yet. Resolve, dismiss, or confirm a handful of items and check back after the next refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Proposed phrases

    private var proposedPatternsSection: some View {
        Section("Proposed phrases") {
            ForEach(model.proposedPatterns) { pattern in
                proposedPatternRow(pattern)
            }
        }
    }

    private func proposedPatternRow(_ pattern: LearnedPattern) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("“\(pattern.phrase)”").font(.body).bold()
                Spacer()
                Text(pattern.bucket.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.displayName(forChannelID: pattern.channelID))
                .font(.caption).foregroundStyle(.secondary)
            if let rationale = pattern.rationale, !rationale.isEmpty {
                Text(rationale).font(.caption).foregroundStyle(.secondary)
            }
            deltaView(for: pattern)
            HStack {
                Button("Approve") { Task { await model.approve(pattern) } }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { Task { await model.reject(pattern) } }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func deltaView(for pattern: LearnedPattern) -> some View {
        if let delta = model.deltas[pattern.id] {
            let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
            HStack(spacing: 6) {
                Image(systemName: delta.regresses ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .foregroundStyle(delta.regresses ? .orange : .green)
                Text("Precision \(pct(delta.beforePrecision)) → \(pct(delta.afterPrecision)), false positives \(pct(delta.beforeFalsePositiveRate)) → \(pct(delta.afterFalsePositiveRate)) over \(delta.sampleCount) labeled")
                    .font(.caption2)
                    .foregroundStyle(delta.regresses ? .orange : .secondary)
            }
        } else {
            Text("Not enough labeled examples to estimate precision impact.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Approved phrases

    private var approvedPatternsSection: some View {
        Section("Active phrases") {
            ForEach(model.approvedPatterns) { pattern in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(pattern.phrase)”")
                        Text("\(pattern.bucket.displayName) · \(model.displayName(forChannelID: pattern.channelID))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retire") { Task { await model.retire(pattern) } }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Guidance

    private var proposedGuidanceSection: some View {
        Section("Proposed AI guidance") {
            ForEach(model.proposedGuidance) { guidance in
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName(forChannelID: guidance.channelID))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(guidance.text).font(.callout)
                    HStack {
                        Button("Append to document") { Task { await model.approve(guidance) } }
                            .buttonStyle(.borderedProminent)
                        Button("Reject") { Task { await model.reject(guidance) } }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var activeGuidanceSection: some View {
        Section("Active AI guidance document") {
            VStack(alignment: .leading, spacing: 8) {
                Text("This is the single guidance document appended to AI classification and thread-resolution prompts. Edit it directly; proposed guidance can append new rules here. Changes save automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.activeGuidanceDraft)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    )
                    .onChange(of: model.activeGuidanceDraft) { _, _ in
                        model.activeGuidanceDidChange()
                    }
                HStack {
                    Label(model.activeGuidanceSaveStatus, systemImage: activeGuidanceStatusIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var activeGuidanceStatusIcon: String {
        switch model.activeGuidanceSaveStatus {
        case "Saved": "checkmark.circle"
        case "Save failed": "exclamationmark.triangle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var revertSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await model.retireAll() }
            } label: {
                Label("Revert all learned patterns", systemImage: "arrow.uturn.backward")
            }
            .help("Retire every approved phrase and guidance block, restoring the built-in defaults.")
        }
    }
}
