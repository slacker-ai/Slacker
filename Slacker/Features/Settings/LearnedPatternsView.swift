import SwiftUI

/// Settings editor for automatically learned phrases and global/channel prompt overlays.
struct LearnedPatternsView: View {
    @Bindable var model: LearnedPatternsModel
    @State private var isAddingPhrase = false
    @State private var areApprovedPhrasesExpanded = false
    @State private var channelSearchText = ""
    @State private var expandedGuidanceChannelID: String?

    var body: some View {
        Form {
            introSection
            approvedPhrasesSection
            activeGuidanceSection
            if !model.channels.isEmpty { channelGuidanceSection }
            if model.hasAnything { revertSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Learned patterns")
        .task { await model.load() }
    }

    private var introSection: some View {
        Section {
            Text("User actions can update these prompts when they teach a new reusable rule. Most automatic changes are saved under the source channel below; the global document changes only for rules that apply everywhere.")
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
            DisclosureGroup(isExpanded: $areApprovedPhrasesExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { isAddingPhrase.toggle() }
                        } label: {
                            Label(
                                isAddingPhrase ? "Cancel" : "Add phrase",
                                systemImage: isAddingPhrase ? "xmark" : "plus"
                            )
                        }
                        .buttonStyle(.borderless)
                    }

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

                    Text("Phrases go live immediately after saving. Raw regex is intentionally not supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Approved phrases")
                    Spacer()
                    Text("\(model.approvedPatterns.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
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
                if model.manualPhraseBucket == .dismiss {
                    Text("Messages containing this phrase will be dismissed instead of surfaced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        Section("Global AI guidance document") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Starts with a generic attention policy and applies to every Slack channel before its channel-specific guidance. Fully editable.")
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
                    Text("\(model.activeGuidanceDraft.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var channelGuidanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ChannelSearchField(text: $channelSearchText)
                    .frame(height: 24)

                if filteredGuidanceChannels.isEmpty {
                    Text("No channels match “\(channelSearchText)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(filteredGuidanceChannels) { channel in
                        DisclosureGroup(isExpanded: guidanceExpansionBinding(for: channel.id)) {
                            channelGuidanceEditor
                                .padding(.top, 8)
                        } label: {
                            HStack {
                                Label(channel.name, systemImage: channel.isPrivate ? "lock.fill" : "number")
                                    .font(.body.weight(.medium))
                                if model.activeChannelGuidance.contains(where: { $0.channelID == channel.id }) {
                                    Text("Learned")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Brand.primary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Brand.primary.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Channel AI guidance documents")
        } footer: {
            Text("Channels marked Learned contain automatic or manual guidance. A triage action may make no change when the current prompts already cover it.")
        }
    }

    private var filteredGuidanceChannels: [Channel] {
        let query = channelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.channels
            .filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || "#\($0.name)".localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func guidanceExpansionBinding(for channelID: String) -> Binding<Bool> {
        Binding(
            get: { expandedGuidanceChannelID == channelID },
            set: { isExpanded in
                if isExpanded {
                    expandedGuidanceChannelID = channelID
                    Task { await model.selectGuidanceChannel(channelID) }
                } else if expandedGuidanceChannelID == channelID {
                    expandedGuidanceChannelID = nil
                }
            }
        )
    }

    private var channelGuidanceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.channelGuidanceDraft)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: model.channelGuidanceDraft) { _, _ in
                    model.channelGuidanceDidChange()
                }

            HStack {
                Label(model.channelGuidanceSaveStatus, systemImage: channelGuidanceStatusIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.effectiveLearnedCharacterCount) effective learned characters")
                    .font(.caption)
                    .foregroundStyle(
                        model.effectiveLearnedCharacterCount >= PatternEvolutionService.condensationThreshold
                            ? .orange : .secondary
                    )
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

    private var channelGuidanceStatusIcon: String {
        switch model.channelGuidanceSaveStatus {
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

/// `NSSearchField` behaves reliably inside a grouped macOS `Form` and sends an update
/// for every keystroke, including changes made with its built-in clear button.
private struct ChannelSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Filter channels"
        field.stringValue = text
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }

        @objc func searchFieldChanged(_ field: NSSearchField) {
            text = field.stringValue
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
