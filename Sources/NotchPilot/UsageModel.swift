import Foundation

// MARK: - Connection State (the public surface this area returns)

/// The four states the rest of Claudometer renders from.
enum ConnectionState: Sendable, Equatable {
    case ok(UsageSnapshot)
    case needsAuth        // 401, or no usable token in the Keychain
    case offline          // URLError / timeout / unreadable response
    case noBinary         // /usr/bin/security could not be launched
    case rateLimited(retryAfter: TimeInterval?)  // HTTP 429 — back off HARD, never fast-retry
}

// MARK: - Severity

/// Maps the `severity` string from the API into a closed set. Unknown strings
/// degrade to `.unknown` rather than throwing, so a new server value never
/// breaks decoding.
enum Severity: String, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown

    init(apiValue: String?) {
        guard let apiValue else { self = .unknown; return }
        self = Severity(rawValue: apiValue) ?? .unknown
    }
}

// MARK: - UsageSnapshot (cleaned, render-ready model)

struct UsageSnapshot: Sendable, Equatable {
    let sessionPercent: Int
    let sessionResetsAt: Date?
    let sessionSeverity: Severity
    /// True when the 5-hour window has ANY usage. Derived from the raw Double,
    /// so a freshly opened window (e.g. 0.3%, which rounds to 0%) still counts
    /// as open. Do not infer "window open" from `sessionPercent > 0`.
    let sessionHasUsage: Bool
    let weeklyPercent: Int
    let weeklyResetsAt: Date?
    let weeklySeverity: Severity
    let fetchedAt: Date
}

// MARK: - Robust ISO-8601 date parsing

/// Parses the API's `resets_at` timestamps, which carry SIX fractional-second
/// digits and a `+00:00` offset (e.g. "2026-06-28T15:50:00.220578+00:00").
///
/// Primary path: `Date.ISO8601FormatStyle`, which is lenient about the number
/// of fractional digits AND about their absence, and preserves microsecond
/// precision. It is a value type, so it is Sendable-safe for Swift 6.
///
/// Fallback path: normalise the fractional component to exactly 3 digits and
/// feed `ISO8601DateFormatter`. This only runs if the primary path ever fails.
enum ISODate {
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }

        if let date = try? Date.ISO8601FormatStyle().parse(string) {
            return date
        }

        // Defensive fallback.
        let normalized = normalizeFractional(string)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) {
            return date
        }
        // Last resort: no fractional seconds at all.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: stripFractional(string))
    }

    /// Rewrites the fractional-seconds run to exactly 3 digits, preserving the
    /// trailing timezone designator (`+00:00`, `Z`, or empty).
    private static func normalizeFractional(_ input: String) -> String {
        guard let dot = input.firstIndex(of: ".") else { return input }
        let afterDot = input.index(after: dot)
        var cursor = afterDot
        while cursor < input.endIndex, input[cursor].isNumber {
            cursor = input.index(after: cursor)
        }
        var fraction = String(input[afterDot..<cursor])
        if fraction.count > 3 { fraction = String(fraction.prefix(3)) }
        while fraction.count < 3 { fraction += "0" }
        return String(input[..<dot]) + "." + fraction + String(input[cursor...])
    }

    /// Removes the fractional component entirely, keeping the timezone.
    private static func stripFractional(_ input: String) -> String {
        guard let dot = input.firstIndex(of: ".") else { return input }
        var cursor = input.index(after: dot)
        while cursor < input.endIndex, input[cursor].isNumber {
            cursor = input.index(after: cursor)
        }
        return String(input[..<dot]) + String(input[cursor...])
    }
}

// MARK: - Raw wire structs (mirror the JSON exactly, snake_case)

/// Decoded straight from the response body. Every field is optional so a null
/// or an added/removed key never aborts decoding. `resets_at` is decoded as a
/// String and converted to Date later — this keeps null-handling explicit and
/// sidesteps JSONDecoder dateDecodingStrategy edge cases.
struct RawUsageResponse: Decodable {
    let five_hour: RawWindow?
    let seven_day: RawWindow?
    let seven_day_sonnet: RawWindow?
    let limits: [RawLimit]?
    let extra_usage: RawExtraUsage?
}

struct RawWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
    let limit_dollars: Double?   // null in the sample; Double? absorbs null
}

struct RawLimit: Decodable {
    let kind: String?
    let group: String?
    let percent: Int?
    let severity: String?
    let resets_at: String?
    let is_active: Bool?
    // `scope` is intentionally omitted; unknown keys are ignored by Codable.
}

struct RawExtraUsage: Decodable {
    let is_enabled: Bool?
}

// MARK: - Mapping wire -> snapshot

extension UsageSnapshot {
    /// Builds the render model from the decoded wire response.
    /// - session  comes from `five_hour`  + severity of the `kind == "session"`   limit.
    /// - weekly   comes from `seven_day`  + severity of the `kind == "weekly_all"` limit.
    static func make(from raw: RawUsageResponse, fetchedAt: Date = Date()) -> UsageSnapshot {
        let limits = raw.limits ?? []
        let sessionSeverity = Severity(apiValue: limits.first { $0.kind == "session" }?.severity)
        let weeklySeverity = Severity(apiValue: limits.first { $0.kind == "weekly_all" }?.severity)

        let sessionUtil = raw.five_hour?.utilization ?? 0

        return UsageSnapshot(
            sessionPercent: Self.clampPercent(raw.five_hour?.utilization),
            sessionResetsAt: ISODate.parse(raw.five_hour?.resets_at),
            sessionSeverity: sessionSeverity,
            sessionHasUsage: sessionUtil.isFinite && sessionUtil > 0,
            weeklyPercent: Self.clampPercent(raw.seven_day?.utilization),
            weeklyResetsAt: ISODate.parse(raw.seven_day?.resets_at),
            weeklySeverity: weeklySeverity,
            fetchedAt: fetchedAt
        )
    }

    /// Never feed an untrusted server Double straight into `Int(...)`: NaN,
    /// infinity, or a value past Int range traps (SIGABRT). Guard finiteness and
    /// clamp to a sane 0...100 percent.
    private static func clampPercent(_ value: Double?) -> Int {
        guard let value, value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 100))
    }
}

// MARK: - Token provider (reads the OAuth token out of the login Keychain)

struct OAuthCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
    let subscriptionType: String?
}

struct CredentialsEnvelope: Decodable {
    let claudeAiOauth: OAuthCredentials
}

enum TokenError: Error, Sendable, Equatable {
    case binaryNotFound        // /usr/bin/security could not be launched -> .noBinary
    case keychainDenied        // empty stdout: prompt denied or item missing -> .needsAuth
    case securityFailed(Int32) // non-zero exit from security
    case malformedJSON         // stdout was not the expected JSON envelope
    case timedOut              // security hung past the watchdog -> .offline (transient blip)
}

struct TokenProvider: Sendable {
    var service: String = "Claude Code-credentials"
    var securityPath: String = "/usr/bin/security"

    /// Reads + parses the token. On first run macOS shows a Keychain prompt for
    /// `/usr/bin/security`; until the user clicks "Always Allow" the call may
    /// return empty stdout (-> .keychainDenied) or block on the dialog.
    func accessToken() async throws -> String {
        let result = try await runSecurity()

        if result.exitCode != 0 {
            if result.data.isEmpty { throw TokenError.keychainDenied }
            throw TokenError.securityFailed(result.exitCode)
        }
        guard !result.data.isEmpty else { throw TokenError.keychainDenied }

        do {
            let envelope = try JSONDecoder().decode(CredentialsEnvelope.self, from: result.data)
            return envelope.claudeAiOauth.accessToken
        } catch {
            throw TokenError.malformedJSON
        }
    }

    /// Runs `security find-generic-password -s <service> -w` off the cooperative
    /// pool. Everything non-Sendable (Process, Pipe, FileHandle) is created and
    /// consumed inside the detached task; only `(Data, Int32)` crosses back.
    private func runSecurity() async throws -> (data: Data, exitCode: Int32) {
        let path = securityPath
        let svc = service
        return try await Task.detached(priority: .userInitiated) { () throws -> (Data, Int32) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["find-generic-password", "-s", svc, "-w"]

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice  // discard; avoids any stderr buffer deadlock

            do {
                try process.run()
            } catch {
                throw TokenError.binaryNotFound
            }

            // Watchdog: a granted ACL makes this read near-instant (~0.02s), but a
            // locked keychain or a wedged keychain subsystem can block `security`
            // with no end. The poll loop is single-flight (isPolling), so ONE infinite
            // read freezes the whole app on "Connecting…" forever. Bound it: SIGTERM at
            // a generous deadline (long enough never to cut off a first-run "Always
            // Allow" dialog), SIGKILL if it resists, then report the timeout so the
            // poller treats it as a transient blip and retries. Killing `security`
            // closes the pipe, which also unblocks the readToEnd() below.
            let killed = TimeoutFlag()
            let forceKill = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    killed.set()
                    process.terminate()                                 // SIGTERM
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: forceKill)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)

            // Read stdout to EOF BEFORE waiting, so a full pipe buffer can never
            // deadlock the process.
            let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            watchdog.cancel()

            if killed.get() { throw TokenError.timedOut }
            return (data, process.terminationStatus)
        }.value
    }
}

// MARK: - Usage client (the network call)

struct UsageClient: Sendable {
    var endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Ephemeral so the credentialed response is never written to the on-disk
    /// URLCache and we don't share process-wide cookie/credential storage.
    /// Tight timeouts so a stalled request can't outlive the poll interval.
    var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 40
        cfg.waitsForConnectivity = true   // ride out a brief connectivity gap instead of erroring
        return URLSession(configuration: cfg)
    }()

    /// Performs the authenticated GET and folds the outcome into ConnectionState.
    /// - 200..<300 -> decode -> .ok
    /// - 401       -> .needsAuth
    /// - 429       -> .rateLimited (poller backs off hard, never fast-retries)
    /// - URLError  -> .offline
    /// - other     -> .offline
    func fetchUsage(token: String) async -> ConnectionState {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .offline
            }

            switch http.statusCode {
            case 200..<300:
                guard let raw = try? JSONDecoder().decode(RawUsageResponse.self, from: data) else {
                    return .offline
                }
                return .ok(UsageSnapshot.make(from: raw))
            case 401:
                return .needsAuth
            case 429:
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
                return .rateLimited(retryAfter: ra)
            default:
                return .offline
            }
        } catch is URLError {
            return .offline
        } catch {
            return .offline
        }
    }
}

// MARK: - Coordinator (ties token + usage into a single ConnectionState)

struct UsageService: Sendable {
    var tokenProvider = TokenProvider()
    var usageClient = UsageClient()

    /// One-shot refresh used by the poller.
    func currentState() async -> ConnectionState {
        let token: String
        do {
            token = try await tokenProvider.accessToken()
        } catch TokenError.binaryNotFound {
            return .noBinary
        } catch TokenError.timedOut {
            // Keychain stalled past the watchdog. This is a transient fault, not a
            // missing credential, so surface it as offline (holds the last-good
            // reading and retries soon), never as needsAuth.
            return .offline
        } catch {
            return .needsAuth
        }
        return await usageClient.fetchUsage(token: token)
    }
}
