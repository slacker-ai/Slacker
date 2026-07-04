import SwiftUI

/// Multi-step onboarding UI (§5.2). Drives `OnboardingModel`.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .intro: introStep
        case .manifestChoice: manifestStep
        case .createAndInstall: createStep
        case .pasteToken: tokenStep
        case .channels: channelsStep
        case .llm: llmStep
        }
    }

    // MARK: - Steps

    private var introStep: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogo(size: 76)
            VStack(spacing: 8) {
                Text("Slacker").font(Brand.display(34))
                Text(Brand.tagline)
                    .font(Brand.display(16, .medium))
                    .foregroundStyle(Brand.primary)
            }
            Text("Create your own read-only Slack app, choose channels, and connect your AI provider. About 3 minutes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 8) {
                trustLine("No Slacker server or shared OAuth app")
                trustLine("Slack messages stay in local SQLite")
                trustLine("Tokens and API keys stay in Keychain")
            }
            .padding(.top, 2)
            Button("Get started") { model.advance(to: .manifestChoice) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var manifestStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader("Choose Slack access",
                       "Pick the smallest read-only scope that still covers the channels you care about.")

            VStack(spacing: 12) {
                variantCard(
                    .publicAndPrivate,
                    title: "Public + private channels",
                    detail: "Recommended for most teams. Reads only channels you already belong to.",
                    scopes: "5 read-only scopes"
                )
                variantCard(
                    .publicOnly,
                    title: "Public channels only",
                    detail: "Strictest option. Slacker cannot read private channels at all.",
                    scopes: "3 read-only scopes"
                )
            }

            Label("Either way: never DMs, never write access, never channels you cannot already see.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Back") { model.advance(to: .intro) }
                Spacer()
                Button("Continue") { model.advance(to: .createAndInstall) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func variantCard(_ variant: ManifestVariant, title: String, detail: String, scopes: String) -> some View {
        let isSelected = model.selectedVariant == variant
        return Button {
            model.selectedVariant = variant
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if variant == .publicAndPrivate {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(scopes)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
    }

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Create your Slack app",
                       "Copy the manifest, open Slack's app page, then paste. Slack gives you the token after install.")

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    instruction(1, "Copy the app manifest.")
                    Button {
                        model.copyManifestToClipboard()
                    } label: {
                        Label("Copy manifest", systemImage: "doc.on.clipboard")
                    }
                    .padding(.leading, 30)
                }

                VStack(alignment: .leading, spacing: 8) {
                    instruction(2, "Open Slack.")
                    Button {
                        model.openSlackAppCreatePage()
                    } label: {
                        Label("Open Slack", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.leading, 30)
                }

                instruction(3, "Select 'From a manifest'.")
                instruction(4, "Choose your workspace (You can add more later), paste the manifest, and click Create.")
                instruction(5, "In the sidebar, click Install App, then click Install to Workspace and Allow.")
                instruction(6, "Copy the OAuth token from the Installed App Settings.")
            }

            Label("The token starts with xoxp-. Slacker stores it only in Keychain.",
                  systemImage: "key.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Back") { model.advance(to: .manifestChoice) }
                Spacer()
                Button("I installed it and copied the token") { model.advance(to: .pasteToken) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Connect Slack",
                       "Paste the User OAuth Token from your app's OAuth & Permissions page. Note, Token is stored LOCALLY on your computer.")

            SecureField("xoxp-...", text: $model.tokenInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back") { model.advance(to: .createAndInstall) }
                Spacer()
                if model.phase == .working {
                    ProgressView().controlSize(.small)
                }
                Button("Connect") {
                    Task { await model.validateTokenAndLoadChannels() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.phase == .working)
            }
        }
    }

    private var channelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let connection = model.connection {
                Label("Connected to \(connection.team) as \(connection.user)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
            stepHeader("Choose channels",
                       "Select the channels where missed follow-ups, stale items, and mentions matter.")

            if model.channels.isEmpty {
                Text("No channels found. Make sure the app is installed in the right workspace and that you belong to at least one readable channel.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.channels) { channel in
                    Toggle(isOn: Binding(
                        get: { channel.isWatched },
                        set: { _ in model.toggleWatched(channel) }
                    )) {
                        HStack(spacing: 6) {
                            Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(channel.name)
                        }
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                Text("\(model.watchedCount) selected").foregroundStyle(.secondary)
                Spacer()
                // First-run continues to the LLM step; adding a workspace finishes here
                // (the global LLM is already configured).
                Button(model.mode == .addWorkspace ? "Finish" : "Continue") {
                    if model.mode == .addWorkspace { model.finish() }
                    else { model.advance(to: .llm) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.watchedCount == 0)
            }
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Connect AI",
                       "Used for ambiguous messages, summaries, and learned guidance. Your key stays in Keychain.")

            Picker("Provider", selection: $model.llmProvider) {
                Text("Anthropic (Claude)").tag(LLMProvider.anthropic)
                Text("OpenAI").tag(LLMProvider.openAI)
                Text("Google Gemini").tag(LLMProvider.gemini)
                Text("Local LLM (Ollama)").tag(LLMProvider.ollama)
                Text("Custom API (OpenAI-compatible)").tag(LLMProvider.genericAPI)
                Text("Codex CLI").tag(LLMProvider.codexCLI)
                Text("Claude Code (subscription)").tag(LLMProvider.claudeCode)
            }
            .pickerStyle(.menu)

            Text(providerHint)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Model", text: $model.llmModel, prompt: Text(modelPlaceholder))
                .textFieldStyle(.roundedBorder)

            if model.llmNeedsAPIKey {
                SecureField("API key (stored in Keychain)", text: $model.llmAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
            if model.llmNeedsEndpoint {
                TextField("Endpoint URL", text: $model.llmBaseURL,
                          prompt: Text(model.llmProvider == .ollama ? "http://localhost:11434" : "https://…"))
                    .textFieldStyle(.roundedBorder)
            }
            if model.llmIsCLI {
                TextField("CLI path (optional — auto-detected)", text: $model.cliPath,
                          prompt: Text("/opt/homebrew/bin/…"))
                    .textFieldStyle(.roundedBorder)
            }

            if model.llmProvider == .ollama {
                Label("Runs fully on your machine — no API key, nothing leaves your laptop.",
                      systemImage: "desktopcomputer")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Text("You can change provider, model, and keys anytime in Settings.")
                .font(.footnote).foregroundStyle(.secondary)

            HStack {
                Button("Back") { model.advance(to: .channels) }
                Spacer()
                Button("Finish") { model.finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isLLMStepValid)
            }
        }
    }

    /// Minimal validation: a model is required (except CLI providers); key required for
    /// key-based providers.
    private var isLLMStepValid: Bool {
        if !model.llmIsCLI, model.llmModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if model.llmNeedsAPIKey, model.llmAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private var modelPlaceholder: String {
        model.llmIsCLI ? "(model handled by the CLI)" : LLMClientFactory.defaultModel(for: model.llmProvider)
    }

    private var providerHint: String {
        switch model.llmProvider {
        case .anthropic:
            return "Good default for high-precision classification."
        case .openAI:
            return "Use your OpenAI API key; Slacker sends only classification and summary prompts to OpenAI."
        case .gemini:
            return "Use your Google Gemini API key."
        case .ollama:
            return "Local option. Start Ollama first; the default endpoint is http://localhost:11434."
        case .genericAPI:
            return "For OpenAI-compatible services. Enter the model name and base URL."
        case .codexCLI:
            return "Uses your installed Codex CLI subscription through a local subprocess."
        case .claudeCode:
            return "Uses your installed Claude Code subscription through a local subprocess."
        }
    }

    // MARK: - Bits

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trustLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func hintLine(_ text: String) -> some View {
        Label(text, systemImage: "chevron.right")
            .labelStyle(.titleAndIcon)
    }
}
