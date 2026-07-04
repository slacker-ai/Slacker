import SwiftUI

/// The review queue (§8.4): ambiguous items the system is uncertain about. The user's
/// triage here ("This matters" / "Ignore") feeds the calibration flywheel (§7.5).
struct ReviewQueueView: View {
    @Bindable var model: MainViewModel

    var body: some View {
        Group {
            if model.reviewItems.isEmpty {
                VStack(spacing: 12) {
                    BrandLogo(size: 56)
                    Text("Nothing to review")
                        .font(Brand.display(20))
                    Text("Uncertain items show up here for a quick yes/no.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.reviewItems) { row in
                            ItemRowView(row: row, style: .review, model: model)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Review queue")
    }
}
