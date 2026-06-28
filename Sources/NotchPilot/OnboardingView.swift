import SwiftUI
import AppKit

/// First-run "connect your Claude" guide, shown inside the panel when no usable
/// Claude credential is found (`ConnectionState.needsAuth`).
///
/// Honest by design: it never invents a percentage. It live-checks whether the
/// Claude Code CLI is installed (step 1), points the user to sign in (step 2),
/// and offers a Recheck that re-polls. The moment a token appears, the next poll
/// flips the panel to the real meters and this view disappears.
struct OnboardingView: View {
    @EnvironmentObject private var store: UsageStore

    private var cliInstalled: Bool { store.claudeInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your Claude")
                .font(.system(.headline, design: .rounded).weight(.semibold))
            Text("Claudometer shows your own Claude Max usage. Two quick steps:")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1,
                 done: cliInstalled,
                 title: cliInstalled ? "Claude Code is installed" : "Install Claude Code",
                 detail: cliInstalled ? nil : "The free CLI that powers your usage data.") {
                if !cliInstalled {
                    Button("Get Claude Code") { open("https://www.anthropic.com/claude-code") }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                }
            }

            step(number: 2,
                 done: false,
                 title: "Sign in to Claude",
                 detail: "In Terminal, run \u{201C}claude\u{201D} and log in once.") {
                EmptyView()
            }

            Button {
                store.poll()
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.mascotCoral)
            .padding(.top, 2)
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
