import SwiftUI

/// The redesigned Liquid Glass content shown in the menu bar panel (and, when
/// pinned, the expanded notch HUD). One layout, two homes. Observes the shared
/// `UsageStore` + `AppSettings`. No `@State` (CLT toolchain): only env objects.
struct UsagePanelView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var waiting: WaitingStore

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                header
                waitingSection
                content
                updateRow
                Divider().opacity(0.5)
                footer
            }
            .padding(GlassTheme.contentPadding)
            .frame(width: GlassTheme.panelWidth, alignment: .leading)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.panelCorner))
    }

    // MARK: Waiting sessions (shown only when one or more are blocked on the user)

    @ViewBuilder
    private var waitingSection: some View {
        if !waiting.waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Waiting for you", systemImage: "bell.badge.fill")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.mascotCoral)
                ForEach(waiting.waiting) { session in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.project)
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .lineLimit(1)
                            Text("waiting \(WaitingStore.elapsed(since: session.since))")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            waiting.dismiss(session.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.controlCorner))
        }
    }

    // MARK: Update banner (only when a newer build is published)

    @ViewBuilder
    private var updateRow: some View {
        if updates.available {
            Button {
                updates.openDownload()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(updates.latestVersion.map { "Update available · v\($0)" } ?? "Update available")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                    Spacer(minLength: 0)
                    Text("Download")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.glass)
            .tint(.mascotCoral)
        }
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
        } else if store.needsWalkthrough {
            OnboardingView()
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
        VStack(spacing: 12) {
            toggleRow("Alert me when Claude's waiting", isOn: $settings.questionAlertsEnabled)
            toggleRow("Pin to notch", isOn: $settings.pinNotch)
            toggleRow("Launch at login", isOn: loginBinding)
        }
        .tint(.mascotCoral)
    }

    /// A settings-style toggle row: the label fills the width and hugs the leading
    /// edge, which pins every switch to a common trailing column (macOS System
    /// Settings convention), instead of each row centering on its own content.
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
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
