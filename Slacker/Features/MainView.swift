import SwiftUI

/// The main window once connected (§8): Needs attention (default), Overview, Review queue,
/// Settings. Uses a custom tab bar so each tab can show a notification count pill — macOS's
/// native `TabView` ignores `.badge()` on tab items.
struct MainView: View {
    @Bindable var model: MainViewModel
    let overviewModel: OverviewViewModel
    let settingsModel: SettingsModel

    @State private var selection: MainTab = .attention

    enum MainTab: Hashable { case attention, overview, review, settings }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .frame(minWidth: 580, minHeight: 480)
        .task {
            model.start()
            await settingsModel.load()
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.attention, "Needs attention", "bell.badge", model.surfacedCount, key: "1")
            tabButton(.overview, "Overview", "rectangle.3.group", 0, key: "2")
            tabButton(.review, "Review", "tray", model.reviewItems.count, key: "3")
            tabButton(.settings, "Settings", "gearshape", settingsModel.pendingEvolutionUpdateCount, key: "4")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func tabButton(_ tab: MainTab, _ title: String, _ icon: String, _ count: Int, key: Character) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                countPill(count)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Brand.primary.opacity(0.15) : .clear)
            )
            .foregroundStyle(selected ? Brand.primary : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    /// Notification pill: hidden at 0, the number through 9, then "9+".
    @ViewBuilder
    private func countPill(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 17)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.red))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .attention: NavigationStack { AttentionListView(model: model) }
        case .overview:  NavigationStack { OverviewView(model: overviewModel) }
        case .review:    NavigationStack { ReviewQueueView(model: model) }
        case .settings:  NavigationStack { SettingsView(model: settingsModel) }
        }
    }
}
