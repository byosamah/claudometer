import AppKit
import Combine

/// Hand-rolled, zero-dependency update check.
///
/// Reads a tiny JSON feed the developer hosts on the landing-page host (NOT the
/// Anthropic usage API, so it can never affect that poller's 429 back-off),
/// compares it to this bundle's build number, and publishes whether a newer
/// build is available. Following through opens the `.dmg` download in the
/// browser. We deliberately do NOT install in place: that is exactly what a
/// framework like Sparkle would add, and this project stays dependency-free.
@MainActor
final class UpdateChecker: ObservableObject {

    /// Shape of `updates.json`. `build` is the monotonic source of truth;
    /// `version` is the human-facing label shown in the UI.
    struct Feed: Decodable {
        let version: String
        let build: Int
        let downloadURL: String
        let notes: String?
        let minimumSystemVersion: String?
    }

    @Published private(set) var available = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false

    /// The feed lives on the landing-page host, on purpose a different origin
    /// from the usage API. (claudometer.vercel.app is taken by an unrelated
    /// product, so we use the team-scoped Vercel domain.)
    private let feedURL = URL(string: "https://claudometer-byosama.vercel.app/updates.json")!

    /// The feed URL with anonymous, non-identifying dimensions appended, so the
    /// server-side counter can break active-install checks down by app build and
    /// macOS version. No device id, no identity: just "a build-N app on macOS X
    /// checked in." The endpoint is a static-shaped JSON feed either way.
    private var feedRequestURL: URL {
        guard var c = URLComponents(url: feedURL, resolvingAgainstBaseURL: false) else { return feedURL }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        c.queryItems = [
            URLQueryItem(name: "v", value: String(currentBuild)),
            URLQueryItem(name: "os", value: "\(os.majorVersion).\(os.minorVersion)"),
        ]
        return c.url ?? feedURL
    }

    /// Ephemeral + cache-off so a stale CDN copy never masks a fresh release.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    /// This bundle's build number (CFBundleVersion). Defaults to 0 so a missing
    /// or garbled value can never *falsely* claim an update is available.
    private var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// Fetch the feed and update published state. Best-effort and silent on any
    /// failure: a failed update check is never surfaced as an app problem.
    func check() async {
        guard !isChecking else { return }   // single-flight: launch check vs. menu click
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }

        var request = URLRequest(url: feedRequestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
            let feed = try? JSONDecoder().decode(Feed.self, from: data)
        else { return }

        if feed.build > currentBuild, let url = URL(string: feed.downloadURL) {
            available = true
            latestVersion = feed.version
            downloadURL = url
        } else {
            available = false
            latestVersion = feed.version
        }
    }

    /// Open the `.dmg` download (or the releases page) in the default browser.
    func openDownload() {
        guard let url = downloadURL else { return }
        NSWorkspace.shared.open(url)
    }
}
