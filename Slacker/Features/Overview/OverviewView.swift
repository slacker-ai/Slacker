import SwiftUI

/// Overview tab (§8.3): the ambient at-a-glance layer across all watched channels.
/// The attention list is the headline; this answers "what's going on across everything."
struct OverviewView: View {
    @Bindable var model: OverviewViewModel

    var body: some View {
        Group {
            if model.channels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No watched channels yet.")
                        .font(.title3.weight(.medium))
                    Text("Pick channels in Settings to see daily summaries here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.channels) { channel in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 6) {
                                    Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                                        .font(.caption).foregroundStyle(Brand.primary)
                                    Text(channel.name).font(Brand.display(15))
                                    Spacer()
                                    if channel.openCount > 0 {
                                        Text("\(channel.openCount) open")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Brand.primary)
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Capsule().fill(Brand.primary.opacity(0.14)))
                                    }
                                }
                                Text(channel.summary ?? "No summary yet today.")
                                    .font(.subheadline)
                                    .foregroundStyle(channel.summary == nil ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(channel.lastActivityText())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .brandCard(tint: Brand.primary)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .task { await model.reload() }
    }
}
