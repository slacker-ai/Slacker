import SwiftUI

/// A small "?" icon that explains a setting on hover. Uses an `onHover`-driven popover
/// (instant and reliable; `.help()` tooltips are delayed and can silently no-op).
struct HelpBadge: View {
    let text: String
    @State private var isHovering = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            // Anchored below so the popover doesn't cover the icon (avoids hover flicker).
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
                    .interactiveDismissDisabled()
            }
            .help(text)
            .accessibilityLabel("Help")
            .accessibilityHint(text)
    }
}
