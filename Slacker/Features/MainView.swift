import SwiftUI

/// The main window once connected (§8): a board with Needs attention, Review, Overview,
/// and Evolution visible together so the user does not have to bounce between tabs.
struct MainView: View {
    @Bindable var model: MainViewModel
    let overviewModel: OverviewViewModel
    let settingsModel: SettingsModel

    @State private var activeSettingsSheet: SettingsSheet?

    private enum SettingsSheet: Identifiable {
        case general
        case evolution

        var id: String {
            switch self {
            case .general: return "general"
            case .evolution: return "evolution"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                NavigationStack {
                    switch sheet {
                    case .general:
                        SettingsView(model: settingsModel, showsCloseButton: false)
                    case .evolution:
                        LearnedPatternsView(model: settingsModel.learnedPatternsModel)
                    }
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
                Task {
                    await model.refreshNow()
                    await overviewModel.refreshNow()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || overviewModel.isRefreshing)

            Button {
                activeSettingsSheet = .general
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Content

    private var board: some View {
        HStack(alignment: .top, spacing: 14) {
            BoardColumn(title: "Needs attention", icon: "bell.badge", count: model.surfacedCount, tint: Brand.primary) {
                AttentionListView(model: model, showsNavigationChrome: false)
            }

            BoardColumn(title: "Review", icon: "tray", count: model.reviewItems.count, tint: Brand.mention) {
                ReviewQueueView(model: model, showsNavigationChrome: false)
            }

            BoardColumn(title: "Overview", icon: "rectangle.3.group", count: overviewModel.activeChannels.count, tint: Brand.resolved) {
                OverviewView(model: overviewModel, showsNavigationChrome: false)
            }

            BoardColumn(title: "Evolution", icon: "wand.and.stars", count: settingsModel.pendingEvolutionUpdateCount, tint: Brand.primaryDeep) {
                EvolutionApprovalView(
                    model: settingsModel.learnedPatternsModel,
                    showsNavigationChrome: false,
                    onOpenSettings: { activeSettingsSheet = .evolution }
                )
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BoardColumn<Content: View>: View {
    let title: String
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
