import SwiftUI

/// Sheet for adding channels to watch. Lists the channels you're a member of that
/// aren't watched yet, grouped by workspace, each with an "Add" action. The catalog
/// lookup pulls newly joined channels from Slack (a user token sees channels you're in).
struct AddChannelView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add channel").font(.headline)
                Spacer()
                Button {
                    Task { await model.findNewChannels() }
                } label: {
                    Label("Find new channels", systemImage: "magnifyingglass")
                }
                .disabled(model.isFindingChannels)
                Button("Done") { model.isShowingAddChannel = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if !model.hasUnwatchedChannels {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("All your channels are added.").font(.headline)
                    Text("Joined a new channel in Slack? Choose Find new channels to pull it in.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(model.workspaces) { workspace in
                        let available = model.unwatchedChannels(for: workspace.id)
                        if !available.isEmpty {
                            Section(workspace.name) {
                                ForEach(available) { channel in
                                    HStack {
                                        Label(channel.name, systemImage: channel.isPrivate ? "lock.fill" : "number")
                                        Spacer()
                                        Button("Add") { model.addChannel(channel) }
                                            .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .task { await model.load() }
    }
}
