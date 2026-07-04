import SwiftUI

/// App entry point.
///
/// Two scenes per the spec (`docs/IMPLEMENTATION.md` §1):
/// - `MenuBarExtra` is the primary entry point (badge + quick popover).
/// - `WindowGroup` hosts the main lists/settings window.
///
/// The main window shows onboarding until the user has connected Slack and picked
/// channels; afterward it shows the main UI.
@main
struct SlackerApp: App {
    @State private var root = AppRoot()

    var body: some Scene {
        // A single, unique main window (not a WindowGroup) — so "Open Slacker" focuses
        // the existing window instead of spawning a new one each time.
        Window("Slacker", id: "main") {
            RootView(root: root)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContentView(root: root)
        } label: {
            // Badge: app icon + open-item count (§8.1).
            let count = root.badgeCount
            Image(nsImage: MenuBarIcon.image)
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

private enum MenuBarIcon {
    static let image: NSImage = {
        let canvasSize = NSSize(width: 20, height: 20)
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        NSApplication.shared.applicationIconImage.draw(
            in: NSRect(x: 0, y: 0, width: 20, height: 20),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }()
}

/// Routes between onboarding and the main UI based on app state.
struct RootView: View {
    @Bindable var root: AppRoot
    @State private var onboarding: OnboardingModel?

    var body: some View {
        VStack(spacing: 0) {
            if let error = root.startupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.orange)
            }
            content
        }
        .tint(Brand.primary)
    }

    @ViewBuilder
    private var content: some View {
        if root.isOnboarded, let main = root.mainViewModel,
           let overview = root.overviewViewModel, let settings = root.settingsModel {
            MainView(model: main, overviewModel: overview, settingsModel: settings)
        } else if !root.isOnboarded, let onboarding {
            OnboardingView(model: onboarding)
        } else {
            Color.clear
                .onAppear { if onboarding == nil { onboarding = root.makeOnboardingModel() } }
        }
    }
}

/// Menu-bar popover (§8.1): top open items + a button to open the main window.
struct MenuBarContentView: View {
    @Bindable var root: AppRoot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandWordmark(logoSize: 22)
                Spacer()
                if let main = root.mainViewModel, main.surfacedCount > 0 {
                    Text("\(main.surfacedCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Brand.primary))
                }
            }

            if let main = root.mainViewModel, main.surfacedCount > 0 {
                ForEach((main.missedFollowups + main.staleItems + main.mentions).prefix(5)) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.type.brandIcon)
                            .font(.caption2).foregroundStyle(row.type.brandColor)
                        Text("#\(row.channelName): \(row.snippet)")
                            .lineLimit(1).font(.callout)
                    }
                }
            } else {
                Label("All caught up.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.resolved).font(.callout)
            }

            Divider()
            Button("Open Slacker") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
    }
}
