import SwiftUI

/// Overview tab (§8.3): the ambient at-a-glance layer across all watched channels.
/// The attention list is the headline; this answers "what's going on across everything."
struct OverviewView: View {
    @Bindable var model: OverviewViewModel
    var showsNavigationChrome = true

    @State private var expandedChannelID: String?

    var body: some View {
        Group {
            if model.activeChannels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No active channels")
                        .font(.title3.weight(.medium))
                    Text("Active watched channels show up here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("Channels")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(model.activeChannels) { channel in
                            let isExpanded = expandedChannelID == channel.id
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedChannelID = isExpanded ? nil : channel.id
                                }
                            } label: {
                                ChannelTab(channel: channel, isExpanded: isExpanded)
                            }
                            .buttonStyle(.plain)

                            if isExpanded {
                                ChannelSummaryDropdown(channel: channel)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(showsNavigationChrome ? "Overview" : "")
        .task { await model.reload() }
    }
}

private struct ChannelTab: View {
    let channel: OverviewViewModel.ChannelOverview
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                .font(.caption)
                .foregroundStyle(Brand.primary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(channel.lastActivityText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))

            if channel.openCount > 0 {
                Text("\(channel.openCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Brand.primary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ChannelSummaryDropdown: View {
    let channel: OverviewViewModel.ChannelOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if channel.openCount > 0 {
                    Text("\(channel.openCount) open")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.primary.opacity(0.14)))
                }
            }

            Text(channel.summary ?? "No summary yet today.")
                .font(.body)
                .foregroundStyle(channel.summary == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(channel.lastActivityText())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Brand.primary.opacity(0.14))
        )
        .padding(.leading, 26)
    }
}
