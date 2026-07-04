import SwiftUI

/// The Slacker logo mark: the pixel-art coffee cup, clipped to a rounded square.
/// Used in onboarding, empty states, and the menu bar popover. `.interpolation(.none)`
/// keeps the pixel-art edges crisp at any size.
struct BrandLogo: View {
    var size: CGFloat = 56

    var body: some View {
        Image("CoffeeCup")
            .resizable()
            .interpolation(.none)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: Brand.primary.opacity(0.35), radius: size * 0.14, y: size * 0.06)
    }
}

/// Wordmark: logo + "Slacker" set in the rounded display face.
struct BrandWordmark: View {
    var logoSize: CGFloat = 28
    var body: some View {
        HStack(spacing: 8) {
            BrandLogo(size: logoSize)
            Text("Slacker").font(Brand.display(logoSize * 0.74))
        }
    }
}
