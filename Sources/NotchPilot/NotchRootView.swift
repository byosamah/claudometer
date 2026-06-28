import SwiftUI

/// The SwiftUI content hosted inside the notch panel.
/// Collapsed = a slim pill (mascot + session %). Expanded (on hover) = a panel
/// that drops below the notch with session/weekly readouts and the Start button.
///
/// No `@State` anywhere — only `@EnvironmentObject` — because the `@State` macro
/// plugin is absent on the Command-Line-Tools toolchain this builds with.
struct NotchRootView: View {
    @EnvironmentObject private var notch: NotchState
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        ZStack {
            background
            Group {
                if notch.isExpanded { expanded } else { collapsed }
            }
            .padding(.horizontal, notch.isExpanded ? 16 : 11)
            .padding(.vertical, notch.isExpanded ? 14 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: notch.isExpanded)
    }

    private var cornerRadius: CGFloat { notch.isExpanded ? 22 : 15 }

    private var background: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(store.accentColor.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
    }

    // MARK: Collapsed pill

    private var collapsed: some View {
        HStack(spacing: 7) {
            MascotView(state: store.mascot)
                .frame(width: 22, height: 22)
            Text(store.collapsedLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: Expanded panel

    private var expanded: some View {
        HStack(spacing: 14) {
            MascotView(state: store.mascot)
                .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 5) {
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
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if store.isWaking {
            Label("Starting…", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        } else if case .ok = store.state {
            if store.hasOpenWindow {
                Label("Window active", systemImage: "circle.fill")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(store.accentColor)
            } else if store.confirming {
                pillButton("Confirm: open 5h window", fill: .severityDanger) {
                    store.confirmStart()
                }
            } else {
                pillButton("Start Window", fill: .severityCalm) {
                    store.requestStart()
                }
            }
        } else {
            Text(store.statusText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
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
