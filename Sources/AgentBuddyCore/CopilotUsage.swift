import Foundation

/// Copilot's monthly quotas from GitHub's `copilot_internal/user` endpoint, the
/// one Copilot's own editor extensions ask, with the GitHub CLI's existing
/// sign-in. The token is only sent to api.github.com and is never stored.
public enum CopilotUsage {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    public static func read() throws -> AgentReading {
        guard let token = token() else {
            throw ReadError("Sign in to the GitHub CLI (gh auth login) to see Copilot's quota.")
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBuddy", forHTTPHeaderField: "User-Agent")
        let answer = try HTTP.get(request)
        switch answer.status {
        case 200..<300:
            guard let body = JSON.parse(answer.data), body.isObject else {
                throw ReadError("GitHub returned an answer this app doesn't recognise")
            }
            return parse(body)
        case 401:
            throw ReadError("GitHub rejected the sign-in. Run gh auth login again.")
        case 403:
            throw ReadError("GitHub refused the Copilot request (HTTP 403).")
        case 404:
            throw ReadError("This GitHub account has no Copilot subscription (HTTP 404).")
        default:
            throw ReadError("The Copilot request failed (HTTP \(answer.status)).")
        }
    }

    // MARK: - Reading the answer

    /// One metered quota: how much of it is left, of how much, and when it renews.
    private struct Quota {
        let key: String
        let percentLeft: Double
        let entitlement: Double?
        let remaining: Double?
        let resetsAt: Date?

        var window: UsageWindow {
            var detail: String?
            if let entitlement, entitlement > 0, let remaining {
                detail = "\(CopilotUsage.number(max(entitlement - remaining, 0))) / \(CopilotUsage.number(entitlement)) \(CopilotUsage.unit(key))"
            }
            return UsageWindow(
                id: "copilot.\(key)", kind: .monthly, title: CopilotUsage.title(key),
                usedPercent: min(max(100 - percentLeft, 0), 100), resetsAt: resetsAt, detail: detail)
        }
    }

    public static func parse(_ body: JSON, fetchedAt: Date = Date()) -> AgentReading {
        var reading = AgentReading(agent: .copilot, fetchedAt: fetchedAt)
        reading.account = body["login"].nonEmptyString
        reading.plan = planName(body["copilot_plan"].string)
        // Paid plans report snapshots; Copilot Free reports its monthly quotas apart.
        let quotas = snapshotQuotas(body) ?? freeQuotas(body)
        reading.windows = quotas.sorted { rank($0.key) < rank($1.key) }.map(\.window)
        if reading.windows.isEmpty {
            reading.notes.append("No metered Copilot quota on this plan.")
        }
        return reading
    }

    /// The `quota_snapshots`, unlimited ones left out; nil when there are none at all.
    private static func snapshotQuotas(_ body: JSON) -> [Quota]? {
        guard var snapshots = body["quota_snapshots"].object, !snapshots.isEmpty else { return nil }
        // The older name for premium requests.
        if snapshots["premium_interactions"] == nil, let premium = snapshots.removeValue(forKey: "premium_models") {
            snapshots["premium_interactions"] = premium
        }
        let renews = Dates.parse(body["quota_reset_date_utc"].string) ?? Dates.parse(body["quota_reset_date"].string)
        return snapshots.compactMap { key, item in
            guard item["unlimited"].bool != true else { return nil }
            let entitlement = item["entitlement"].double
            let remaining = item["remaining"].double ?? item["quota_remaining"].double
            guard entitlement != 0 || remaining != 0 else { return nil }
            var percentLeft = item["percent_remaining"].double
            if percentLeft == nil, let entitlement, entitlement > 0, let remaining {
                percentLeft = remaining / entitlement * 100
            }
            guard let percentLeft else { return nil }
            let ownReset = item["quota_reset_at"].double.flatMap { $0 > 0 ? Dates.epoch($0) : nil }
            return Quota(key: key, percentLeft: percentLeft, entitlement: entitlement, remaining: remaining,
                         resetsAt: ownReset ?? renews)
        }
    }

    /// Copilot Free: what's left of each monthly quota, and the quotas themselves.
    private static func freeQuotas(_ body: JSON) -> [Quota] {
        guard let left = body["limited_user_quotas"].object else { return [] }
        let renews = Dates.parse(body["limited_user_reset_date"].string)
        return left.compactMap { key, value in
            guard let remaining = value.double, let entitlement = body["monthly_quotas"][key].double, entitlement > 0 else { return nil }
            return Quota(key: key, percentLeft: remaining / entitlement * 100, entitlement: entitlement, remaining: remaining,
                         resetsAt: renews)
        }
    }

    /// Premium requests first, then chat and completions, then anything new by name.
    private static func rank(_ key: String) -> (Int, String) {
        (["premium_interactions", "chat", "completions"].firstIndex(of: key) ?? 3, key)
    }

    static func title(_ key: String) -> String {
        switch key {
        case "premium_interactions": return "Premium requests"
        case "chat": return "Chat messages"
        case "completions": return "Code completions"
        default: return TextTools.capitalized(key.replacingOccurrences(of: "_", with: " "))
        }
    }

    static func unit(_ key: String) -> String {
        switch key {
        case "premium_interactions": return "requests"
        case "chat": return "messages"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        let named = ["individual": "Individual", "individual_pro": "Pro+", "business": "Business", "enterprise": "Enterprise"]
        return named[plan] ?? TextTools.capitalized(plan.replacingOccurrences(of: "_", with: " "))
    }

    private static let counting: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func number(_ value: Double) -> String {
        counting.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    // MARK: - The GitHub CLI's sign-in

    /// Wherever the GitHub CLI keeps its sign-in: GH_TOKEN or GITHUB_TOKEN,
    /// `gh auth token`, gh's Keychain item, then gh's hosts.yml.
    static func token() -> String? {
        let places: [() -> String?] = [environmentToken, ghToken, keychainToken, hostsFileToken]
        return places.lazy.compactMap { $0() }.first
    }

    private static func environmentToken() -> String? {
        ["GH_TOKEN", "GITHUB_TOKEN"].lazy.compactMap { clean(ProcessInfo.processInfo.environment[$0]) }.first
    }

    private static func ghToken() -> String? {
        guard let gh = Executables.find("gh"),
              let result = ProcessRunner.run(gh, ["auth", "token", "--hostname", "github.com"], directory: Environment.workDirectory, timeout: 10),
              result.status == 0
        else { return nil }
        return clean(result.text)
    }

    /// gh's Keychain item, which go-keyring may have stored base64-encoded.
    private static func keychainToken() -> String? {
        guard let result = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/security"), ["find-generic-password", "-s", "gh:github.com", "-w"], timeout: 10),
            result.status == 0, let value = clean(result.text)
        else { return nil }
        let prefix = "go-keyring-base64:"
        guard value.hasPrefix(prefix) else { return value }
        return Data(base64Encoded: String(value.dropFirst(prefix.count))).flatMap { clean(String(data: $0, encoding: .utf8)) }
    }

    /// `oauth_token` under `github.com:` in gh's hosts.yml.
    static func hostsFileToken() -> String? {
        let folder = Environment.value("GH_CONFIG_DIR").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Environment.value("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0).appendingPathComponent("gh") }
            ?? Environment.home.appendingPathComponent(".config/gh")
        guard let text = try? String(contentsOf: folder.appendingPathComponent("hosts.yml"), encoding: .utf8),
              text.utf8.count < 1 << 20
        else { return nil }
        var underGitHub = false
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            if line.first?.isWhitespace != true {
                // A host's name, flush left.
                underGitHub = content == "github.com:"
            } else if underGitHub, content.hasPrefix("oauth_token:") {
                return clean(String(content.dropFirst("oauth_token:".count)))
            }
        }
        return nil
    }

    /// A token as written, without spaces or quotes; nil if it can't be one.
    public static func clean(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")),
              !value.isEmpty, value.count < 32_768, !value.contains(where: \.isNewline)
        else { return nil }
        return value
    }
}

enum HTTP {
    struct Answer {
        let status: Int
        let data: Data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// A blocking GET, tried once more a second later after a dropped
    /// connection, a timeout or a server error.
    static func get(_ request: URLRequest) throws -> Answer {
        let host = request.url?.host ?? "the server"
        var outcome = fetch(request)
        if outcome.isPassing {
            Thread.sleep(forTimeInterval: 1)
            outcome = fetch(request)
        }
        if let error = outcome.error {
            throw ReadError("Couldn't reach \(host): \(error.localizedDescription)")
        }
        guard let status = outcome.status else {
            throw ReadError("No answer from \(host)")
        }
        return Answer(status: status, data: outcome.data ?? Data())
    }

    private final class Outcome: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?

        /// A failure that a second try may well not have.
        var isPassing: Bool {
            if let status { return status >= 500 }
            let passing: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
            return (error as? URLError).map { passing.contains($0.code) } ?? false
        }
    }

    private static func fetch(_ request: URLRequest) -> Outcome {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            outcome.data = data
            outcome.status = (response as? HTTPURLResponse)?.statusCode
            outcome.error = error
            done.signal()
        }.resume()
        done.wait()
        return outcome
    }
}
