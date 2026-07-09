import SwiftUI

/// Settings (§8.5). LLM key lives only in the Keychain; channels + thresholds in the DB.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    var showsCloseButton = true
    @Environment(\.dismiss) private var dismiss

    private let providerNames: [LLMProvider: String] = [
        .openAI: "OpenAI", .anthropic: "Anthropic Claude", .gemini: "Google Gemini",
        .genericAPI: "Custom API (OpenAI-compatible)", .ollama: "Local LLM (Ollama)",
        .codexCLI: "Codex CLI", .claudeCode: "Claude Code (subscription)",
    ]

    /// Curated model choices per provider for the Model dropdown. Providers with
    /// user-defined model names (Ollama, custom API) are absent → free-text field.
    private static let modelOptions: [LLMProvider: [String]] = [
        .anthropic: ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-fable-5"],
        .claudeCode: ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
        .openAI: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"],
        .codexCLI: ["gpt-4o", "gpt-4.1", "o4-mini"],
        .gemini: ["gemini-2.0-flash", "gemini-2.0-pro", "gemini-1.5-pro", "gemini-1.5-flash"],
    ]
    /// Sentinel tag for the "Custom…" dropdown entry.
    private static let customModelTag = "__custom__"

    /// True when the saved model isn't one of the curated options → show a text field.
    @State private var isCustomModel = false

    private var isCLIProvider: Bool {
        model.settings.llmProvider == .codexCLI || model.settings.llmProvider == .claudeCode
    }
    private var needsAPIKey: Bool {
        switch model.settings.llmProvider {
        case .ollama, .codexCLI, .claudeCode: return false
        default: return true
        }
    }

    var body: some View {
        Form {
            autosaveSection
            detectionSection
            learningSection
            llmSection
            workspacesSection
            channelsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Close settings")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Label(model.autosaveStatus, systemImage: autosaveStatusIcon)
                    .foregroundStyle(autosaveStatusColor)
            }
        }
        .task { await model.load() }
        .onChange(of: model.settings) { _, _ in model.scheduleAutosave() }
        .onChange(of: model.apiKey) { _, _ in model.scheduleAutosave() }
        .sheet(isPresented: Binding(
            get: { model.addWorkspaceModel != nil },
            set: { if !$0 { model.cancelAddWorkspace() } }
        )) {
            if let onboarding = model.addWorkspaceModel {
                VStack(spacing: 0) {
                    HStack {
                        Text("Add workspace").font(.headline)
                        Spacer()
                        Button("Cancel") { model.cancelAddWorkspace() }
                    }
                    .padding()
                    Divider()
                    OnboardingView(model: onboarding)
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .sheet(isPresented: $model.isShowingAddChannel) {
            AddChannelView(model: model)
        }
    }

    private var autosaveSection: some View {
        Section {
            Label("Changes save automatically.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var autosaveStatusIcon: String {
        switch model.autosaveStatus {
        case "Autosaved": "checkmark.circle.fill"
        case "Autosave failed": "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var autosaveStatusColor: Color {
        switch model.autosaveStatus {
        case "Autosaved": .green
        case "Autosave failed": .red
        default: .secondary
        }
    }

    private var workspacesSection: some View {
        Section {
            if model.workspaces.isEmpty {
                Text("No workspaces connected.").foregroundStyle(.secondary)
            } else {
                ForEach(model.workspaces) { workspace in
                    HStack {
                        Label(workspace.name, systemImage: "building.2")
                        Spacer()
                        Button(role: .destructive) {
                            model.removeWorkspace(workspace)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Disconnect this workspace and delete its local data (token, channels, items).")
                    }
                }
            }
        } header: {
            HStack {
                Text("Workspaces")
                HelpBadge("Each workspace has its own Slack token and channels. Add several to track them all in one place.")
                Spacer()
                Button {
                    model.startAddWorkspace()
                } label: {
                    Label("Add workspace", systemImage: "plus")
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Sections

    private var detectionSection: some View {
        Section("Detection") {
            LabeledRow("Staleness threshold",
                       help: "How long an item (decision, blocker, action) can sit untouched before it's flagged as stale. Measured from the message time, not when the app saw it.") {
                Stepper("\(model.settings.stalenessHours)h",
                        value: $model.settings.stalenessHours, in: 1...336, step: 1)
            }
            LabeledRow("Poll interval",
                       help: "How often Slacker checks your channels for new messages. Lower = fresher, but more Slack API calls.") {
                Stepper("\(model.settings.pollIntervalSeconds)s",
                        value: $model.settings.pollIntervalSeconds, in: 60...900, step: 30)
            }
            LabeledRow("Summary interval",
                       help: "How often daily channel summaries may regenerate when new activity arrives. Refresh still updates messages and detection immediately.") {
                Stepper(summaryIntervalLabel(model.settings.summaryRefreshIntervalMinutes),
                        value: $model.settings.summaryRefreshIntervalMinutes, in: 15...1440, step: 15)
            }
        }
    }

    private func summaryIntervalLabel(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var learningSection: some View {
        Section {
            LabeledRow("Enable self-evolution",
                       help: "When enabled, triage decisions can propose learned detection phrases and learned AI guidance. Proposals still require your approval before affecting detection.") {
                Toggle("", isOn: $model.settings.selfEvolutionEnabled)
                    .labelsHidden()
            }

            NavigationLink {
                LearnedPatternsView(model: model.learnedPatternsModel)
            } label: {
                LabeledContent {
                    EmptyView()
                } label: {
                    HStack {
                        Label("Approved phrases", systemImage: "wand.and.stars")
                        HelpBadge("Open Learned patterns to add, view, or retire approved phrases and active AI guidance.")
                    }
                }
            }
            .disabled(!model.settings.selfEvolutionEnabled)

            if !model.settings.selfEvolutionEnabled {
                Text("Self-evolution is off. Slacker will use only the built-in detection rules and base AI prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Self-evolution")
        }
    }

    private var llmSection: some View {
        Section("AI provider") {
            LabeledRow("Provider",
                       help: "Which AI model classifies ambiguous messages and writes summaries. Local LLM (Ollama) runs entirely on your machine; nothing leaves your laptop.") {
                Picker("", selection: $model.settings.llmProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(providerNames[provider] ?? provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
            }
            modelRow
            if needsAPIKey {
                LabeledRow("API key",
                           help: "Your provider API key. Stored only in the macOS Keychain — never written to disk or logs, never sent to us.") {
                    SecureField("", text: $model.apiKey).labelsHidden()
                }
            }
            if model.settings.llmProvider == .genericAPI || model.settings.llmProvider == .ollama {
                LabeledRow("Endpoint URL",
                           help: "Base URL of the API. Ollama defaults to http://localhost:11434. For a custom OpenAI-compatible service, enter its base URL.") {
                    TextField("", text: $model.settings.llmBaseURL, prompt: Text("https://…"))
                        .labelsHidden()
                }
            }
            if isCLIProvider {
                cliDetectionRow
            }
            Text("Provider/model changes take effect on next launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: model.settings.llmProvider) { _, _ in syncModelForProvider() }
        .onAppear {
            let options = curatedModelsForCurrentProvider()
            // Never leave the model blank for a curated provider — default to the first.
            if model.settings.llmModel.isEmpty, let first = options.first {
                model.settings.llmModel = first
            }
            isCustomModel = !options.isEmpty && !options.contains(model.settings.llmModel)
        }
    }

    // MARK: - Model dropdown

    private func curatedModelsForCurrentProvider() -> [String] {
        Self.modelOptions[model.settings.llmProvider] ?? []
    }

    /// On provider change, default to the new provider's first model unless the current
    /// one is already valid for it; reset the custom-field state.
    private func syncModelForProvider() {
        let options = curatedModelsForCurrentProvider()
        if options.isEmpty {                       // user-defined model names (Ollama / custom API)
            isCustomModel = false
        } else if !options.contains(model.settings.llmModel) {
            model.settings.llmModel = options[0]
            isCustomModel = false
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        let options = curatedModelsForCurrentProvider()
        if options.isEmpty {
            // Ollama / custom API: model names are user-defined.
            LabeledRow("Model",
                       help: "Model name for this provider, e.g. llama3 or qwen2.5 for Ollama.") {
                TextField("", text: $model.settings.llmModel, prompt: Text("model name"))
                    .labelsHidden()
            }
        } else {
            LabeledRow("Model",
                       help: "Pick a model for the selected provider, or choose Custom… to type one.") {
                Picker("", selection: modelPickerSelection(options)) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                    Text("Custom…").tag(Self.customModelTag)
                }
                .labelsHidden()
            }
            if isCustomModel {
                LabeledRow("Custom model",
                           help: "Exact model id to send to the provider.") {
                    TextField("", text: $model.settings.llmModel, prompt: Text("model id"))
                        .labelsHidden()
                }
            }
        }
    }

    private func modelPickerSelection(_ options: [String]) -> Binding<String> {
        Binding(
            get: {
                if isCustomModel || !options.contains(model.settings.llmModel) {
                    return Self.customModelTag
                }
                return model.settings.llmModel
            },
            set: { newValue in
                if newValue == Self.customModelTag {
                    isCustomModel = true
                } else {
                    isCustomModel = false
                    model.settings.llmModel = newValue
                }
            }
        )
    }

    // MARK: - CLI detection (auto + manual override)

    @ViewBuilder
    private var cliDetectionRow: some View {
        let binary = model.settings.llmProvider == .codexCLI ? "codex" : "claude"
        let override = model.settings.cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        // Effective resolution: the typed override wins (when valid), else auto-detect.
        let resolved = BinaryLocator.locate(binary, override: override.isEmpty ? nil : override)

        LabeledRow("CLI binary",
                   help: "Auto-detected on your PATH and common install locations (Homebrew, nvm, ~/.local/bin, …). If it isn't found, enter the path manually.") {
            if let resolved {
                Label(resolved, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Label("\(binary) not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
        }

        // Only ask for a manual path when auto-detection failed.
        if resolved == nil {
            LabeledRow("CLI path",
                       help: "Full path to the \(binary) binary, e.g. /opt/homebrew/bin/\(binary).") {
                TextField("", text: $model.settings.cliPathOverride, prompt: Text("/path/to/\(binary)"))
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var channelsSection: some View {
        Section {
            if model.channels.allSatisfy({ !$0.isWatched }) {
                Text("No channels watched yet. Use “Add channel” to start watching one.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Watched channels")
                HelpBadge("These are the channels Slacker is tracking. Sensitivity tunes how readily a channel surfaces items; the trash icon stops watching it. Use “Add channel” to watch more.")
                Spacer()
                Button { model.isShowingAddChannel = true } label: {
                    Label("Add channel", systemImage: "plus")
                }
                .textCase(nil)
            }
        }

        // Watched channels grouped under their workspace.
        ForEach(model.workspaces) { workspace in
            let watched = model.watchedChannels(for: workspace.id)
            if !watched.isEmpty {
                Section(workspace.name) {
                    columnHeaderRow
                    ForEach(watched) { channel in
                        channelRow(channel)
                    }
                }
            }
        }
    }

    /// Column labels so the sensitivity picker (Low / Normal / High) is self-explanatory.
    private var columnHeaderRow: some View {
        HStack {
            Text("Channel")
            Spacer()
            HStack(spacing: 4) {
                Text("Sensitivity")
                HelpBadge("How readily this channel surfaces items. High surfaces more (lower bar), Low surfaces less, Normal is the default.")
            }
            .frame(width: 124, alignment: .leading)
            Image(systemName: "trash").hidden()  // aligns with the per-row remove button
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { channel.isWatched },
                set: { _ in model.toggleWatched(channel) }
            )) {
                Label(channel.name, systemImage: channel.isPrivate ? "lock.fill" : "number")
            }
            Spacer()
            Picker("", selection: Binding(
                get: { channel.sensitivity },
                set: { model.setSensitivity($0, for: channel) }
            )) {
                ForEach(ChannelSensitivity.allCases, id: \.self) { s in
                    Text(s.rawValue.capitalized).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 124)
            .disabled(!channel.isWatched)

            Button(role: .destructive) {
                model.removeChannel(channel)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this channel. A Refresh re-adds it if you're still a member.")
        }
    }

}

/// A form row: label + a "?" help badge on the left, the control on the right.
private struct LabeledRow<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, help: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.help = help
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title)
            HelpBadge(help)
            Spacer()
            content()
        }
    }
}
