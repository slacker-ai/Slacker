import SwiftUI

/// Settings screen for the self-evolving loop (§7.5). Approvals live primarily on the
/// main board's Evolution column; Settings keeps the manual editor, active phrases,
/// guidance document, and revert controls.
struct LearnedPatternsView: View {
    @Bindable var model: LearnedPatternsModel
    @State private var isAddingPhrase = false

    var body: some View {
        Form {
            introSection
            approvedPhrasesSection
            activeGuidanceSection
            if model.hasAnything { revertSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Learned patterns")
        .task { await model.load() }
    }

    private var introSection: some View {
        Section {
            Text("Manage the approved phrases and AI guidance that affect detection.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.hasAnything {
                Text("No learned phrases or guidance yet. Add a phrase manually to teach Slacker team-specific language.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Approved phrases

    private var approvedPhrasesSection: some View {
        Section {
            if isAddingPhrase {
                addPhraseForm
                if !model.approvedPatterns.isEmpty { Divider() }
            }

            if model.approvedPatterns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No approved phrases yet.")
                        .foregroundStyle(.secondary)
                    Text("Add a specific multi-word phrase to extend a detection type immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.approvedPatterns) { pattern in
                    approvedPhraseRow(pattern)
                }
            }
        } header: {
            HStack {
                Text("Approved phrases")
                Spacer()
                Button {
                    withAnimation { isAddingPhrase.toggle() }
                } label: {
                    Label(isAddingPhrase ? "Cancel" : "Add phrase", systemImage: isAddingPhrase ? "xmark" : "plus")
                }
                .textCase(nil)
            }
        } footer: {
            Text("Phrases go live immediately after saving. Raw regex is intentionally not supported.")
        }
    }

    private var addPhraseForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter phrase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LeftAlignedPhraseField(
                    placeholder: "red alert on",
                    text: $model.manualPhraseDraft
                ) {
                    model.manualPhraseSaveStatus = ""
                }
                .frame(height: 24)
                if let message = model.manualPhraseValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Channel")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Channel", selection: $model.manualPhraseChannelSelection) {
                    Text("All channels (default)").tag(LearnedPatternsModel.globalChannelSelection)
                    ForEach(model.channels) { channel in
                        Text("#\(channel.name)").tag(channel.id)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Type")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Type", selection: $model.manualPhraseBucket) {
                    ForEach(RuleBucket.allCases, id: \.self) { bucket in
                        Text(bucket.displayName).tag(bucket)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.saveManualPhrase()
                        if model.manualPhraseSaveStatus == "Saved" {
                            isAddingPhrase = false
                        }
                    }
                } label: {
                    Label("Save phrase", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    isAddingPhrase = false
                    model.manualPhraseDraft = ""
                    model.manualPhraseSaveStatus = ""
                }
                .buttonStyle(.borderless)

                if !model.manualPhraseSaveStatus.isEmpty {
                    Text(model.manualPhraseSaveStatus)
                        .font(.caption)
                        .foregroundStyle(model.manualPhraseSaveStatus == "Saved" ? Color.secondary : Color.orange)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func approvedPhraseRow(_ pattern: LearnedPattern) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pattern.source == .manual ? "person.crop.circle.badge.checkmark" : "wand.and.stars")
                .foregroundStyle(Brand.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(pattern.phrase)\"")
                    .font(.body.weight(.semibold))
                Text("\(pattern.bucket.displayName) · \(model.displayName(forChannelID: pattern.channelID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await model.retire(pattern) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Retire this phrase")
        }
        .padding(.vertical, 3)
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

private struct LeftAlignedPhraseField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onEdit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.alignment = .left
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.alignment = .left
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEdit: onEdit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        private let onEdit: () -> Void

        init(text: Binding<String>, onEdit: @escaping () -> Void) {
            _text = text
            self.onEdit = onEdit
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard
                let field = notification.object as? NSTextField,
                field.stringValue.isEmpty,
                let editor = field.currentEditor()
            else { return }
            editor.selectedRange = NSRange(location: 0, length: 0)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            onEdit()
        }
    }
}

/// Main-board review surface for pending self-evolution proposals. Each proposed phrase
/// or guidance block stays independent so approval remains a deliberate triage action.
struct EvolutionApprovalView: View {
    @Bindable var model: LearnedPatternsModel
    var showsNavigationChrome = true
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if model.pendingProposalCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 42))
                        .foregroundStyle(Brand.primary)
                    Text("No evolution pending")
                        .font(Brand.display(20))
                    Text("New learned phrases and AI guidance will appear here for approval.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    managePhrasesButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        managementControls
                        bulkControls
                        ForEach(model.proposedPatterns) { pattern in
                            phraseCard(pattern)
                        }
                        ForEach(model.proposedGuidance) { guidance in
                            guidanceCard(guidance)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(showsNavigationChrome ? "Evolution" : "")
        .task { await model.load() }
    }

    @ViewBuilder
    private var managePhrasesButton: some View {
        if let onOpenSettings {
            Button {
                onOpenSettings()
            } label: {
                Label("Manage phrases", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var managementControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Approvals")
                    .font(.caption.weight(.semibold))
                Text("Detection changes stay inert until approved here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            managePhrasesButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var bulkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.approveSafePhrases() }
                } label: {
                    Label("Approve safe phrases", systemImage: "checkmark.seal")
                }
                .disabled(model.safeProposedPhraseCount == 0)
                .help("Approves only phrase proposals whose offline precision estimate does not regress.")

                Button(role: .destructive) {
                    Task { await model.rejectAllProposals() }
                } label: {
                    Label("Reject all", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(model.safePhraseBulkStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func phraseCard(_ pattern: LearnedPattern) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\"\(pattern.phrase)\"")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(pattern.bucket.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.primary)
                    .lineLimit(1)
            }

            Label(model.displayName(forChannelID: pattern.channelID), systemImage: "number")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let rationale = pattern.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            deltaView(for: pattern)

            HStack(spacing: 8) {
                Button("Approve") { Task { await model.approve(pattern) } }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { Task { await model.reject(pattern) } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .brandCard(tint: Brand.primary)
    }

    private func guidanceCard(_ guidance: LearnedGuidance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(model.displayName(forChannelID: guidance.channelID), systemImage: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("AI guidance")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.mention)
            }

            Text(guidance.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Append") { Task { await model.approve(guidance) } }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { Task { await model.reject(guidance) } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .brandCard(tint: Brand.mention)
    }

    @ViewBuilder
    private func deltaView(for pattern: LearnedPattern) -> some View {
        if let delta = model.deltas[pattern.id] {
            let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: delta.regresses ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .foregroundStyle(delta.regresses ? .orange : .green)
                Text("Precision \(pct(delta.beforePrecision)) -> \(pct(delta.afterPrecision)), false positives \(pct(delta.beforeFalsePositiveRate)) -> \(pct(delta.afterFalsePositiveRate)) over \(delta.sampleCount) labeled")
                    .font(.caption2)
                    .foregroundStyle(delta.regresses ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Not enough labeled examples to estimate precision impact.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
