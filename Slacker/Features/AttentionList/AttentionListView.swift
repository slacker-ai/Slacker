import SwiftUI
import AppKit

/// The default "Needs attention" view (§8.2): ranked, grouped by signal type.
struct AttentionListView: View {
    @Bindable var model: MainViewModel
    var showsNavigationChrome = true

    var body: some View {
        Group {
            if model.surfacedCount == 0 {
                CaughtUpView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !model.missedFollowups.isEmpty {
                            signalSection(.missedFollowup, rows: model.missedFollowups)
                        }
                        if !model.staleItems.isEmpty {
                            signalSection(.stale, rows: model.staleItems)
                        }
                        if !model.mentions.isEmpty {
                            signalSection(.mention, rows: model.mentions)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(showsNavigationChrome ? "Needs attention" : "")
    }

    private func signalSection(_ type: ItemType, rows: [ItemRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: type.brandIcon)
                    .foregroundStyle(type.brandColor)
                Text(type.brandSectionTitle)
                    .font(Brand.display(15))
                Text("\(rows.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(type.brandColor.opacity(0.15)))
            }
            ForEach(rows) { row in
                ItemRowView(row: row, style: .attention, model: model)
            }
        }
    }
}

/// Empty state — never blank (§8.6), now branded.
struct CaughtUpView: View {
    var body: some View {
        VStack(spacing: 14) {
            BrandLogo(size: 64)
            Text("All caught up")
                .font(Brand.display(22))
            Text("Nothing needs your attention right now.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One item, rendered as a signal-coded card. Used by attention list and review queue.
struct ItemRowView: View {
    enum Style { case attention, review }

    let row: ItemRow
    let style: Style
    @Bindable var model: MainViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Color rail keys the card to its signal type.
            Rectangle()
                .fill(row.type.brandColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                header
                Text(row.snippet)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = row.threadSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(Brand.cardPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                .strokeBorder(row.type.brandColor.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: Brand.corner, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("#\(row.channelName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.primary)
            if let author = row.authorName {
                Text("· \(author)").font(.caption).foregroundStyle(.secondary)
            }
            if row.responseCount > 0 {
                Label("\(row.responseCount)", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.ageText()).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                if let url = row.deepLink() { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open in Slack", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .tint(Brand.primary)

            Spacer()

            switch style {
            case .attention:
                Button("Resolve") { Task { await model.resolve(row) } }
                Button("Dismiss") { Task { await model.dismiss(row) } }
            case .review:
                Button("This matters") { Task { await model.promote(row) } }
                    .buttonStyle(.borderedProminent)
                Button("Ignore") { Task { await model.ignore(row) } }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }
}
