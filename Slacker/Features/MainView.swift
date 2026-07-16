import SwiftUI

/// The main window once connected (§8): Needs attention, Review, and Overview.
struct MainView: View {
    @Bindable var model: MainViewModel
    let overviewModel: OverviewViewModel
    let settingsModel: SettingsModel

    @State private var activeSettingsSheet: SettingsSheet?

    private enum SettingsSheet: Identifiable {
        case general

        var id: String { "general" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !settingsModel.workspacesNeedingSocketModeSetup.isEmpty {
                socketModeSetupBanner
                Divider()
            }
            board
        }
        .frame(minWidth: 1180, minHeight: 620)
        .sheet(item: $activeSettingsSheet) { sheet in
            VStack(spacing: 0) {
                HStack {
                    Button {
                        activeSettingsSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close settings")

                    Spacer()
                }
                // Keep the header height unchanged while nudging the close control away
                // from the sheet's top-left edge.
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.top, 13)
                .padding(.bottom, 7)

                Divider()

                NavigationStack {
                    SettingsView(model: settingsModel, showsCloseButton: false)
                }
            }
            .frame(minWidth: 620, minHeight: 520)
        }
        .task {
            model.start()
            await settingsModel.load()
            await overviewModel.reload()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            BrandLogo(size: 28)
            Text("Slacker")
                .font(Brand.display(18))
            Text(Brand.tagline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                activeSettingsSheet = .general
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var socketModeSetupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Socket Mode setup required")
                    .font(.callout.weight(.semibold))
                Text("Real-time updates are off for \(settingsModel.workspacesNeedingSocketModeSetup.map(\.name).joined(separator: ", ")). Add an xapp- token with connections:write in Settings. Slacker will catch up automatically after setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { activeSettingsSheet = .general }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - Content

    private var board: some View {
        HStack(alignment: .top, spacing: 14) {
            BoardColumn(
                title: "Needs attention",
                helpText: "High-confidence follow-ups, stale threads, and mentions that likely need your response.",
                icon: "bell.badge",
                count: model.surfacedCount,
                tint: Brand.primary
            ) {
                AttentionListView(model: model, showsNavigationChrome: false)
            }

            BoardColumn(
                title: "Review",
                helpText: "Ambiguous messages Slacker is unsure about. Your triage teaches future detection.",
                icon: "tray",
                count: model.reviewItems.count,
                tint: Brand.mention
            ) {
                ReviewQueueView(model: model, showsNavigationChrome: false)
            }

            BoardColumn(
                title: "Overview",
                helpText: "Per-channel daily summaries and open-item counts for watched channels.",
                icon: "rectangle.3.group",
                count: overviewModel.activeChannels.count,
                tint: Brand.resolved
            ) {
                OverviewView(model: overviewModel, showsNavigationChrome: false)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BoardColumn<Content: View>: View {
    let title: String
    let helpText: String?
    let icon: String
    let count: Int
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(Brand.display(16))
                if let helpText {
                    HelpBadge(helpText)
                        .font(.caption)
                }
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
        )
    }
}
