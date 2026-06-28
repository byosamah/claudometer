import SwiftUI

/// Layout + material constants for the Liquid Glass surfaces, so the panel and
/// the (pinned) notch HUD share one visual language. Colors live in
/// `MascotView.swift` (coral + severity ramp); this is geometry + helpers.
enum GlassTheme {
    static let panelWidth: CGFloat = 300
    static let panelCorner: CGFloat = 26
    static let controlCorner: CGFloat = 14
    static let contentPadding: CGFloat = 18
}

/// A slim usage meter: faint track + accent fill, spring-animated on change.
struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: fraction)
    }
}
