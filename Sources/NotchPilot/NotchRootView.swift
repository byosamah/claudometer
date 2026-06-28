import SwiftUI

/// The SwiftUI content hosted inside the notch panel.
/// Collapsed = a slim pill (mascot + session %). Expanded (on hover) = a panel
/// that drops below the notch with session/weekly readouts and the Start button.
///
/// The mascot is the FIRST child of one stable HStack (not inside the if/else),
/// so its WKWebView instance is reused across collapse/expand and never flashes.
///
/// No `@State` anywhere — only `@EnvironmentObject` — because the `@State` macro
/// plugin is absent on the Command-Line-Tools toolchain this builds with.
struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchState
    @EnvironmentObject private var store: UsageStore

    private var expanded: Bool { notch.isExpanded }

    var body: some View {
        ZStack {
            background
            HStack(spacing: expanded ? 14 : 7) {
                MascotView(state: store.mascot, expanded: expanded)
                    .frame(width: expanded ? 62 : 22, height: expanded ? 62 : 22)
                    .allowsHitTesting(false)   // never let the webview eat hover/clicks
                content
                if expanded { Spacer(minLength: 0) }
            }
            .padding(.horizontal, expanded ? 16 : 11)
            .padding(.vertical, expanded ? 12 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: expanded)
    }

    private var cornerRadius: CGFloat { expanded ? 22 : 15 }

    @ViewBuilder
    private var background: some View {
        if expanded {
            // Concave top corners so the panel reads as carved out of the screen
            // around the notch (top edge sits flush at the notch's bottom line).
            NotchCarveShape(notchWidth: notch.notchWidth)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    NotchCarveShape(notchWidth: notch.notchWidth)
                        .stroke(store.accentColor.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(store.accentColor.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
        }
    }

    // MARK: Content (everything to the right of the mascot)

    @ViewBuilder
    private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 5) {
                if case .ok = store.state {
                    Text(store.sessionLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)

                    if !store.weeklyLine.isEmpty {
                        Text(store.weeklyLine)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 4)
                    actionRow
                } else {
                    Text(store.statusText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
        } else {
            Text(store.collapsedLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: Start-window action row (only shown in the .ok state)

    @ViewBuilder
    private var actionRow: some View {
        if store.isWaking {
            Label("Starting…", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        } else if store.hasOpenWindow {
            Label("Window active", systemImage: "circle.fill")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(store.accentColor)
        } else if store.confirming {
            pillButton("Confirm: open 5h window", fill: .severityDanger) {
                store.confirmStart()
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let err = store.startError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.severityDanger)
                }
                pillButton("Start Window", fill: .severityCalm) {
                    store.requestStart()
                }
            }
        }
    }

    private func pillButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// Panel outline that GROWS OUT OF THE NOTCH: the top edge is only the notch's
/// width (flush at the notch's bottom line), then concave fillets flare it out
/// to the full panel width, with convex rounded corners on the bottom. So the
/// panel reads as one carved black shape continuous with the notch.
struct NotchCarveShape: Shape {
    var notchWidth: CGFloat          // points; the flat top spans this, centered
    var flare: CGFloat = 16          // height of the concave flare from notch to body
    var topCorner: CGFloat = 9       // small convex round on the outer top corners
    var bottomRadius: CGFloat = 24   // convex round on the bottom corners

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let br = max(0, min(bottomRadius, w / 2, h / 2))
        let f  = max(0, min(flare, h / 2))
        let oc = max(0, min(topCorner, (w - notchWidth) / 2 - 0.1, f))
        // Clamp the notch span so the flares always fit inside the panel width.
        let half = max(0, min(notchWidth / 2, w / 2 - f - oc))
        let nL = w / 2 - half
        let nR = w / 2 + half

        var p = Path()
        p.move(to: CGPoint(x: nL, y: 0))
        p.addLine(to: CGPoint(x: nR, y: 0))                          // flush top under the notch
        // right concave flare (notch edge -> body), like the notch's own corner
        p.addQuadCurve(to: CGPoint(x: nR + f, y: f), control: CGPoint(x: nR, y: f))
        p.addLine(to: CGPoint(x: w - oc, y: f))                      // right shoulder
        p.addQuadCurve(to: CGPoint(x: w, y: f + oc), control: CGPoint(x: w, y: f)) // outer top-right
        p.addLine(to: CGPoint(x: w, y: h - br))                      // right side
        p.addQuadCurve(to: CGPoint(x: w - br, y: h), control: CGPoint(x: w, y: h)) // bottom-right
        p.addLine(to: CGPoint(x: br, y: h))                          // bottom
        p.addQuadCurve(to: CGPoint(x: 0, y: h - br), control: CGPoint(x: 0, y: h)) // bottom-left
        p.addLine(to: CGPoint(x: 0, y: f + oc))                      // left side
        p.addQuadCurve(to: CGPoint(x: oc, y: f), control: CGPoint(x: 0, y: f))     // outer top-left
        p.addLine(to: CGPoint(x: nL - f, y: f))                      // left shoulder
        p.addQuadCurve(to: CGPoint(x: nL, y: 0), control: CGPoint(x: nL, y: f))    // left concave flare
        p.closeSubpath()
        return p
    }
}
