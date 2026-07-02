import SwiftUI
import AppKit

/// Guided "connect your Claude" walkthrough, shown inside the panel whenever the
/// app isn't connected yet (`UsageStore.needsWalkthrough`): first run, a revoked
/// login, or a brand-new install stuck behind the Keychain dialog.
///
/// Honest by design: it never invents a percentage. Every step's checkmark is
/// live-derived from real signals (CLI on disk, a Keychain read that actually
/// succeeded), the diagnosis box says exactly what is blocking the connection
/// right now, and the preview meters are empty until real data exists. The
/// moment a poll succeeds, the panel flips to the live meters and this view
/// disappears.
struct OnboardingView: View {
    @EnvironmentObject private var store: UsageStore

    private var cliInstalled: Bool { store.claudeInstalled }
    private var signedIn: Bool { store.tokenSeen }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your Claude")
                .font(.system(.headline, design: .rounded).weight(.semibold))
            Text("Claudometer shows your own Claude usage as live meters. Three quick steps:")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1,
                 done: cliInstalled,
                 title: cliInstalled ? "Claude Code is installed" : "Install Claude Code",
                 detail: cliInstalled ? nil : "The free CLI that holds your Claude login.") {
                if !cliInstalled {
                    Button("Get Claude Code") { open("https://www.anthropic.com/claude-code") }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                }
            }

            step(number: 2,
                 done: signedIn,
                 title: signedIn ? "Signed in to Claude" : "Sign in once",
                 detail: signedIn ? nil
                                  : "In Terminal, run \u{201C}claude\u{201D} and log in with your Claude account.") {
                EmptyView()
            }

            step(number: 3,
                 done: signedIn,
                 title: signedIn ? "Keychain access allowed" : "Allow Keychain access",
                 detail: signedIn ? nil
                                  : "macOS asks once about \u{201C}Claude Code-credentials\u{201D}. Click Always Allow so the meters can read that login.") {
                EmptyView()
            }

            statusArea

            if !store.hasConnectedBefore { preview }

            Button {
                store.poll()
            } label: {
                Label(store.isRateLimited ? "Waiting out the rate limit…" : "Recheck",
                      systemImage: "arrow.clockwise")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.mascotCoral)
            // During a 429 every request restarts the cooldown, so the one thing
            // Recheck must not do is fire one (poll() also no-ops as a backstop).
            .disabled(store.isRateLimited)
            .padding(.top, 2)
        }
    }

    // MARK: Live diagnosis — what is blocking the connection right now

    @ViewBuilder
    private var statusArea: some View {
        if !store.loadedOnce {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking your setup…")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else if let problem = store.setupProblem {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.severityWarn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(problem.title)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                    Text(problem.detail)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.controlCorner))
        }
    }

    // MARK: What you'll see — empty meters, never fabricated numbers

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Once connected, your live meters appear here:")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
            previewRow(label: "Session", hint: "your 5-hour window")
            previewRow(label: "Weekly", hint: "your 7-day limit")
        }
        .padding(.top, 2)
    }

    private func previewRow(label: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hint)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            UsageBar(fraction: 0, color: .mascotCoral, height: 5)
                .opacity(0.6)
        }
    }

    /// One numbered step row: a state icon, a title, an optional detail line, and
    /// optional trailing control (e.g. the "Get Claude Code" button).
    @ViewBuilder
    private func step<Trailing: View>(
        number: Int, done: Bool, title: String, detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.mascotCoral : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                trailing()
            }
            Spacer(minLength: 0)
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
