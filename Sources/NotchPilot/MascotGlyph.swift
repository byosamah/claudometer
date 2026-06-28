import SwiftUI

/// A crisp, lightweight VECTOR rendering of the Claude sunburst mascot for the
/// menu bar. This is NOT the live WKWebView mascot (that one is heavy and blurry
/// at status-item size); it's a static-but-mood-tinted glyph drawn with `Canvas`,
/// so it stays sharp at 16-22pt and costs nothing to animate (it just crossfades
/// when the mood changes). The full GSAP mascot still plays inside the panel.
struct MascotGlyph: View {
    var state: MascotState
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width
            let c = CGPoint(x: w / 2, y: sz.height / 2)
            let tint = Self.tint(for: state)

            // ---- sunburst rays ---------------------------------------------
            let rayCount = 11
            let inner = w * 0.20
            let outer = w * (state.glyphDrooped ? 0.42 : 0.47)
            let rayWidth = w * 0.085
            for i in 0..<rayCount {
                let angle = (Double(i) / Double(rayCount)) * 2 * .pi - .pi / 2
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
                p.addLine(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
                ctx.stroke(p, with: .color(tint),
                           style: StrokeStyle(lineWidth: rayWidth, lineCap: .round))
            }

            // ---- body ------------------------------------------------------
            let bodyR = w * 0.235
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - bodyR, y: c.y - bodyR,
                                            width: bodyR * 2, height: bodyR * 2)),
                     with: .color(tint))

            // ---- eyes (dark, so they read on the coral body) ---------------
            let eyeColor = GraphicsContext.Shading.color(.black.opacity(0.72))
            let eyeDX = w * 0.095
            let eyeY = c.y - w * 0.01
            if state.glyphDrooped {
                // sleepy / offline: two short horizontal slits
                let slitW = w * 0.10, slitH = w * 0.028
                for dx in [-eyeDX, eyeDX] {
                    ctx.fill(Path(roundedRect: CGRect(x: c.x + dx - slitW / 2, y: eyeY - slitH / 2,
                                                      width: slitW, height: slitH),
                                  cornerRadius: slitH / 2), with: eyeColor)
                }
            } else {
                let eyeR = w * (state.glyphAlarmed ? 0.058 : 0.05)
                for dx in [-eyeDX, eyeDX] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x + dx - eyeR, y: eyeY - eyeR,
                                                    width: eyeR * 2, height: eyeR * 2)),
                             with: eyeColor)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Mood -> glyph tint, reusing the app's severity palette.
    static func tint(for state: MascotState) -> Color {
        switch state {
        case .frantic:               return .severityDanger
        case .needsAuth, .offline:   return Color(white: 0.62)
        case .dormant:               return .mascotCoral.opacity(0.92)
        case .playing, .wakeup:      return .mascotCoral
        }
    }
}

private extension MascotState {
    /// Eyes-as-slits + drooped rays (low-energy states).
    var glyphDrooped: Bool {
        switch self { case .needsAuth, .offline: return true; default: return false }
    }
    /// Wider, alarmed eyes.
    var glyphAlarmed: Bool {
        if case .frantic = self { return true }
        return false
    }
}
