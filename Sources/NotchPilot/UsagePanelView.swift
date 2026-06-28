import SwiftUI

/// The redesigned Liquid Glass content shown in the menu bar panel (and, when
/// pinned, the expanded notch HUD). One layout, two homes. Observes the shared
/// `UsageStore` + `AppSettings`. No `@State` (CLT toolchain): only env objects.
struct UsagePanelView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
                Divider().opacity(0.5)
                footer
            }
            .padding(GlassTheme.contentPadding)
            .frame(width: GlassTheme.panelWidth, alignment: .leading)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.panelCorner))
    }

    // MARK: Header — live mascot + identity

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(state: store.mascot, expanded: true)
                .frame(width: 46, height: 46)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        if case .ok = store.state { return "Max plan usage" }
        return store.statusText
    }

    // MARK: Content — meters (when connected) or an honest status line

    @ViewBuilder
    private var content: some View {
        if case .ok = store.state {
            VStack(alignment: .leading, spacing: 14) {
                meter(title: "Session",
                      percent: store.sessionPercent,
                      fraction: store.sessionFraction,
                      reset: store.sessionResetText,
                      color: store.accentColor)
                meter(title: "Weekly",
                      percent: store.weeklyPercent,
                      fraction: store.weeklyFraction,
                      reset: store.weeklyResetText,
                      color: .secondary)
            }
            actionArea
        } else {
            Text(store.statusText)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
    }

    private func meter(title: String, percent: Int, fraction: Double,
                       reset: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                Spacer()
                Text("\(percent)%")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: fraction, color: color)
            if !reset.isEmpty {
                Text(reset)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Start-window action (one tap)

    @ViewBuilder
    private var actionArea: some View {
        if store.isWaking {
            Label("Starting a window…", systemImage: "sparkles")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        } else if store.hasOpenWindow {
            Label("5-hour window active", systemImage: "circle.fill")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(store.accentColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        } else {
            VStack(spacing: 6) {
                Button {
                    store.confirmStart()
                } label: {
                    Text("Start Window")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.mascotCoral)
                if let err = store.startError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(Color.severityDanger)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Footer — inline toggles

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle("Pin to notch", isOn: $settings.pinNotch)
            Toggle("Launch at login", isOn: loginBinding)
        }
        .toggleStyle(.switch)
        .tint(.mascotCoral)
        .font(.system(.subheadline, design: .rounded))
    }

    /// LoginItem is a static AppKit wrapper, not observable; bridge it to a Toggle.
    /// On `.requiresApproval` the toggle can't take effect alone, so deep-link to
    /// Login Items instead of letting it silently snap back off.
    private var loginBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { _ in
            _ = LoginItem.toggle()
            if LoginItem.needsApproval { LoginItem.openLoginItemsSettings() }
        })
    }
}
