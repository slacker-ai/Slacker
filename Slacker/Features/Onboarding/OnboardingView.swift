import SwiftUI

/// Multi-step onboarding UI (§5.2). Drives `OnboardingModel` while keeping navigation,
/// progress, validation, and privacy cues consistent across every step.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @State private var channelQuery = ""
    @State private var didCopyManifest = false

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()

            ScrollView {
                content
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 36)
                    .padding(.vertical, model.step == .intro ? 42 : 30)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(model.step)
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            wizardFooter
        }
        .frame(width: 760, height: 620)
        .background(
            LinearGradient(
                colors: [Brand.primary.opacity(0.045), Color(nsColor: .windowBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .center
            )
        )
    }

    // MARK: - Wizard chrome

    private var wizardHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                BrandWordmark(logoSize: 30)
                Spacer()
                if model.step == .intro {
                    Label("Private by default", systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(stepLabel.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.primary)
                        Text("Step \(currentStepIndex + 1) of \(setupSteps.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.step != .intro {
                HStack(spacing: 7) {
                    ForEach(Array(setupSteps.enumerated()), id: \.offset) { index, _ in
                        Capsule()
                            .fill(progressColor(for: index))
                            .frame(height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(currentStepIndex + 1) of \(setupSteps.count): \(stepLabel)")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private var wizardFooter: some View {
        HStack(spacing: 12) {
            footerContent
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
    }

    @ViewBuilder
    private var footerContent: some View {
        switch model.step {
        case .intro:
            Label("About 5 minutes", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get started") { model.advance(to: .manifestChoice) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

        case .manifestChoice:
            Button("Back") { model.advance(to: .intro) }
            Spacer()
            Button("Continue") { model.advance(to: .createAndInstall) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

        case .createAndInstall:
            Button("Back") { model.advance(to: .manifestChoice) }
            Spacer()
            Button("I have both tokens") { model.advance(to: .pasteToken) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

        case .pasteToken:
            Button("Back") { model.advance(to: .createAndInstall) }
            Spacer()
            if model.phase == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Connect workspace") {
                Task { await model.validateTokenAndLoadChannels() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!tokensAreValid || model.phase == .working)

        case .channels:
            Button("Back") { model.advance(to: .pasteToken) }
            Spacer()
            Text("\(model.watchedCount) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(model.mode == .addWorkspace ? "Finish" : "Continue") {
                if model.mode == .addWorkspace { model.finish() }
                else { model.advance(to: .llm) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.watchedCount == 0)

        case .llm:
            Button("Back") { model.advance(to: .channels) }
            Spacer()
            Button("Finish setup") { model.finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isLLMStepValid)
        }
    }

    private var setupSteps: [OnboardingModel.Step] {
        switch model.mode {
        case .firstRun:
            return [.manifestChoice, .createAndInstall, .pasteToken, .channels, .llm]
        case .addWorkspace:
            return [.manifestChoice, .createAndInstall, .pasteToken, .channels]
        }
    }

    private var currentStepIndex: Int {
        setupSteps.firstIndex(of: model.step) ?? 0
    }

    private var stepLabel: String {
        switch model.step {
        case .intro: return "Welcome"
        case .manifestChoice: return "Slack access"
        case .createAndInstall: return "Create app"
        case .pasteToken: return "Credentials"
        case .channels: return "Channels"
        case .llm: return "AI provider"
        }
    }

    private func progressColor(for index: Int) -> Color {
        if index < currentStepIndex { return Brand.resolved }
        if index == currentStepIndex { return Brand.primary }
        return Color.secondary.opacity(0.16)
    }

    // MARK: - Step routing

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
        VStack(spacing: 24) {
            BrandLogo(size: 88)

            VStack(spacing: 9) {
                Text(model.mode == .addWorkspace ? "Add another workspace" : "Slack minus the noise")
                    .font(Brand.display(32))
                    .multilineTextAlignment(.center)
                Text(model.mode == .addWorkspace
                     ? "Connect another read-only Slack app without changing your existing workspace."
                     : "Slacker watches the channels you choose, only surfaces the important thread, and keeps EVERYTHING on your mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 580)
            }

            HStack(alignment: .top, spacing: 12) {
                trustCard(
                    icon: "eye.slash.fill",
                    title: "Read-only",
                    detail: "No DMs, posting, or shared OAuth app."
                )
                trustCard(
                    icon: "internaldrive.fill",
                    title: "Local-first",
                    detail: "Messages and analysis live in local SQLite."
                )
                trustCard(
                    icon: "key.fill",
                    title: "Keychain-secured",
                    detail: "Slack tokens and AI keys never enter the database."
                )
            }

            Label("You’ll create a private Slack app, connect two tokens, choose channels, and select an AI provider.",
                  systemImage: "checklist")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var manifestStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(
                "Choose the Slack access you need",
                "Both options are read-only. Pick the narrowest scope that covers the conversations you want Slacker to watch."
            )

            VStack(spacing: 12) {
                variantCard(
                    .publicAndPrivate,
                    icon: "building.2.fill",
                    title: "Public + private channels",
                    detail: "Reads public channels and private channels you already belong to.",
                    coverage: ["Public channels", "Your private channels", "Messages and reactions"],
                    scopes: "6 read-only scopes"
                )
                variantCard(
                    .publicOnly,
                    icon: "number.circle.fill",
                    title: "Public channels only",
                    detail: "Strictest option. Private channels remain completely unavailable.",
                    coverage: ["Public channels", "Messages and reactions"],
                    scopes: "4 read-only scopes"
                )
            }

            infoBanner(
                icon: "lock.shield.fill",
                title: "What Slacker can never access",
                detail: "Direct messages, posting permissions, and channels your Slack account cannot already see.",
                tint: Brand.mention
            )
        }
    }

    private func variantCard(
        _ variant: ManifestVariant,
        icon: String,
        title: String,
        detail: String,
        coverage: [String],
        scopes: String
    ) -> some View {
        let isSelected = model.selectedVariant == variant
        return Button {
            if model.selectedVariant != variant { didCopyManifest = false }
            model.selectedVariant = variant
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Brand.primary : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if variant == .publicAndPrivate {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Brand.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Brand.primary.opacity(0.12)))
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        ForEach(coverage, id: \.self) { item in
                            Label(item, systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(scopes)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.primary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Brand.primary : Color.secondary.opacity(0.45))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                    .fill(isSelected ? Brand.primary.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                    .strokeBorder(isSelected ? Brand.primary.opacity(0.8) : Color.secondary.opacity(0.16), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                "Create your private Slack app",
                "Slack owns this setup screen. Slacker provides the manifest and stores the resulting credentials locally."
            )

            setupCard(
                number: 1,
                title: "Copy the manifest",
                detail: "It contains the read-only scopes and Socket Mode event subscriptions for your selection."
            ) {
                Button {
                    model.copyManifestToClipboard()
                    withAnimation { didCopyManifest = true }
                } label: {
                    Label(didCopyManifest ? "Manifest copied" : "Copy manifest",
                          systemImage: didCopyManifest ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
            }

            setupCard(
                number: 2,
                title: "Create and install the app",
                detail: "Open Slack, choose From a manifest, select your workspace, paste, and create the app. Then open Install App and allow it."
            ) {
                Button {
                    model.openSlackAppCreatePage()
                } label: {
                    Label("Open Slack app setup", systemImage: "arrow.up.right.square")
                }
            }

            setupCard(
                number: 3,
                title: "Collect both credentials",
                detail: "You’ll paste these on the next screen. Do not use a bot token."
            ) {
                VStack(spacing: 8) {
                    credentialLocation(
                        prefix: "xoxp-",
                        title: "User OAuth token",
                        location: "Install App -> Install to Slack Workspace -> User OAuth Token"
                    )
                    credentialLocation(
                        prefix: "xapp-",
                        title: "Socket Mode token",
                        location: "Basic Information → App-Level Tokens → Generate an app-level token -> add scope 'connections:write' -> Generate"
                    )
                }
            }

            infoBanner(
                icon: "key.fill",
                title: "Why two tokens?",
                detail: "The user token controls what messages can be read. The app token only opens the real-time Socket Mode connection.",
                tint: Brand.primary
            )
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                "Connect Slack securely",
                "Both credentials are validated with Slack before anything is stored in macOS Keychain."
            )

            credentialCard(
                title: "User OAuth token",
                prefix: "xoxp-",
                icon: "person.crop.circle.badge.checkmark",
                detail: "Found under OAuth & Permissions after installing the app.",
                text: $model.tokenInput,
                isValid: userTokenIsValid
            )

            credentialCard(
                title: "Socket Mode app token",
                prefix: "xapp-",
                icon: "bolt.horizontal.circle.fill",
                detail: "Found under Basic Information → App-Level Tokens. It needs connections:write.",
                text: $model.appTokenInput,
                isValid: appTokenIsValid
            )

            if case .failed(let message) = model.phase {
                infoBanner(
                    icon: "exclamationmark.triangle.fill",
                    title: "Couldn’t connect",
                    detail: message,
                    tint: Brand.stale
                )
            } else {
                infoBanner(
                    icon: "lock.fill",
                    title: "Credentials stay on this Mac",
                    detail: "Slacker never writes token values to SQLite, logs, analytics, or crash reports.",
                    tint: Brand.mention
                )
            }
        }
    }

    private var channelsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let connection = model.connection {
                infoBanner(
                    icon: "checkmark.circle.fill",
                    title: "Connected to \(connection.team)",
                    detail: "Authenticated as \(connection.user). Now choose what Slacker should watch.",
                    tint: Brand.resolved
                )
            }

            stepHeader(
                "Choose channels to watch",
                "Start narrow. You can add or remove channels later without reinstalling the Slack app."
            )

            if model.channels.isEmpty {
                infoBanner(
                    icon: "tray",
                    title: "No readable channels found",
                    detail: "Confirm the app is installed in the correct workspace and that your Slack account belongs to at least one channel.",
                    tint: Brand.missed
                )
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter \(model.channels.count) channels", text: $channelQuery)
                            .textFieldStyle(.plain)
                        if !channelQuery.isEmpty {
                            Button {
                                channelQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear filter")
                        }
                        Divider().frame(height: 18)
                        Button("Select visible") { setVisibleChannels(watched: true) }
                            .buttonStyle(.borderless)
                        Button(channelQuery.isEmpty ? "Clear" : "Clear visible") {
                            setVisibleChannels(watched: false)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider()

                    if visibleChannels.isEmpty {
                        ContentUnavailableView(
                            "No matching channels",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different channel name.")
                        )
                        .frame(height: 230)
                    } else {
                        List(visibleChannels) { channel in
                            Toggle(isOn: Binding(
                                get: { model.channels.first(where: { $0.id == channel.id })?.isWatched ?? false },
                                set: { _ in model.toggleWatched(channel) }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                                        .foregroundStyle(channel.isPrivate ? Brand.missed : .secondary)
                                        .font(.caption)
                                        .frame(width: 14)
                                    Text(channel.name)
                                    if channel.isPrivate {
                                        Text("Private")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 250, maxHeight: 320)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.16))
                )
            }
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                "Choose your AI provider",
                "AI resolves ambiguous messages, applies your learned guidance, and writes concise summaries."
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Label("Provider", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Picker("Provider", selection: $model.llmProvider) {
                        Text("Anthropic (Claude)").tag(LLMProvider.anthropic)
                        Text("OpenAI").tag(LLMProvider.openAI)
                        Text("Google Gemini").tag(LLMProvider.gemini)
                        Text("Local LLM (Ollama)").tag(LLMProvider.ollama)
                        Text("Custom API").tag(LLMProvider.genericAPI)
                        Text("Codex CLI").tag(LLMProvider.codexCLI)
                        Text("Claude Code").tag(LLMProvider.claudeCode)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                Text(providerHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                if !model.llmIsCLI {
                    formField("Model", help: "Use the provider’s exact model identifier.") {
                        TextField("Model", text: $model.llmModel, prompt: Text(modelPlaceholder))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if model.llmNeedsAPIKey {
                    formField("API key", help: "Required and stored only in Keychain.") {
                        SecureField("Paste API key", text: $model.llmAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if model.llmNeedsEndpoint {
                    formField(
                        "Endpoint URL",
                        help: model.llmProvider == .ollama
                            ? "Optional. Leave blank for http://localhost:11434."
                            : "Required for a custom OpenAI-compatible service."
                    ) {
                        TextField(
                            "Endpoint URL",
                            text: $model.llmBaseURL,
                            prompt: Text(model.llmProvider == .ollama ? "http://localhost:11434" : "https://api.example.com/v1")
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                if model.llmIsCLI {
                    formField("CLI path", help: "Auto-detected when you select a CLI provider. Edit it if needed.") {
                        TextField("CLI path", text: $model.cliPath, prompt: Text("/opt/homebrew/bin/…"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .brandCard(tint: Brand.primary)

            if model.llmProvider == .ollama {
                infoBanner(
                    icon: "desktopcomputer",
                    title: "Fully local inference",
                    detail: "No API key is needed and Slack content stays on your machine. Start Ollama before using Slacker.",
                    tint: Brand.resolved
                )
            } else if model.llmIsCLI {
                infoBanner(
                    icon: "terminal.fill",
                    title: "Uses your local CLI session",
                    detail: "Slacker invokes the installed command locally and does not store another provider API key.",
                    tint: Brand.mention
                )
            } else {
                infoBanner(
                    icon: "key.fill",
                    title: "Your key remains in Keychain",
                    detail: "Only classification and summary prompts are sent to the provider you select. You can change this anytime in Settings.",
                    tint: Brand.mention
                )
            }

            if let validationMessage = llmValidationMessage {
                Label(validationMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Validation and channel actions

    private var trimmedUserToken: String {
        model.tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAppToken: String {
        model.appTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var userTokenIsValid: Bool { trimmedUserToken.hasPrefix("xoxp-") }
    private var appTokenIsValid: Bool { trimmedAppToken.hasPrefix("xapp-") }
    private var tokensAreValid: Bool { userTokenIsValid && appTokenIsValid }

    private var visibleChannels: [Channel] {
        let query = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.channels }
        return model.channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func setVisibleChannels(watched: Bool) {
        let candidates = visibleChannels.filter { $0.isWatched != watched }
        for channel in candidates {
            model.toggleWatched(channel)
        }
    }

    private var isLLMStepValid: Bool {
        if !model.llmIsCLI,
           model.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if model.llmNeedsAPIKey,
           model.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if model.llmProvider == .genericAPI {
            return validHTTPURL(model.llmBaseURL)
        }
        if model.llmProvider == .ollama,
           !model.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return validHTTPURL(model.llmBaseURL)
        }
        return true
    }

    private var llmValidationMessage: String? {
        if !model.llmIsCLI,
           model.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a model identifier to finish setup."
        }
        if model.llmNeedsAPIKey,
           model.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Paste the provider API key to finish setup."
        }
        if model.llmProvider == .genericAPI, !validHTTPURL(model.llmBaseURL) {
            return "Enter a valid http:// or https:// endpoint URL."
        }
        if model.llmProvider == .ollama,
           !model.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !validHTTPURL(model.llmBaseURL) {
            return "The custom Ollama endpoint must be a valid http:// or https:// URL."
        }
        return nil
    }

    private func validHTTPURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host != nil
    }

    private var modelPlaceholder: String {
        LLMClientFactory.defaultModel(for: model.llmProvider)
    }

    private var providerHint: String {
        switch model.llmProvider {
        case .anthropic:
            return "Recommended default for high-precision classification and thread summaries."
        case .openAI:
            return "Uses the OpenAI API for classification, summaries, and learned-guidance checks."
        case .gemini:
            return "Uses the Google Gemini API with your own key."
        case .ollama:
            return "Runs a model through Ollama on this Mac. No cloud API key required."
        case .genericAPI:
            return "Connect any OpenAI-compatible service with its model, endpoint, and API key."
        case .codexCLI:
            return "Uses your installed Codex CLI subscription through a local subprocess."
        case .claudeCode:
            return "Uses your installed Claude Code subscription through a local subprocess."
        }
    }

    // MARK: - Reusable pieces

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Brand.display(27))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trustCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Brand.primary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .brandCard(tint: Brand.primary)
    }

    private func setupCard<Actions: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Brand.gradient))

            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .brandCard(tint: Brand.primary)
    }

    private func credentialLocation(prefix: String, title: String, location: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(prefix)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(Brand.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Brand.primary.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(location).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func credentialCard(
        title: String,
        prefix: String,
        icon: String,
        detail: String,
        text: Binding<String>,
        isValid: Bool
    ) -> some View {
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasInput = !trimmed.isEmpty
        let tint = !hasInput ? Brand.primary : (isValid ? Brand.resolved : Brand.stale)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title).font(.headline)
                Spacer()
                if hasInput {
                    Label(isValid ? "Format looks right" : "Wrong token type",
                          systemImage: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("\(prefix)…", text: text)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            if hasInput && !isValid {
                Text("Expected a token beginning with \(prefix)")
                    .font(.caption)
                    .foregroundStyle(Brand.stale)
            }
        }
        .brandCard(tint: tint)
    }

    private func infoBanner(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.16))
        )
    }

    private func formField<Field: View>(
        _ title: String,
        help: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            field()
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
