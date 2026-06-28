import SwiftUI
import WebKit

// MARK: - Mood model

/// The mascot's mood, driven by Claudometer's usage/auth/network state.
public enum MascotState: Equatable, Sendable {
    case dormant
    case playing(intensity: Double)   // 0...1, scales liveliness
    case frantic
    case wakeup
    case needsAuth
    case offline
}

// MARK: - Coral / amber / red severity palette

public extension Color {
    /// Claude coral, the brand body color. #CC785C
    static let mascotCoral       = Color(.sRGB, red: 0.800, green: 0.471, blue: 0.361, opacity: 1)
    /// Brighter coral used for highlights. #D97757
    static let mascotCoralBright = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341, opacity: 1)
    /// Soft peach glow tone. #ED9E7F
    static let mascotCoralGlow   = Color(.sRGB, red: 0.929, green: 0.620, blue: 0.498, opacity: 1)

    /// Severity ramp: calm -> warn -> danger.
    static let severityCalm   = Color.mascotCoral
    static let severityWarn   = Color(.sRGB, red: 0.910, green: 0.639, blue: 0.243, opacity: 1) // amber #E8A33E
    static let severityDanger = Color(.sRGB, red: 0.851, green: 0.290, blue: 0.247, opacity: 1) // red   #D94A3F
}

// MARK: - Mascot (the real Claude sunburst, rendered as SVG + GSAP in a WKWebView)

/// Hosts `Resources/mascot.html` (a self-contained SVG + GSAP animation) in a
/// transparent WKWebView and drives its mood via the page's `window.NotchMascot`
/// API. One instance is reused across collapse/expand (it just resizes), so the
/// always-visible pill never flashes.
public struct MascotView: NSViewRepresentable {
    private let state: MascotState

    public init(state: MascotState, expanded: Bool = true) {
        self.state = state
        // `expanded` is accepted for call-site symmetry; the SVG scales itself.
        _ = expanded
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        // Transparent background so the page floats over the panel, not on white.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        if let url = Bundle.main.url(forResource: "mascot", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(Self.moodScript(for: state))
    }

    /// Maps a MascotState to a `window.NotchMascot.setMood(name, intensity)` call.
    static func moodScript(for state: MascotState) -> String {
        let mood: String
        let intensity: Double
        switch state {
        case .dormant:            mood = "idle";    intensity = 0.4
        case .playing(let i):     mood = "playing"; intensity = min(max(i, 0), 1)
        case .frantic:            mood = "frantic"; intensity = 1.0
        case .wakeup:             mood = "wakeup";  intensity = 0.8
        case .needsAuth:          mood = "sleepy";  intensity = 0.0
        case .offline:            mood = "offline"; intensity = 0.0
        }
        return "window.NotchMascot && window.NotchMascot.setMood('\(mood)', \(intensity));"
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?

        /// Remember the latest desired mood; apply now if the page is ready,
        /// otherwise replay it once navigation finishes.
        func apply(_ script: String) {
            pending = script
            if loaded { flush() }
        }

        private func flush() {
            guard let script = pending, let webView else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }
    }
}
