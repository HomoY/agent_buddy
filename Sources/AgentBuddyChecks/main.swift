import Foundation
import AgentBuddyCore

// Self-checks for AgentBuddyCore (XCTest isn't available with the Command Line Tools).
//   swift run AgentBuddyChecks                 fixtures + a live FSEvents watcher test in a temp folder
//   swift run AgentBuddyChecks --live          read your real Claude, ChatGPT (Codex) and Copilot limits
//   swift run AgentBuddyChecks --replay FILE   run a real session log through its tracker, ignoring freshness
//   swift run AgentBuddyChecks --mock-ntfy     a mock ntfy server on 127.0.0.1, for AgentBuddy --selftest-phone
//   swift run AgentBuddyChecks --history FILE  the prompt tree of a session log, as the history window shows it
//   swift run AgentBuddyChecks --codex-resets  ask codex-reset.com once for everyone's Codex resets

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (line \(line)): \(what)")
    }
}

func json(_ text: String) -> JSON {
    guard let value = JSON.parse(text) else { fatalError("bad fixture: \(text)") }
    return value
}

let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func stamp(_ date: Date) -> String { isoFormatter.string(from: date) }

func finishedEvents(_ actions: [TrackerAction]) -> [JobEvent] {
    actions.compactMap { if case .finished(let event) = $0 { return event } else { return nil } }
}

func isCancel(_ actions: [TrackerAction]) -> Bool {
    actions.contains { if case .cancel = $0 { return true } else { return false } }
}

// MARK: - Fixtures

func checkDates() {
    print("Dates")
    let micro = Dates.parse("2026-10-25T14:19:59.567023+00:00")
    check(micro != nil, "microsecond timestamps parse")
    check(abs((micro?.timeIntervalSince1970 ?? 0) - 1_792_937_999.567023) < 0.001, "fraction is kept")
    check(Dates.parse("2026-10-21T08:40:49Z") != nil, "Z timestamps parse")
    check(Dates.parse("2026-11-01")?.timeIntervalSince1970 == 1_793_491_200, "a bare day is UTC midnight")
    check(Dates.parse("soon") == nil, "junk is nil")
    check(Dates.epoch(1_793_513_928)?.timeIntervalSince1970 == 1_793_513_928, "epoch seconds")
    check(Dates.epoch(1_793_513_928_000)?.timeIntervalSince1970 == 1_793_513_928, "epoch milliseconds")
}

func checkRoundTrip() {
    print("A server's round trip, for the agent windows' signal")
    check(RoundTrip.pingTime("1 packets transmitted, 1 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 431.208/431.208/431.208/0.000 ms") == 431,
          "macOS ping's summary: the round trip in milliseconds")
    check(RoundTrip.pingTime("rtt min/avg/max/mdev = 1.234/2.6/3.456/0.1 ms") == 3, "and Linux's")
    check(RoundTrip.pingTime("Request timeout for icmp_seq 0") == nil, "no reply: no time")
    let (name, port) = RoundTrip.address(fromSSHConfig: "user dev\nhostname 203.0.113.7\nport 2222\n", fallback: "gpu")
    check(name == "203.0.113.7" && port == 2222, "the server's address and port, as ssh resolves an alias")
    check(RoundTrip.ping("127.0.0.1").map { $0 < 50 } == true, "this Mac answers a ping at once")
    // A port listening here: reached; one that isn't: no time, soon.
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
    listen(listener, 1)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
    let open = UInt16(bigEndian: address.sin_port)
    check(RoundTrip.connectTime("127.0.0.1", open).map { $0 < 200 } == true, "a port that listens: the time to reach it")
    close(listener)
    let started = Date()
    check(RoundTrip.connectTime("127.0.0.1", open, timeout: 2) == nil && Date().timeIntervalSince(started) < 3, "a port that doesn't: no time, and soon")
}

func checkClaudeUsage() {
    print("Claude usage")
    let payload = json("""
    {"rate_limits_available": true, "subscription_type": "max",
     "rate_limits": {
       "five_hour": {"utilization": 18, "resets_at": "2026-10-25T14:19:59.567023+00:00"},
       "seven_day": {"utilization": 11, "resets_at": "2026-10-30T23:59:59.567044+00:00"},
       "seven_day_opus": null, "seven_day_sonnet": null,
       "limits": [
         {"kind": "session", "percent": 18, "resets_at": "2026-10-25T14:19:59.567023+00:00"},
         {"kind": "weekly_all", "percent": 11, "resets_at": "2026-10-30T23:59:59.567044+00:00"},
         {"kind": "weekly_scoped", "percent": 22, "resets_at": "2026-10-30T23:59:59.567211+00:00",
          "scope": {"model": {"id": null, "display_name": "Fable"}}}
       ]}}
    """)
    let profile = json(#"{"organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x", "emailAddress": "me@example.com"}"#)
    guard let reading = try? ClaudeUsage.parse(payload: payload, profile: profile) else {
        check(false, "Claude payload parses")
        return
    }
    check(reading.windows.map(\.id) == ["claude.session", "claude.weekly", "claude.weekly.fable"], "session, week, then Fable's week")
    check(reading.windows.first?.usedPercent == 18, "session percent")
    check(reading.windows.first?.kind == .session, "session kind")
    check(reading.windows.first?.resetsAt == Dates.parse("2026-10-25T14:19:59.567023+00:00"), "session reset")
    check(reading.windows[1].title == "Weekly · All models", "weekly title")
    check(reading.windows[2].title == "Weekly · Fable" && reading.windows[2].usedPercent == 22, "model week")
    check(reading.plan == "Max 20x", "plan from the profile")
    check(reading.account == "me@example.com", "account")
    check(reading.menuWindows.map(\.id) == ["claude.session", "claude.weekly", "claude.weekly.fable"], "menu bar shows the session, the week, and Fable's week")

    let noLimits = try? ClaudeUsage.parse(payload: json(#"{"rate_limits_available": false}"#), profile: JSON(nil))
    check(noLimits?.windows.isEmpty == true && noLimits?.notes.isEmpty == false, "no plan limits is a note, not an error")
    let failedLookup = try? ClaudeUsage.parse(payload: json(#"{"rate_limits_available": true, "rate_limits": null}"#), profile: JSON(nil))
    check(failedLookup == nil, "limits available without numbers is a failed read")
    let legacy = try? ClaudeUsage.parse(payload: json("""
    {"rate_limits_available": true, "rate_limits": {"five_hour": {"utilization": 3.5}, "seven_day_opus": {"utilization": 30}}}
    """), profile: JSON(nil))
    check(legacy?.windows.map(\.id) == ["claude.session", "claude.weekly.opus"], "older seven_day_<family> keys")
    let both = try? ClaudeUsage.parse(payload: json("""
    {"rate_limits_available": true, "rate_limits": {
       "five_hour": {"utilization": 10}, "seven_day_fable": {"utilization": 40},
       "limits": [{"kind": "session", "percent": 12},
                  {"kind": "weekly_scoped", "percent": 7, "scope": {"model": {"id": "claude-opus-5-5", "display_name": null}}}]}}
    """), profile: JSON(nil))
    check(both?.windows.first?.usedPercent == 12, "the newer list wins over the named fields")
    check(both?.windows.map(\.id) == ["claude.session", "claude.weekly.opus", "claude.weekly.fable"], "model weeks, largest family first")
    // Claude's newer answer: no 5-hour session, and a model's week listed but not in force.
    let weekly = try? ClaudeUsage.parse(payload: json("""
    {"rate_limits_available": true, "subscription_type": "max", "rate_limits": {
       "five_hour": null, "seven_day": {"utilization": 4, "resets_at": "2026-11-07T00:00:00.194008+00:00"},
       "limits": [
         {"kind": "weekly_all", "group": "weekly", "percent": 4, "resets_at": "2026-11-07T00:00:00.194008+00:00", "severity": "normal", "is_active": true, "scope": null},
         {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "resets_at": "2026-11-07T00:00:00+00:00", "severity": "normal", "is_active": false,
          "scope": {"model": {"display_name": "Fable", "id": null}, "surface": null}}],
       "weekly_scoped_shares": [{"limit_index": 1, "used_percent_of_weekly": 0, "allowance_percent_of_weekly": 50}],
       "model_scoped": [{"display_name": "Fable", "utilization": 0, "resets_at": "2026-11-07T00:00:00+00:00"}],
       "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "percent": 0, "enabled": false}}}
    """), profile: json(#"{"organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x", "planDisplayName": "Ultra"}"#))
    check(weekly?.windows.map(\.id) == ["claude.weekly", "claude.weekly.fable"] && weekly?.windows.last?.detail == "Up to 50% of your week",
          "no 5-hour session: the week, and Fable's share of it")
    check(weekly?.plan == "Ultra", "the plan as Claude names it")
    check(weekly?.notes.isEmpty == true, "usage credits off and unused: nothing said")
    let credits = ClaudeUsage.creditsNote(json(#"{"used": {"amount_minor": 1250, "currency": "USD", "exponent": 2}, "enabled": true}"#)) ?? ""
    check(credits.hasPrefix("Usage credits on: ") && credits.contains("12.50") && credits.hasSuffix("used, past your plan's limits"),
          "usage credits on: what they've covered, in this Mac's money format: \(credits)")
    if let weekly {
        check(weekly.menuValues(at: Date()).map { "\($0.tag ?? "") \($0.text)" } == ["wk 4%", "Fable 0%"], "the bar: the week, then Fable's")
    }
    check(ClaudeUsage.planName(profile: json(#"{"organizationType": "claude_max", "userRateLimitTier": "default_claude_max_5x"}"#), subscription: nil) == "Max 5x"
          && ClaudeUsage.planName(profile: JSON(nil), subscription: "pro") == "Pro", "plan from the tier, else the subscription")
}

func checkCodexUsage() {
    print("Codex usage")
    let limits = json("""
    {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 99, "windowDurationMins": 300}},
     "rateLimitsByLimitId": {"codex": {"limitId": "codex", "limitName": null,
        "primary": {"usedPercent": 21, "windowDurationMins": 10080, "resetsAt": 1793513928},
        "secondary": null, "planType": "prolite"}},
     "rateLimitResetCredits": {"availableCount": 2, "credits": []},
     "accountId": "a9cd4833"}
    """)
    let reading = CodexUsage.parse(limits: limits, account: json(#"{"email": "me@example.com", "planType": "prolite", "type": "chatgpt"}"#))
    check(reading.windows.count == 1, "the bucket map wins over the legacy bucket")
    check(reading.windows.first?.id == "codex.codex.primary", "window id")
    check(reading.windows.first?.title == "Weekly limit", "a 10080-minute window is weekly")
    check(reading.windows.first?.kind == .weekly, "weekly kind")
    check(reading.windows.first?.usedPercent == 21, "percent")
    check(reading.windows.first?.resetsAt?.timeIntervalSince1970 == 1_793_513_928, "reset")
    check(reading.plan == "Pro Lite", "plan name")
    check(reading.notes.contains { $0.contains("2 free limit resets") }, "free resets note")

    let two = CodexUsage.parse(limits: json("""
    {"rateLimitsByLimitId": {
       "gpt-spark": {"limitName": "Spark", "primary": {"usedPercent": 5, "windowDurationMins": 300}},
       "codex": {"primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1793000000},
                 "secondary": {"usedPercent": 23, "windowDurationMins": 10080, "resetsAt": 1793500000}, "planType": "plus"}}}
    """), account: JSON(nil))
    check(two.windows.map(\.title) == ["5-hour limit", "Weekly limit", "Spark · 5-hour"], "codex bucket first, others named")
    check(two.windows.first?.kind == .session, "a 300-minute window is a session")
    check(two.menuWindows.count == 2, "menu bar shows codex's two windows")
    check(two.plan == "Plus", "plus plan")

    let live = CodexUsage.reading(fromTokenCount: json("""
    {"limit_id": "codex", "limit_name": null, "primary": {"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1793156160},
     "secondary": null, "plan_type": "prolite"}
    """), at: Date(timeIntervalSince1970: 1_792_500_000))
    check(live?.windows.first?.usedPercent == 52, "token_count snapshot percent")
    check(live?.windows.first?.id == "codex.codex.primary", "token_count snapshot id matches the app-server's")
    check(live?.fetchedAt.timeIntervalSince1970 == 1_792_500_000, "snapshot time")
    check(CodexUsage.reading(fromTokenCount: JSON(nil), at: Date()) == nil, "no snapshot")
    check(live?.plan == "Pro Lite", "the snapshot's plan, in snake_case")
    let unsized = CodexUsage.parse(limits: json("""
    {"rateLimits": {"primary": {"usedPercent": 3}, "secondary": {"usedPercent": 9}}}
    """), account: JSON(nil))
    check(unsized.windows.map(\.title) == ["Short-term limit", "Long-term limit"], "limits without a length: \(unsized.windows.map(\.title))")
    check(CodexUsage.periodName(minutes: 1440, secondary: false) == "Daily" && CodexUsage.periodName(minutes: 4320, secondary: false) == "3-day"
          && CodexUsage.periodName(minutes: 43200, secondary: true) == "Monthly" && CodexUsage.periodName(minutes: 90, secondary: false) == "2-hour",
          "period names")
}

func checkCopilotUsage() {
    print("Copilot usage")
    let body = json("""
    {"login": "octo", "copilot_plan": "individual", "access_type_sku": "free_faculty_quota",
     "quota_reset_date": "2026-11-01", "quota_reset_date_utc": "2026-11-01T00:00:00.000Z", "token_based_billing": true,
     "quota_snapshots": {
       "chat": {"percent_remaining": 100.0, "unlimited": true, "remaining": 0, "entitlement": 0},
       "completions": {"percent_remaining": 100.0, "unlimited": true, "remaining": 0, "entitlement": 0},
       "premium_interactions": {"percent_remaining": 73.0, "quota_remaining": 1096.1, "unlimited": false,
                                "remaining": 1096, "entitlement": 1500, "quota_reset_at": 0}}}
    """)
    let reading = CopilotUsage.parse(body)
    check(reading.windows.count == 1, "unlimited quotas are skipped")
    check(reading.windows.first?.title == "Premium requests", "premium title")
    check(reading.windows.first?.usedPercent == 27, "27% used")
    check(reading.windows.first?.detail == "404 / 1,500 requests", "requests used")
    check(reading.windows.first?.resetsAt == Dates.parse("2026-11-01T00:00:00Z"), "monthly reset")
    check(reading.plan == "Individual" && reading.account == "octo", "plan and login")

    let free = CopilotUsage.parse(json("""
    {"access_type_sku": "free_limited_copilot", "limited_user_quotas": {"chat": 40, "completions": 1000},
     "monthly_quotas": {"chat": 50, "completions": 2000}, "limited_user_reset_date": "2026-11-01"}
    """))
    check(free.windows.first(where: { $0.id == "copilot.chat" })?.usedPercent == 20, "free plan chat quota")
    check(free.windows.map(\.id) == ["copilot.chat", "copilot.completions"] && free.windows.first?.detail == "10 / 50 messages",
          "free plan quotas in order, with their units")
    let older = CopilotUsage.parse(json("""
    {"quota_snapshots": {"premium_models": {"entitlement": 300, "remaining": 150},
                         "chat": {"unlimited": true}, "brand_new": {"percent_remaining": 90}}}
    """))
    check(older.windows.map(\.id) == ["copilot.premium_interactions", "copilot.brand_new"]
          && older.windows.first?.usedPercent == 50, "premium_models is premium requests; new quotas follow by name")
    check(CopilotUsage.clean(" 'gho_abc' \n") == "gho_abc" && CopilotUsage.clean("a\nb") == nil && CopilotUsage.clean("  ") == nil, "token cleaning")
}

func checkMenuValues() {
    print("Menu bar values")
    let now = Date()
    let session = UsageWindow(id: "claude.session", kind: .session, title: "Current session", usedPercent: 25, resetsAt: now.addingTimeInterval(3600))
    let week = UsageWindow(id: "claude.weekly", kind: .weekly, title: "Weekly · All models", usedPercent: 13, resetsAt: now.addingTimeInterval(86400))
    let fable = UsageWindow(id: "claude.weekly.fable", kind: .weeklyModel, title: "Weekly · Fable", usedPercent: 24)
    // Handed over in the wrong order on purpose.
    let claude = AgentReading(agent: .claude, windows: [fable, week, session])
    check(claude.menuValues(at: now) == [
        MenuValue(tag: "5h", text: "25%", severity: .normal),
        MenuValue(tag: "wk", text: "13%", severity: .normal),
        MenuValue(tag: "Fable", text: "24%", severity: .normal),
    ], "Claude shows the session, the week, then each model's week")
    check(AgentReading(agent: .claude, windows: [week]).menuValues(at: now) == [MenuValue(tag: "wk", text: "13%", severity: .normal)],
          "a plan without a 5-hour session: its week alone")
    check(AgentReading(agent: .claude, windows: [session]).menuValues(at: now).map(\.text) == ["25%", "–"],
          "a missing week keeps its place")
    check(AgentReading(agent: .claude, notes: ["No plan limits"]).menuValues(at: now) == [MenuValue(tag: nil, text: "–", severity: nil)],
          "a login without limits is one dash")
    let lapsed = UsageWindow(id: "claude.session", kind: .session, title: "Current session", usedPercent: 80, resetsAt: now.addingTimeInterval(-5))
    check(AgentReading(agent: .claude, windows: [week, lapsed]).menuValues(at: now).first?.text == "0%",
          "a session past its reset shows 0% until the next read")
    let codexWeek = UsageWindow(id: "codex.codex.primary", kind: .weekly, title: "Weekly limit", usedPercent: 24)
    check(AgentReading(agent: .codex, windows: [codexWeek]).menuValues(at: now) == [MenuValue(tag: nil, text: "24%", severity: .normal)],
          "a single window needs no tag")
    let codexTwo = AgentReading(agent: .codex, windows: [
        UsageWindow(id: "codex.codex.primary", kind: .session, title: "5-hour limit", usedPercent: 91),
        UsageWindow(id: "codex.codex.secondary", kind: .weekly, title: "Weekly limit", usedPercent: 40),
    ])
    check(codexTwo.menuValues(at: now).map { $0.tag ?? "" } == ["5h", "wk"], "two Codex windows are tagged")
    check(codexTwo.menuValues(at: now).first?.severity == .critical, "colour follows the percent")
}

func checkFolding() {
    print("Folding by agent window")
    let now = Date()
    func job(_ id: String, _ agent: Agent, _ session: String, _ minutesAgo: Double, source: String? = nil) -> JobEvent {
        JobEvent(id: id, agent: agent, outcome: .completed, sessionID: session, title: "t-\(id)",
                 finishedAt: now.addingTimeInterval(-minutesAgo * 60), source: source)
    }
    let jobs = [
        job("a1", .claude, "s1", 30), job("b1", .codex, "s2", 20), job("a2", .claude, "s1", 10),
        job("a3", .claude, "s1", 1), job("r1", .claude, "s1", 5, source: "server"),
    ]
    let windows = JobWindow.fold(jobs)
    check(windows.count == 3, "three agent windows: two on this Mac, one on the server (got \(windows.count))")
    check(windows.first?.count == 3 && windows.first?.latest.id == "a3", "the window with the newest job comes first, its jobs newest first")
    check(windows.first?.jobs.map(\.id) == ["a3", "a2", "a1"], "a window keeps all its jobs")
    check(windows[1].latest.id == "r1" && windows[1].count == 1, "the same session id on a server is another window")
    check(windows[2].latest.id == "b1", "another agent's session is another window")
    check(JobWindow.key(jobs[0]) == JobWindow.key(jobs[2]) && JobWindow.key(jobs[0]) != JobWindow.key(jobs[4]), "a window is its agent, server and session")
    check(JobWindow.fold([]).isEmpty, "no jobs, no windows")
}

func checkWindowMath() {
    print("Windows")
    let now = Date()
    let past = UsageWindow(id: "a", kind: .session, title: "s", usedPercent: 80, resetsAt: now.addingTimeInterval(-1))
    let future = UsageWindow(id: "b", kind: .session, title: "s", usedPercent: 80, resetsAt: now.addingTimeInterval(60))
    check(past.percent(at: now) == 0 && past.hasReset(at: now), "a window past its reset reads 0%")
    check(future.percent(at: now) == 80, "a running window keeps its percent")
    check(Severity(percent: 69.9) == .normal && Severity(percent: 70) == .warning && Severity(percent: 90) == .critical, "severity bands")
}

// MARK: - Trackers

func checkClaudeTracker() {
    print("Claude tracker")
    let tracker = ClaudeTracker(path: "/tmp/projects/-demo/11111111-2222-3333-4444-555555555555.jsonl")
    let t0 = Date()
    func at(_ seconds: Double) -> String { stamp(t0.addingTimeInterval(seconds)) }
    var all: [TrackerAction] = []
    func feed(_ text: String) -> [TrackerAction] {
        let actions = tracker.consume(json(text))
        all += actions
        return actions
    }
    _ = feed(#"{"type":"user","cwd":"/Users/me/demo","isSidechain":false,"timestamp":"\#(at(0))","message":{"role":"user","content":"Build the menu bar app please"}}"#)
    _ = feed(#"{"type":"user","isMeta":true,"timestamp":"\#(at(0))","message":{"role":"user","content":"<system note>"}}"#)
    _ = feed(#"{"type":"assistant","timestamp":"\#(at(2))","message":{"id":"msg_a","role":"assistant","model":"claude-opus-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#)
    _ = feed(#"{"type":"user","timestamp":"\#(at(3))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#)
    _ = feed(#"{"type":"assistant","isSidechain":true,"timestamp":"\#(at(3.5))","message":{"id":"msg_side","role":"assistant","model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"sub-agent answer"}]}}"#)
    check(finishedEvents(all).isEmpty, "tool use, tool results and sidechains don't finish a turn")
    let thinking = feed(#"{"type":"assistant","timestamp":"\#(at(5))","message":{"id":"msg_b","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"..."}]}}"#)
    let text = feed(#"{"type":"assistant","timestamp":"\#(at(5))","message":{"id":"msg_b","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"**Done.** The app builds and runs."}]}}"#)
    let hook = feed(#"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(at(5.1))"}"#)
    let first = finishedEvents(thinking).first
    let refreshed = finishedEvents(text).first
    check(first != nil, "end_turn finishes the turn")
    check(refreshed?.id == first?.id, "a later line of the same answer refreshes the same reminder")
    check(refreshed?.summary == "Done. The app builds and runs.", "the summary is the answer's words")
    check(refreshed?.title == "Build the menu bar app please", "the first prompt names a session without a title")
    check(refreshed?.project == "demo", "project is the working folder's name")
    check(refreshed.flatMap(\.duration).map { abs($0 - 5) < 0.01 } == true, "duration runs from the prompt")
    check(finishedEvents(hook).isEmpty, "the stop-hook summary after end_turn doesn't remind twice")

    _ = feed(#"{"type":"ai-title","aiTitle":"Agent usage menu bar app","sessionId":"x"}"#)
    _ = feed(#"{"type":"user","timestamp":"\#(at(10))","message":{"role":"user","content":"<command-name>/usage</command-name>"}}"#)
    _ = feed(#"{"type":"user","timestamp":"\#(at(20))","message":{"role":"user","content":[{"type":"text","text":"Now add tests"}]}}"#)
    let summaryEnd = feed(#"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(at(30))"}"#)
    check(finishedEvents(summaryEnd).first?.title == "Agent usage menu bar app", "a stop-hook summary finishes a running turn; the AI title names it")

    _ = feed(#"{"type":"user","timestamp":"\#(at(40))","message":{"role":"user","content":"Try again"}}"#)
    let interrupted = feed(#"{"type":"user","timestamp":"\#(at(41))","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)
    check(isCancel(interrupted), "an interruption cancels")
    let lateHook = feed(#"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(at(41.5))"}"#)
    check(finishedEvents(lateHook).isEmpty, "nothing finishes after an interruption")

    _ = feed(#"{"type":"user","timestamp":"\#(at(50))","message":{"role":"user","content":"One more"}}"#)
    let limited = feed(#"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\#(at(51))","message":{"id":"e1","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 4pm"}]}}"#)
    check(finishedEvents(limited).first?.outcome == .limited, "a rate-limit error is a limited outcome")
    let synthetic = feed(#"{"type":"assistant","timestamp":"\#(at(52))","message":{"id":"s1","role":"assistant","model":"<synthetic>","stop_reason":"end_turn","content":[{"type":"text","text":"No response requested."}]}}"#)
    check(finishedEvents(synthetic).isEmpty, "synthetic messages are ignored")
}

func checkCodexTracker() {
    print("Codex tracker")
    let thread = "01a15d97-5126-73d3-971c-2fa5886ddde6"
    let tracker = CodexTracker(path: "/tmp/sessions/2026/10/25/rollout-2026-10-25T10-00-00-\(thread).jsonl", sessionIndex: nil)
    let t0 = Date()
    func at(_ seconds: Double) -> String { stamp(t0.addingTimeInterval(seconds)) }
    _ = tracker.consume(json(#"{"timestamp":"\#(at(0))","type":"session_meta","payload":{"id":"\#(thread)","cwd":"/Users/me/site","source":"vscode","originator":"Codex Desktop"}}"#))
    _ = tracker.consume(json(#"{"timestamp":"\#(at(1))","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#))
    _ = tracker.consume(json(#"{"timestamp":"\#(at(1))","type":"event_msg","payload":{"type":"user_message","message":"Fix the login page"}}"#))
    let usage = tracker.consume(json(#"{"timestamp":"\#(at(5))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":30,"window_minutes":10080,"resets_at":1793513928},"secondary":null,"plan_type":"plus"}}}"#))
    let snapshot = usage.compactMap { if case .usage(let reading) = $0 { return reading } else { return nil } }.first
    check(snapshot?.windows.first?.usedPercent == 30, "token_count becomes a live usage update")
    let done = tracker.consume(json(#"{"timestamp":"\#(at(9))","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":8000,"last_agent_message":"Fixed the **login** page."}}"#))
    let event = finishedEvents(done).first
    check(event?.outcome == .completed, "task_complete finishes the turn")
    check(event?.summary == "Fixed the login page.", "the last agent message is the summary")
    check(event?.title == "Fix the login page", "the first prompt names the thread")
    check(event?.project == "site", "project")
    check(event.flatMap(\.duration).map { abs($0 - 8) < 0.01 } == true, "duration from duration_ms")
    check(event?.id == "codex:\(thread):turn-1", "event id")
    let again = tracker.consume(json(#"{"timestamp":"\#(at(9))","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#))
    check(finishedEvents(again).isEmpty, "the same turn reminds once")
    _ = tracker.consume(json(#"{"timestamp":"\#(at(20))","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#))
    check(isCancel(tracker.consume(json(#"{"timestamp":"\#(at(21))","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2","reason":"interrupted"}}"#))), "turn_aborted cancels")
    _ = tracker.consume(json(#"{"timestamp":"\#(at(30))","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-3"}}"#))
    let failure = tracker.consume(json(#"{"timestamp":"\#(at(31))","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-3","error":{"message":"boom"}}}"#))
    check(finishedEvents(failure).first?.outcome == .failed, "an error is a failed outcome")

    let sub = CodexTracker(path: "/tmp/sessions/rollout-x-\(UUID().uuidString.lowercased()).jsonl", sessionIndex: nil)
    _ = sub.consume(json(#"{"timestamp":"\#(at(0))","type":"session_meta","payload":{"id":"\#(UUID().uuidString.lowercased())","source":{"subagent":{"thread_spawn":{"agent_path":"/reviewer"}}}}}"#))
    _ = sub.consume(json(#"{"timestamp":"\#(at(1))","type":"event_msg","payload":{"type":"task_started","turn_id":"s1"}}"#))
    check(finishedEvents(sub.consume(json(#"{"timestamp":"\#(at(2))","type":"event_msg","payload":{"type":"task_complete","turn_id":"s1"}}"#))).isEmpty,
          "a spawned sub-agent's thread doesn't remind")
}

func checkCopilotTracker() {
    print("Copilot tracker")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hs-copilot-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? "id: abc\ncwd: /Users/me/visa\nname: 'Open the visa scheduling page in Chrome'\nuser_named: false\n"
        .write(to: folder.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tracker = CopilotTracker(path: folder.appendingPathComponent("events.jsonl").path)
    let t0 = Date()
    func at(_ seconds: Double) -> String { stamp(t0.addingTimeInterval(seconds)) }
    func feed(_ text: String) -> [TrackerAction] { tracker.consume(json(text)) }
    _ = feed(#"{"type":"user.message","id":"u1","timestamp":"\#(at(0))","data":{"content":"open chrome"}}"#)
    _ = feed(#"{"type":"assistant.message","timestamp":"\#(at(2))","data":{"content":"","toolRequests":[{"name":"bash"}]}}"#)
    check(finishedEvents(feed(#"{"type":"assistant.turn_end","timestamp":"\#(at(3))","data":{"turnId":"1"}}"#)).isEmpty,
          "a turn that asked for tools isn't the end")
    _ = feed(#"{"type":"assistant.turn_start","timestamp":"\#(at(3))","data":{"turnId":"2"}}"#)
    _ = feed(#"{"type":"assistant.message","timestamp":"\#(at(6))","data":{"content":"Chrome is open on the page.","toolRequests":[]}}"#)
    let end = finishedEvents(feed(#"{"type":"assistant.turn_end","timestamp":"\#(at(6))","data":{"turnId":"2"}}"#)).first
    check(end?.outcome == .completed, "the turn_end after a tool-free answer finishes the request")
    check(end?.title == "Open the visa scheduling page in Chrome", "workspace.yaml names the session")
    check(end?.project == "visa", "workspace.yaml gives the folder")
    check(end?.summary == "Chrome is open on the page.", "summary")
    check(finishedEvents(feed(#"{"type":"hook.start","timestamp":"\#(at(6))","data":{"hookType":"agentStop","input":{"stopReason":"end_turn"}}}"#)).isEmpty,
          "the agentStop record after it doesn't remind twice")

    _ = feed(#"{"type":"user.message","id":"u2","timestamp":"\#(at(10))","data":{"content":"and log in"}}"#)
    let stop = finishedEvents(feed(#"{"type":"hook.start","timestamp":"\#(at(12))","data":{"hookType":"agentStop","input":{"stopReason":"end_turn"}}}"#)).first
    check(stop?.id.hasSuffix(":u2") == true, "agentStop end_turn finishes a request")
    _ = feed(#"{"type":"system.notification","timestamp":"\#(at(13))","data":{"kind":{"type":"shell_completed"}}}"#)
    let resumed = feed(#"{"type":"assistant.message","timestamp":"\#(at(13.2))","data":{"content":"","toolRequests":[{"name":"bash"}]}}"#)
    check(resumed.contains { if case .activity = $0 { return true } else { return false } },
          "work after a stop resumes (and withdraws a pending reminder)")
    _ = feed(#"{"type":"assistant.message","timestamp":"\#(at(15))","data":{"content":"The shell finished; all good.","toolRequests":[]}}"#)
    let again = finishedEvents(feed(#"{"type":"hook.start","timestamp":"\#(at(15))","data":{"hookType":"agentStop","input":{"stopReason":"end_turn"}}}"#)).first
    check(again?.id.contains(":resume-") == true && again?.summary == "The shell finished; all good.", "a resumed job reminds when it stops again")
    check(finishedEvents(feed(#"{"type":"hook.start","timestamp":"\#(at(15))","data":{"hookType":"sessionEnd","input":{}}}"#)).isEmpty,
          "sessionEnd doesn't resume or remind")

    _ = feed(#"{"type":"user.message","id":"u3","timestamp":"\#(at(20))","data":{"content":"stop"}}"#)
    check(isCancel(feed(#"{"type":"abort","timestamp":"\#(at(21))","data":{"reason":"user"}}"#)), "abort cancels")
    check(finishedEvents(feed(#"{"type":"assistant.turn_end","timestamp":"\#(at(21))","data":{}}"#)).isEmpty, "nothing after an abort")
}

// MARK: - Watcher (real FSEvents in a temp folder)

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [JobEvent] = []
    private var readings: [AgentReading] = []

    func add(_ job: JobEvent) { lock.lock(); jobs.append(job); lock.unlock() }
    func add(_ reading: AgentReading) { lock.lock(); readings.append(reading); lock.unlock() }
    var allJobs: [JobEvent] { lock.lock(); defer { lock.unlock() }; return jobs }
    var allReadings: [AgentReading] { lock.lock(); defer { lock.unlock() }; return readings }
}

func append(_ lines: [String], to url: URL) {
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

func waitFor(_ seconds: Double, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && !done() {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func checkWatcher() {
    print("Watcher (FSEvents)")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let claudeDir = root.appendingPathComponent("claude/projects/-Users-me-demo")
    let codexDir = root.appendingPathComponent("codex/sessions/2026/10/25")
    let copilotDir = root.appendingPathComponent("copilot/session-state/9f1c")
    for folder in [claudeDir, codexDir, copilotDir] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let thread = UUID().uuidString.lowercased()
    let claudeFile = claudeDir.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
    let codexFile = codexDir.appendingPathComponent("rollout-2026-10-25T10-00-00-\(thread).jsonl")
    let copilotFile = copilotDir.appendingPathComponent("events.jsonl")
    try? "cwd: /Users/me/visa\nname: Visa helper\n".write(to: copilotDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    try? #"{"id":"\#(thread)","thread_name":"Fix login"}"#.appending("\n").write(to: root.appendingPathComponent("codex/session_index.jsonl"), atomically: true, encoding: .utf8)

    // History written an hour ago, with a finished turn: it must not remind.
    let old = Date().addingTimeInterval(-3600)
    append([
        #"{"type":"user","cwd":"/Users/me/demo","timestamp":"\#(stamp(old))","message":{"role":"user","content":"old prompt"}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(old.addingTimeInterval(5)))","message":{"id":"old","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"old answer"}]}}"#,
    ], to: claudeFile)
    append([#"{"timestamp":"\#(stamp(old))","type":"session_meta","payload":{"id":"\#(thread)","cwd":"/Users/me/site","source":"cli"}}"#], to: codexFile)
    append([#"{"type":"session.start","timestamp":"\#(stamp(old))","data":{"context":{"cwd":"/Users/me/visa"}}}"#], to: copilotFile)

    let watcher = TranscriptWatcher(roots: .init(
        claudeProjects: root.appendingPathComponent("claude/projects"),
        codexSessions: root.appendingPathComponent("codex/sessions"),
        codexIndex: root.appendingPathComponent("codex/session_index.jsonl"),
        copilotSessions: root.appendingPathComponent("copilot/session-state")))
    watcher.debounce = [.claude: 1, .codex: 0.5, .copilot: 0.5]
    let collector = Collector()
    watcher.onJob = { collector.add($0) }
    watcher.onUsage = { collector.add($0) }
    watcher.start()
    Thread.sleep(forTimeInterval: 1.0)

    // A new Claude turn, then an answer that is quickly followed by more work (a stop hook resumed it).
    var now = Date()
    append([
        #"{"type":"user","cwd":"/Users/me/demo","timestamp":"\#(stamp(now))","message":{"role":"user","content":"new prompt"}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(now.addingTimeInterval(0.2)))","message":{"id":"m1","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"first try"}]}}"#,
    ], to: claudeFile)
    Thread.sleep(forTimeInterval: 0.4)
    now = Date()
    append([#"{"type":"assistant","timestamp":"\#(stamp(now))","message":{"id":"m2","role":"assistant","model":"m","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash"}]}}"#], to: claudeFile)
    Thread.sleep(forTimeInterval: 0.3)
    now = Date()
    append([#"{"type":"assistant","timestamp":"\#(stamp(now))","message":{"id":"m3","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"All tests pass."}]}}"#], to: claudeFile)

    now = Date()
    append([
        #"{"timestamp":"\#(stamp(now))","type":"event_msg","payload":{"type":"task_started","turn_id":"tw"}}"#,
        #"{"timestamp":"\#(stamp(now))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42,"window_minutes":10080,"resets_at":1893513928}}}}"#,
        #"{"timestamp":"\#(stamp(now.addingTimeInterval(0.1)))","type":"event_msg","payload":{"type":"task_complete","turn_id":"tw","last_agent_message":"Login fixed."}}"#,
    ], to: codexFile)
    append([
        #"{"type":"user.message","id":"w1","timestamp":"\#(stamp(now))","data":{"content":"open it"}}"#,
        #"{"type":"assistant.message","timestamp":"\#(stamp(now))","data":{"content":"Opened.","toolRequests":[]}}"#,
        #"{"type":"assistant.turn_end","timestamp":"\#(stamp(now))","data":{}}"#,
        #"{"type":"hook.start","timestamp":"\#(stamp(now))","data":{"hookType":"agentStop","input":{"stopReason":"end_turn"}}}"#,
    ], to: copilotFile)

    waitFor(8) { collector.allJobs.count >= 3 }
    Thread.sleep(forTimeInterval: 1.5)
    watcher.stop()
    let jobs = collector.allJobs
    let claude = jobs.filter { $0.agent == .claude }
    check(claude.count == 1, "one Claude reminder (got \(claude.count))")
    check(claude.first?.summary == "All tests pass.", "the resumed turn's final answer reminds, not the first try")
    check(!jobs.contains { $0.summary == "old answer" }, "history doesn't remind")
    let codex = jobs.filter { $0.agent == .codex }
    check(codex.count == 1 && codex.first?.title == "Fix login", "one Codex reminder named from session_index.jsonl")
    check(codex.first?.project == "site", "Codex project from the primed session_meta")
    let copilot = jobs.filter { $0.agent == .copilot }
    check(copilot.count == 1 && copilot.first?.title == "Visa helper", "one Copilot reminder named from workspace.yaml")
    check(collector.allReadings.first?.windows.first?.usedPercent == 42, "Codex live usage arrives")
}

/// A job that finished while Agent Buddy wasn't running (or just before it
/// started): told apart as missed, so it's listed if it wasn't seen already;
/// older ones stay history.
func checkMissedJobs() {
    print("Jobs finished while Agent Buddy wasn't watching")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-missed-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = "01a18184-b6ad-75e3-a840-\(String(UUID().uuidString.suffix(12)).lowercased())"
    // A conversation from days ago, resumed today: its log stays in its first day's folder.
    let day = root.appendingPathComponent("codex/sessions/2026/10/28")
    for folder in [day, root.appendingPathComponent("claude/projects"), root.appendingPathComponent("copilot/session-state")] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = day.appendingPathComponent("rollout-2026-10-28T15-58-40-\(thread).jsonl")
    let now = Date()
    let long = now.addingTimeInterval(-1200)
    let recent = now.addingTimeInterval(-60)
    try? [
        #"{"timestamp":"\#(stamp(long))","type":"session_meta","payload":{"id":"\#(thread)","cwd":"/Users/me/proof","source":"vscode"}}"#,
        #"{"timestamp":"\#(stamp(long))","type":"event_msg","payload":{"type":"task_started","turn_id":"long"}}"#,
        #"{"timestamp":"\#(stamp(long.addingTimeInterval(4)))","type":"event_msg","payload":{"type":"task_complete","turn_id":"long","last_agent_message":"Earlier."}}"#,
        #"{"timestamp":"\#(stamp(recent))","type":"event_msg","payload":{"type":"task_started","turn_id":"hi"}}"#,
        #"{"timestamp":"\#(stamp(recent.addingTimeInterval(7)))","type":"event_msg","payload":{"type":"task_complete","turn_id":"hi","last_agent_message":"Hi! How can I help?"}}"#,
    ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(roots: .init(
        claudeProjects: root.appendingPathComponent("claude/projects"),
        codexSessions: root.appendingPathComponent("codex/sessions"),
        codexIndex: nil,
        copilotSessions: root.appendingPathComponent("copilot/session-state")))
    watcher.debounce = [.claude: 0.5, .codex: 0.5, .copilot: 0.5]
    let fresh = Collector()
    let missed = Collector()
    watcher.onJob = { fresh.add($0) }
    watcher.onMissed = { missed.add($0) }
    watcher.start()
    waitFor(5) { !missed.allJobs.isEmpty }
    Thread.sleep(forTimeInterval: 1)
    watcher.stop()
    check(missed.allJobs.map(\.id) == ["codex:\(thread):hi"] && fresh.allJobs.isEmpty,
          "a turn that ended a minute before watching began: missed, not lost (\(missed.allJobs.map(\.id)))")
    check(!missed.allJobs.contains { $0.id.hasSuffix(":long") }, "one twenty minutes old: history")
    var archive = SessionArchive()
    if let job = missed.allJobs.first {
        check(!archive.contains(job), "not on record: listed")
        archive.record(job)
        check(archive.contains(job), "on record (seen before a restart, say): not listed again")
    }
}

/// A long session that existed before the watcher started, as a Claude Code
/// session you're working in does: reading starts in its last 512 KB.
func checkWatcherOnLongSession() {
    print("Watcher on a long, existing session")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-long-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("claude/projects/-Users-me-long")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("codex/sessions"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("copilot/session-state"), withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")

    // About 1.5 MB of history from an hour ago, ending with a finished turn.
    let old = Date().addingTimeInterval(-3600)
    let filler = String(repeating: "x", count: 6000)
    var history: [String] = []
    for turn in 0..<60 {
        let at = old.addingTimeInterval(Double(turn) * 20)
        history.append(#"{"type":"user","cwd":"/Users/me/long","timestamp":"\#(stamp(at))","message":{"role":"user","content":"old prompt \#(turn)"}}"#)
        history.append(#"{"type":"assistant","timestamp":"\#(stamp(at.addingTimeInterval(1)))","message":{"id":"old_tool_\#(turn)","role":"assistant","model":"m","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t\#(turn)","name":"Read"}]}}"#)
        history.append(#"{"type":"user","timestamp":"\#(stamp(at.addingTimeInterval(2)))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(turn)","content":"\#(filler)"}]}}"#)
        history.append(#"{"type":"assistant","timestamp":"\#(stamp(at.addingTimeInterval(3)))","message":{"id":"old_end_\#(turn)","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"old answer \#(turn)"}]}}"#)
        history.append(#"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(stamp(at.addingTimeInterval(3.1)))"}"#)
        history.append(#"{"type":"ai-title","aiTitle":"Long session","sessionId":"x"}"#)
    }
    append(history, to: file)

    let watcher = TranscriptWatcher(roots: .init(
        claudeProjects: root.appendingPathComponent("claude/projects"),
        codexSessions: root.appendingPathComponent("codex/sessions"),
        codexIndex: nil,
        copilotSessions: root.appendingPathComponent("copilot/session-state")))
    watcher.debounce = [.claude: 1, .codex: 0.5, .copilot: 0.5]
    let collector = Collector()
    watcher.onJob = { collector.add($0) }
    watcher.start()
    Thread.sleep(forTimeInterval: 1.0)

    // You type, the agent works, then answers in two lines (thinking, then text).
    var now = Date()
    append([#"{"type":"user","cwd":"/Users/me/long","timestamp":"\#(stamp(now))","message":{"role":"user","content":"new prompt"}}"#], to: file)
    Thread.sleep(forTimeInterval: 0.6)
    now = Date()
    append([
        #"{"type":"assistant","timestamp":"\#(stamp(now))","message":{"id":"new_tool","role":"assistant","model":"m","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tn","name":"Bash"}]}}"#,
        #"{"type":"user","timestamp":"\#(stamp(now.addingTimeInterval(0.2)))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tn","content":"ok"}]}}"#,
    ], to: file)
    Thread.sleep(forTimeInterval: 0.6)
    now = Date()
    append([#"{"type":"assistant","timestamp":"\#(stamp(now))","message":{"id":"new_end","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"..."}]}}"#], to: file)
    Thread.sleep(forTimeInterval: 0.4)
    append([
        #"{"type":"assistant","timestamp":"\#(stamp(Date()))","message":{"id":"new_end","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"New answer."}]}}"#,
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(stamp(Date()))"}"#,
    ], to: file)

    waitFor(6) { !collector.allJobs.isEmpty }
    Thread.sleep(forTimeInterval: 1.5)
    let jobs = collector.allJobs
    check(jobs.count == 1, "one reminder for the new turn (got \(jobs.count))")
    check(jobs.first?.summary == "New answer.", "it carries the answer's words")
    check(jobs.first?.title == "Long session", "the session's title comes from the history read for context")

    // A finished answer and your next prompt, written well after it, reach the
    // watcher in one read: the job still finished, so it still reminds.
    now = Date()
    append([
        #"{"type":"user","cwd":"/Users/me/long","timestamp":"\#(stamp(now))","message":{"role":"user","content":"second prompt"}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(now.addingTimeInterval(0.5)))","message":{"id":"late_end","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"Late answer."}]}}"#,
        #"{"type":"user","cwd":"/Users/me/long","timestamp":"\#(stamp(now.addingTimeInterval(40)))","message":{"role":"user","content":"third prompt"}}"#,
    ], to: file)
    waitFor(4) { collector.allJobs.count >= 2 }
    check(collector.allJobs.count == 2 && collector.allJobs.last?.summary == "Late answer.",
          "an answer followed much later by the next prompt still reminds (got \(collector.allJobs.count))")

    // What Claude Code writes when you typed your next message while it worked:
    // the answer, the stop-hook summary, then your queued prompt 38 ms later.
    // The answered job is finished, so it reminds at once.
    now = Date()
    append([#"{"type":"user","cwd":"/Users/me/long","timestamp":"\#(stamp(now))","message":{"role":"user","content":"fourth prompt"}}"#], to: file)
    Thread.sleep(forTimeInterval: 0.5)
    now = Date()
    append([
        #"{"type":"assistant","timestamp":"\#(stamp(now))","message":{"id":"queued_end","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"..."}]}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(now.addingTimeInterval(0.009)))","message":{"id":"queued_end","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"Answer before your queued message."}]}}"#,
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(stamp(now.addingTimeInterval(0.025)))"}"#,
        #"{"type":"queue-operation","operation":"dequeue","timestamp":"\#(stamp(now.addingTimeInterval(0.043)))"}"#,
        #"{"type":"user","origin":{"kind":"human"},"cwd":"/Users/me/long","timestamp":"\#(stamp(now.addingTimeInterval(0.047)))","message":{"role":"user","content":[{"type":"text","text":"queued prompt"}]}}"#,
        #"{"type":"attachment","timestamp":"\#(stamp(now.addingTimeInterval(0.047)))"}"#,
    ], to: file)
    waitFor(4) { collector.allJobs.count >= 3 }
    watcher.stop()
    check(collector.allJobs.count == 3 && collector.allJobs.last?.summary == "Answer before your queued message.",
          "a queued prompt starting right after an answer doesn't swallow its reminder (got \(collector.allJobs.count))")
}

// MARK: - Token statistics

func checkTokenLedger() {
    print("Token ledger")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-ledger-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("claude/projects/-Users-me-app")
    let codexDay = root.appendingPathComponent("codex/sessions/2026/10/25")
    let copilotSession = root.appendingPathComponent("copilot/session-state/s1")
    for folder in [project, codexDay, copilotSession] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let now = Date()
    let t = stamp(now.addingTimeInterval(-600))
    let usage1 = #""usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}"#
    // One message written as two lines (thinking, then text), a second message, and a synthetic one.
    let session = project.appendingPathComponent("a.jsonl")
    append([
        #"{"type":"assistant","timestamp":"\#(t)","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant",\#(usage1),"content":[{"type":"thinking"}]}}"#,
        #"{"type":"assistant","timestamp":"\#(t)","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant",\#(usage1),"content":[{"type":"text","text":"hi"}]}}"#,
        #"{"type":"assistant","timestamp":"\#(t)","requestId":"req_2","message":{"id":"msg_2","model":"claude-haiku-5-5","role":"assistant","usage":{"input_tokens":1,"output_tokens":2},"content":[]}}"#,
        #"{"type":"assistant","timestamp":"\#(t)","message":{"id":"syn","model":"<synthetic>","role":"assistant","usage":{"input_tokens":0,"output_tokens":0},"content":[]}}"#,
        #"{"type":"user","timestamp":"\#(t)","message":{"role":"user","content":"a prompt that mentions \"usage\""}}"#,
    ], to: session)
    // A fork copies msg_1: it must count once.
    append([#"{"type":"assistant","timestamp":"\#(t)","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant",\#(usage1),"content":[]}}"#],
           to: project.appendingPathComponent("b.jsonl"))
    // Codex: two responses with usage records, and token_count events repeating the same use.
    let rollout = codexDay.appendingPathComponent("rollout-2026-10-25T10-00-00-\(UUID().uuidString.lowercased()).jsonl")
    append([
        #"{"timestamp":"\#(t)","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
        #"{"timestamp":"\#(t)","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":1050}}}"#,
        #"{"timestamp":"\#(t)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#,
        #"{"timestamp":"\#(t)","type":"token_usage_record","payload":{"response_id":"resp_2","usage":{"input_tokens":2000,"cached_input_tokens":1900,"output_tokens":100,"total_tokens":2100}}}"#,
        #"{"timestamp":"\#(t)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2700,"output_tokens":150}}}}"#,
    ], to: rollout)
    // Copilot: input includes cache reads and writes; the last shutdown holds the totals.
    append([
        #"{"type":"session.shutdown","timestamp":"\#(t)","data":{"modelMetrics":{"claude-haiku-4.5":{"usage":{"inputTokens":500,"outputTokens":10,"cacheReadTokens":300,"cacheWriteTokens":100}}}}}"#,
        #"{"type":"session.shutdown","timestamp":"\#(t)","data":{"modelMetrics":{"claude-haiku-4.5":{"usage":{"inputTokens":900,"outputTokens":20,"cacheReadTokens":600,"cacheWriteTokens":200}}}}}"#,
    ], to: copilotSession.appendingPathComponent("events.jsonl"))

    let roots = TranscriptWatcher.Roots(
        claudeProjects: root.appendingPathComponent("claude/projects"),
        codexSessions: root.appendingPathComponent("codex/sessions"), codexIndex: nil,
        copilotSessions: root.appendingPathComponent("copilot/session-state"))
    let cache = root.appendingPathComponent("ledger.json")
    let ledger = TokenLedger(roots: roots, cacheURL: cache)
    var entries = ledger.refresh(now: now)
    func sum(_ agent: Agent) -> TokenCounts {
        entries.filter { $0.agent == agent }.reduce(TokenCounts()) { $0 + $1.counts }
    }
    check(entries.filter { $0.agent == .claude }.count == 2, "Claude: one entry per message, a fork's copy included once (got \(entries.filter { $0.agent == .claude }.count))")
    check(sum(.claude) == TokenCounts(input: 11, output: 7, cacheWrite: 100, cacheRead: 1000), "Claude counts by kind")
    check(sum(.codex) == TokenCounts(input: 300, output: 150, cacheWrite: 0, cacheRead: 2700), "Codex: records counted once, cached input split out")
    check(entries.first { $0.agent == .codex }?.model == "gpt-5.5", "Codex model from turn_context")
    check(sum(.copilot) == TokenCounts(input: 100, output: 20, cacheWrite: 200, cacheRead: 600), "Copilot: the last shutdown's totals, cache split out of input")

    _ = ledger.refresh(now: now)
    check(ledger.lastBytesRead == 0, "an unchanged log isn't read again")
    let more = #"{"type":"assistant","timestamp":"\#(stamp(now.addingTimeInterval(-60)))","requestId":"req_3","message":{"id":"msg_3","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":4,"output_tokens":6},"content":[]}}"#
    append([more], to: session)
    entries = ledger.refresh(now: now)
    check(ledger.lastBytesRead == UInt64(more.utf8.count + 1), "an appended log is read from where it was left (read \(ledger.lastBytesRead) bytes)")
    check(entries.filter { $0.agent == .claude }.count == 3, "the appended message counts")

    let reopened = TokenLedger(roots: roots, cacheURL: cache)
    let fromCache = reopened.refresh(now: now)
    check(reopened.lastBytesRead == 0 && fromCache.count == entries.count, "after a restart the cache answers without reading the logs")

    let later = reopened.refresh(now: now.addingTimeInterval(Double(TokenLedger.windowDays + 1) * 86400))
    check(later.isEmpty, "entries older than the window drop out")
}

func checkStatistics() {
    print("Statistics")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard let now = Dates.parse("2026-10-25T15:30:00Z") else { return }
    func at(_ text: String) -> Date { Dates.parse(text) ?? now }
    func entry(_ agent: Agent, _ model: String, _ time: String, _ tokens: Int) -> TokenEntry {
        TokenEntry(agent: agent, model: model, at: at(time), counts: TokenCounts(input: tokens))
    }
    let entries = [
        entry(.claude, "opus", "2026-10-25T01:10:00Z", 1000),
        entry(.codex, "gpt", "2026-10-25T15:00:00Z", 500),
        entry(.claude, "opus", "2026-10-24T10:00:00Z", 200),
        entry(.copilot, "haiku", "2026-10-19T08:00:00Z", 300),
        entry(.claude, "sonnet", "2026-10-18T08:00:00Z", 50),
        entry(.claude, "opus", "2026-09-15T08:00:00Z", 999),
        entry(.claude, "opus", "2026-10-25T16:00:00Z", 7),
    ]
    let day = TokenStatistics.summary(entries, period: .day, now: now, calendar: calendar)
    check(day.total.total == 1500 && day.bars.count == 24, "today: by the hour, up to now")
    check(day.bars[1].byAgent[.claude] == 1000 && day.bars[15].byAgent[.codex] == 500, "today: each call in its hour")
    let week = TokenStatistics.summary(entries, period: .week, now: now, calendar: calendar)
    check(week.total.total == 2000 && week.bars.count == 7, "7 days: today and the 6 before")
    check(week.bars.first?.byAgent[.copilot] == 300 && week.bars.last?.total == 1500, "7 days: oldest day first, today last")
    check(week.byAgent[.claude]?.total == 1200, "7 days: per agent")
    let month = TokenStatistics.summary(entries, period: .month, now: now, calendar: calendar)
    check(month.total.total == 2050 && month.bars.count == 30 && month.days == 30, "30 days: older than 30 days left out")
    check(month.models.map(\.model) == ["opus", "gpt", "haiku", "sonnet"], "models by tokens, most first")
    check(TokenStatistics.compact(950) == "950" && TokenStatistics.compact(12_400) == "12.4K"
          && TokenStatistics.compact(3_200_000) == "3.2M" && TokenStatistics.compact(1_000_000) == "1M"
          && TokenStatistics.compact(123_456_789) == "123M", "compact numbers")
}

/// The server-side counter, run here through `env HOME=… python3 -` in place of
/// ssh, against the same logs as the Swift ledger: both must agree exactly.
func checkRemoteCounter() {
    print("Remote counter (Python, run locally in place of ssh)")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-remote-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let project = home.appendingPathComponent(".claude/projects/-home-me-app")
    let codexDay = home.appendingPathComponent(".codex/sessions/2026/10/25")
    for folder in [project, codexDay] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let t = stamp(Date().addingTimeInterval(-900))
    let session = project.appendingPathComponent("s.jsonl")
    append([
        #"{"type":"assistant","timestamp":"\#(t)","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"output_tokens":7},"content":[]}}"#,
        #"{"type":"assistant","timestamp":"\#(t)","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"output_tokens":7},"content":[]}}"#,
    ], to: session)
    append([
        #"{"timestamp":"\#(t)","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
        #"{"timestamp":"\#(t)","type":"token_usage_record","payload":{"response_id":"x1","usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":20}}}"#,
    ], to: codexDay.appendingPathComponent("rollout-2026-10-25T10-00-00-\(UUID().uuidString.lowercased()).jsonl"))

    let remote = RemoteTokenSource(
        host: "test-server", cacheURL: root.appendingPathComponent("remote.json"),
        transport: ["/usr/bin/env", "HOME=\(home.path)", "CLAUDE_CONFIG_DIR=", "CODEX_HOME=", "COPILOT_HOME=", "python3", "-"])
    let local = TokenLedger(roots: .init(
        claudeProjects: home.appendingPathComponent(".claude/projects"),
        codexSessions: home.appendingPathComponent(".codex/sessions"), codexIndex: nil,
        copilotSessions: home.appendingPathComponent(".copilot/session-state")), cacheURL: nil)
    func totals(_ entries: [TokenEntry]) -> [String: TokenCounts] {
        Dictionary(grouping: entries, by: { $0.agent.rawValue + "/" + $0.model }).mapValues { $0.reduce(TokenCounts()) { $0 + $1.counts } }
    }
    switch remote.refresh() {
    case .failure(let error):
        check(false, "the counter runs (\(error.message))")
    case .success(let entries):
        check(totals(entries) == totals(local.refresh()), "the Python counter agrees with the Swift ledger")
        check(entries.allSatisfy { $0.source == "test-server" }, "entries are marked with the server")
        check(entries.count == 2, "one per message or response (got \(entries.count))")
    }
    append([#"{"type":"assistant","timestamp":"\#(stamp(Date().addingTimeInterval(-60)))","requestId":"r2","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[]}}"#], to: session)
    if case .success(let entries) = remote.refresh() {
        check(entries.count == 3, "an appended line is picked up from where the counter stopped")
    } else {
        check(false, "the second count runs")
    }
    let reopened = RemoteTokenSource(host: "test-server", cacheURL: root.appendingPathComponent("remote.json"), transport: ["/usr/bin/false"])
    check(reopened.cachedEntries().count == 3, "a server that can't be reached still shows its last counts")
    if case .failure(let error) = RemoteTokenSource(host: "nowhere", cacheURL: nil, transport: ["/bin/sh", "-c", "echo 'ssh: connect to host nowhere port 22: Connection refused' >&2; exit 255"]).refresh() {
        check(error.message == "Couldn't connect to nowhere: ssh: connect to host nowhere port 22: Connection refused", "a failed connection says why")
    } else {
        check(false, "a failed connection is an error")
    }
    if case .failure(let error) = RemoteTokenSource(host: "bare", cacheURL: nil, transport: ["/bin/sh", "-c", "exit 127"]).refresh() {
        check(error.message == "python3 isn't installed on bare", "a missing python3 is named")
    } else {
        check(false, "a missing python3 is an error")
    }
}

/// The server-side watcher, run here in place of ssh against a temp home: a turn
/// finishing there reminds through the same watcher, marked with the server.
func checkRemoteStream() {
    print("Remote watcher (Python, run locally in place of ssh)")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-stream-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let project = home.appendingPathComponent(".claude/projects/-home-me-site")
    let codexDay = home.appendingPathComponent(".codex/sessions/2026/10/25")
    for folder in [project, codexDay] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let session = project.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
    let thread = UUID().uuidString.lowercased()
    let rollout = codexDay.appendingPathComponent("rollout-2026-10-25T10-00-00-\(thread).jsonl")
    let big = String(repeating: "y", count: 3000)
    // History: an old finished turn, with a large tool result that must not travel in full.
    let old = Date().addingTimeInterval(-600)
    append([
        #"{"type":"user","cwd":"/home/me/site","timestamp":"\#(stamp(old))","message":{"role":"user","content":"old prompt"}}"#,
        #"{"type":"user","timestamp":"\#(stamp(old))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"\#(big)"}]}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(old))","message":{"id":"old","role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"old answer"}]}}"#,
        #"{"type":"ai-title","aiTitle":"Fix the build on the server","sessionId":"x"}"#,
    ], to: session)
    append([#"{"timestamp":"\#(stamp(old))","type":"session_meta","payload":{"id":"\#(thread)","cwd":"/home/me/api","source":"cli","base_instructions":{"text":"\#(big)"}}}"#], to: rollout)
    try? #"{"id":"\#(thread)","thread_name":"Speed up the API","updated_at":"x"}"#.appending("\n")
        .write(to: home.appendingPathComponent(".codex/session_index.jsonl"), atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(roots: .init(
        claudeProjects: root.appendingPathComponent("none/claude"), codexSessions: root.appendingPathComponent("none/codex"),
        codexIndex: nil, copilotSessions: root.appendingPathComponent("none/copilot")))
    watcher.debounce = [.claude: 0.5, .codex: 0.5, .copilot: 0.5]
    let collector = Collector()
    watcher.onJob = { collector.add($0) }
    let stream = RemoteSessionStream(
        host: "test-server",
        transport: ["/usr/bin/env", "HOME=\(home.path)", "CLAUDE_CONFIG_DIR=", "CODEX_HOME=", "COPILOT_HOME=", "python3", "-u", "-"],
        poll: 0.2, scan: 0.4)
    let statuses = StatusLog()
    var largest = 0
    stream.onStatus = { statuses.add($0) }
    stream.onLines = { path, agent, lines, prime, skew in
        largest = max(largest, lines.map { ($0.raw as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }?.count ?? 0 }.max() ?? 0)
        watcher.feed(source: "test-server", path: path, agent: agent, lines: lines, prime: prime, skew: skew)
    }
    stream.onNames = { watcher.feedNames(source: "test-server", names: $0) }
    stream.start()
    waitFor(10) { statuses.all.contains(.live) }
    check(statuses.all.contains(.live), "the watcher starts and reports in")
    Thread.sleep(forTimeInterval: 1.2)

    let now = Date()
    append([
        #"{"type":"user","cwd":"/home/me/site","timestamp":"\#(stamp(now))","message":{"role":"user","content":"make it faster"}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp(now.addingTimeInterval(0.3)))","message":{"id":"new","role":"assistant","model":"claude-fable-5","stop_reason":"end_turn","content":[{"type":"text","text":"Built and tested on the server."}]}}"#,
    ], to: session)
    append([
        #"{"timestamp":"\#(stamp(now))","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
        #"{"timestamp":"\#(stamp(now.addingTimeInterval(0.2)))","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Twice as fast now."}}"#,
    ], to: rollout)
    waitFor(8) { collector.allJobs.count >= 2 }
    Thread.sleep(forTimeInterval: 1)
    stream.stop()
    let jobs = collector.allJobs
    let claude = jobs.first { $0.agent == .claude }
    let codex = jobs.first { $0.agent == .codex }
    check(jobs.count == 2, "one reminder per finished job, none for history (got \(jobs.count))")
    check(claude?.source == "test-server" && claude?.summary == "Built and tested on the server.", "a Claude Code job on the server reminds, marked with the server")
    check(claude?.title == "Fix the build on the server" && claude?.project == "site", "its title and folder come from the server's log")
    check(codex?.title == "Speed up the API" && codex?.project == "api", "a Codex job is named from the server's session index")
    check(largest < 1500, "large tool results and instructions are cut before they travel (largest line \(largest) bytes)")
    check(statuses.all.last == .stopped, "it stops when asked")

    let failing = RemoteSessionStream(host: "nowhere", transport: ["/bin/sh", "-c", "echo 'ssh: Could not resolve hostname nowhere' >&2; exit 255"])
    let failures = StatusLog()
    failing.onStatus = { failures.add($0) }
    failing.start()
    // Under load, the first retry can take a few seconds to be said.
    waitFor(8) { failures.all.contains { if case .retrying = $0 { return true } else { return false } } }
    failing.stop()
    check(failures.all.contains(.retrying("ssh: Could not resolve hostname nowhere")), "a failed connection retries and says why: \(failures.all)")
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [RemoteSessionStream.Status] = []
    func add(_ status: RemoteSessionStream.Status) { lock.lock(); statuses.append(status); lock.unlock() }
    var all: [RemoteSessionStream.Status] { lock.lock(); defer { lock.unlock() }; return statuses }
}

/// Replays real logs in full and slimmed as the server's watcher sends them:
/// the finished jobs must come out the same.
func slimParity(_ paths: [String]) {
    for path in paths {
        let agent: Agent = path.hasSuffix("events.jsonl") ? .copilot : (URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") ? .codex : .claude)
        let settings = ["slim": [agent.rawValue, path]]
        guard let config = try? JSONSerialization.data(withJSONObject: settings),
              let result = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-u", "-"],
                                             input: Data(RemoteSessionStream.script.replacingOccurrences(of: "__CONFIG__", with: config.base64EncodedString()).utf8),
                                             timeout: 120),
              let full = FileManager.default.contents(atPath: path)
        else {
            print("couldn't slim \(path)")
            continue
        }
        func run(_ lines: [Data]) -> [JobEvent] {
            let tracker: SessionTracker
            switch agent {
            case .claude: tracker = ClaudeTracker(path: path)
            case .codex: tracker = CodexTracker(path: path, sessionIndex: nil)
            case .copilot: tracker = CopilotTracker(path: path)
            default: return []
            }
            var events: [String: JobEvent] = [:]
            var order: [String] = []
            for line in lines {
                guard let value = JSON.parse(line) else { continue }
                for case .finished(let event) in tracker.consume(value) {
                    if events[event.id] == nil { order.append(event.id) }
                    events[event.id] = event
                }
            }
            return order.compactMap { events[$0] }
        }
        let a = run(full.split(separator: 0x0A).map { Data($0) })
        let b = run(result.output.split(separator: 0x0A).map { Data($0) })
        let same = a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.outcome == $1.outcome && $0.title == $1.title && $0.summary == $1.summary }
        print(String(format: "%@ %@: %d jobs in full, %d slimmed, %@; %.0f KB → %.0f KB", agent.rawValue, URL(fileURLWithPath: path).lastPathComponent.prefix(24) as CVarArg,
                     a.count, b.count, same ? "same" : "DIFFERENT", Double(full.count) / 1024, Double(result.output.count) / 1024))
        if !same {
            for (x, y) in zip(a, b) where x.summary != y.summary || x.title != y.title {
                print("   full:   \(x.title ?? "-") | \(x.summary ?? "-")")
                print("   slimmed: \(y.title ?? "-") | \(y.summary ?? "-")")
                break
            }
        }
    }
}

/// Runs the Python counter on this Mac's real logs and compares it with the Swift ledger.
func parity() {
    let started = Date()
    let remote = RemoteTokenSource(host: "this-mac", cacheURL: nil, transport: ["/usr/bin/env", "python3", "-"])
    guard case .success(let python) = remote.refresh() else {
        print("the Python counter failed")
        return
    }
    let swift = TokenLedger(roots: .standard(), cacheURL: nil).refresh()
    print(String(format: "counted in %.1fs; python %d entries, swift %d entries", Date().timeIntervalSince(started), python.count, swift.count))
    for period in StatsPeriod.allCases {
        let a = TokenStatistics.summary(python, period: period, now: Date())
        let b = TokenStatistics.summary(swift, period: period, now: Date())
        let same = Agent.allCases.allSatisfy { a.byAgent[$0] == b.byAgent[$0] }
        print("\(period.rawValue): python \(a.total.total) vs swift \(b.total.total) \(same ? "(same, agent by agent)" : "(DIFFERENT)")")
    }
}

/// Counts a real server over ssh, cold then warm.
func remoteStatistics(_ host: String) {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hs-remote-live.json")
    try? FileManager.default.removeItem(at: cache)
    defer { try? FileManager.default.removeItem(at: cache) }
    for round in ["first count", "again (only what's new)"] {
        let started = Date()
        switch RemoteTokenSource(host: host, cacheURL: cache).refresh() {
        case .failure(let error):
            print("\(round): \(error.message)")
            return
        case .success(let entries):
            print(String(format: "%@: %.1fs, %d entries", round, Date().timeIntervalSince(started), entries.count))
            if round == "first count" {
                for period in StatsPeriod.allCases {
                    let summary = TokenStatistics.summary(entries, period: period, now: Date())
                    let agents = Agent.allCases.map { "\($0.clientName) \(TokenStatistics.compact(summary.byAgent[$0]?.total ?? 0))" }.joined(separator: ", ")
                    print("   \(period.rawValue): \(TokenStatistics.compact(summary.total.total)) (\(agents))")
                }
            }
        }
    }
}

/// Counts your real logs twice, cold then warm, and prints the three periods.
func liveStatistics() {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hs-ledger-live.json")
    try? FileManager.default.removeItem(at: cache)
    let ledger = TokenLedger(roots: .standard(), cacheURL: cache)
    var started = Date()
    let entries = ledger.refresh()
    print(String(format: "first count: %.1fs, read %.0f MB, %d entries", Date().timeIntervalSince(started), Double(ledger.lastBytesRead) / 1_048_576, entries.count))
    started = Date()
    _ = TokenLedger(roots: .standard(), cacheURL: cache).refresh()
    print(String(format: "again after a restart (from the cache): %.2fs", Date().timeIntervalSince(started)))
    for period in StatsPeriod.allCases {
        let summary = TokenStatistics.summary(entries, period: period, now: Date())
        let agents = Agent.allCases.map { "\($0.clientName) \(TokenStatistics.compact(summary.byAgent[$0]?.total ?? 0))" }.joined(separator: ", ")
        print("\(period.rawValue): \(TokenStatistics.compact(summary.total.total)) tokens (\(agents))")
        print("   input \(TokenStatistics.compact(summary.total.input)), output \(TokenStatistics.compact(summary.total.output)), cache write \(TokenStatistics.compact(summary.total.cacheWrite)), cache read \(TokenStatistics.compact(summary.total.cacheRead))")
        print("   models: " + summary.models.prefix(4).map { "\($0.model) \(TokenStatistics.compact($0.counts.total))" }.joined(separator: ", "))
    }
    try? FileManager.default.removeItem(at: cache)
}

// MARK: - Replay and live modes

func replay(_ path: String) {
    let tracker: SessionTracker
    if path.contains("/session-state/") || path.hasSuffix("events.jsonl") {
        tracker = CopilotTracker(path: path)
    } else if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") {
        let index = URL(fileURLWithPath: path).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        tracker = CodexTracker(path: path, sessionIndex: index)
    } else {
        tracker = ClaudeTracker(path: path)
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        print("Can't read \(path)")
        exit(1)
    }
    var events: [JobEvent] = []
    var cancels = 0
    for line in data.split(separator: 0x0A) {
        guard let value = JSON.parse(Data(line)) else { continue }
        for action in tracker.consume(value) {
            switch action {
            case .finished(let event):
                if let index = events.lastIndex(where: { $0.id == event.id }) {
                    events[index] = event
                } else {
                    events.append(event)
                }
            case .cancel:
                cancels += 1
            default:
                break
            }
        }
    }
    print("\(tracker.agent.clientName): \(events.count) finished turns, \(cancels) interrupted")
    for event in events.suffix(6) {
        let took = event.duration.map { String(format: "%.0fs", $0) } ?? "?"
        print("  [\(event.outcome.rawValue)] \(event.finishedAt) took \(took) · \(event.title ?? "-") · \(event.project ?? "-")")
        print("      \(event.summary ?? "")")
    }
}

func live() {
    for agent in Agent.allCases {
        let started = Date()
        do {
            let reading = try UsageReaders.read(agent)
            let took = String(format: "%.1fs", Date().timeIntervalSince(started))
            print("\(agent.displayName) (\(reading.plan ?? "plan unknown"), read in \(took))")
            for window in reading.windows {
                let reset = window.resetsAt.map { "resets \($0)" } ?? "no reset time"
                print("  \(window.title): \(window.usedPercent)% · \(reset)\(window.detail.map { " · \($0)" } ?? "")")
            }
            for note in reading.notes {
                print("  note: \(note)")
            }
        } catch {
            print("\(agent.displayName): \(error.localizedDescription)")
        }
    }
}

/// Watches the real session folders (or a root holding claude/projects,
/// codex/sessions and copilot/session-state) and prints what happens.
func watch(seconds: Double, root: String?) {
    let watcher: TranscriptWatcher
    if let root {
        let base = URL(fileURLWithPath: root)
        watcher = TranscriptWatcher(roots: .init(
            claudeProjects: base.appendingPathComponent("claude/projects"),
            codexSessions: base.appendingPathComponent("codex/sessions"),
            codexIndex: nil,
            copilotSessions: base.appendingPathComponent("copilot/session-state")))
    } else {
        watcher = TranscriptWatcher()
    }
    let started = Date()
    func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(started)) }
    watcher.debugLog = { print(stamp(), $0) }
    watcher.onJob = { print(stamp(), "JOB", $0.agent.rawValue, $0.outcome.rawValue, $0.title ?? "-", "·", $0.summary ?? "") }
    watcher.onUsage = { print(stamp(), "USAGE", $0.agent.rawValue, $0.windows.map { "\($0.title) \($0.usedPercent)%" }) }
    watcher.start()
    Thread.sleep(forTimeInterval: seconds)
    watcher.stop()
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--stats" {
    liveStatistics()
} else if arguments.first == "--parity" {
    parity()
} else if arguments.first == "--slim-parity", arguments.count > 1 {
    slimParity(Array(arguments.dropFirst()))
} else if arguments.first == "--remote", arguments.count > 1 {
    remoteStatistics(arguments[1])
} else if arguments.first == "--watch" {
    let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 20 : 20
    watch(seconds: seconds, root: arguments.count > 2 ? arguments[2] : nil)
} else if arguments.first == "--round-trip", arguments.count > 1 {
    // How the agent windows' signal measures a server: `--round-trip HOST`.
    let measured = RoundTrip.measure(arguments[1])
    print(measured.map { "\(arguments[1]): \($0.milliseconds) ms by \($0.how)" } ?? "\(arguments[1]): no reply")
} else if arguments.first == "--live" {
    live()
} else if arguments.first == "--remote-snapshot" {
    #if PHONE_CHECKS
    MainActor.assumeIsolated {
        remoteSnapshots(into: URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : NSTemporaryDirectory() + "AgentBuddyRemote-snapshots"))
    }
    #else
    print("Agent Buddy Remote, the iPhone and Apple Watch app, isn't in this copy")
    exit(1)
    #endif
} else if arguments.first == "--job-parity", arguments.count > 1 {
    jobParity(Array(arguments.dropFirst()))
} else if arguments.first == "--reading-parity", arguments.count > 1 {
    exit(readingParity(Array(arguments.dropFirst())))
} else if arguments.first == "--time-history", arguments.count > 1 {
    // How long reading a Claude Code log takes, step by step: `--time-history LOG`.
    let url = URL(fileURLWithPath: arguments[1])
    func timed<T>(_ what: String, _ body: () -> T) -> T {
        let start = Date()
        let result = body()
        print(String(format: "%@: %.3f s", what, Date().timeIntervalSince(start)))
        return result
    }
    let data = timed("mapping") { (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data() }
    let lines = timed("splitting and parsing \(data.count / 1_000_000) MB") { SessionHistoryReader.lines(data) }
    let history = timed("building the history of \(lines.count) lines") {
        SessionHistoryReader.claude(lines: lines, sessionID: url.deletingPathExtension().lastPathComponent)
    }
    _ = timed("the whole read, with sub-agents (\(history.turns.count) prompts)") { SessionHistoryReader.read(agent: .claude, path: url.path) }
    if let latest = history.turns.max(by: { $0.askedAt < $1.askedAt }) {
        let steps = timed("the latest prompt's steps") { SessionHistoryReader.steps(agent: .claude, path: url.path, turn: latest, cwd: history.cwd) }
        print("(\(steps?.count ?? 0) steps)")
    }
    func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Int(info.phys_footprint / 1_000_000)
    }
    let before = footprint()
    let reading = SessionLogReading()
    _ = timed("reading it to read on") { SessionHistoryReader.read(agent: .claude, path: url.path, reading: reading) }
    _ = timed("reading on, nothing added") { SessionHistoryReader.read(agent: .claude, path: url.path, reading: reading) }
    let kept = footprint()
    reading.forget()
    print("memory: \(before) MB, with the reading kept \(kept) MB, forgotten \(footprint()) MB")
} else if arguments.first == "--history", arguments.count > 1 {
    let host = arguments.firstIndex(of: "--on").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let named = arguments.count > 2 && !arguments[2].hasPrefix("--") ? arguments[2] : nil
    printHistory(arguments[1], agent: named, host: host)
} else if arguments.first == "--steps", arguments.count > 1 {
    // A turn's steps, in outline: `--steps LOG [N]`, the Nth prompt from the end (1, the latest).
    // `--steps SESSION N --on HOST`: a session on a server, by its id.
    let path = arguments[1]
    let agent: Agent = path.contains("/.codex/") || path.hasPrefix("rollout-") ? .codex : .claude
    let back = arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1
    let server = arguments.firstIndex(of: "--on").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    if let server, case .success(let history) = RemoteHistory.fetch(host: server, agent: agent, path: nil, sessionID: path) {
        let turns = history.turns.sorted { $0.askedAt < $1.askedAt }
        if turns.count >= back {
            let turn = turns[turns.count - back]
            let started = Date()
            switch RemoteHistory.steps(host: server, agent: agent, path: history.logPath, sessionID: path, turn: turn, cwd: history.cwd) {
            case .success(let steps):
                print("\(steps.count) steps from \(server) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s for: \(turn.text.prefix(60))")
                for step in steps.prefix(12) {
                    let change = step.hunks.isEmpty ? "" : " [+\(step.changes.added) -\(step.changes.removed)]"
                    print("● \(step.kind.rawValue)\(step.failed ? " FAILED" : ""): \(step.text.replacingOccurrences(of: "\n", with: " ").prefix(50))\(change)")
                }
            case .failure(let problem):
                print("couldn't read its steps: \(problem.message)")
            }
        }
    } else if server == nil, case .success(let history) = SessionHistoryReader.read(agent: agent, path: path) {
        let turns = history.turns.sorted { $0.askedAt < $1.askedAt }
        if turns.count >= back {
            let turn = turns[turns.count - back]
            let started = Date()
            // `--steps LOG N --as-server`: through the server's script, run here in place of ssh.
            let steps = arguments.contains("--as-server")
                ? ((try? RemoteHistory.steps(host: "here", agent: agent, path: path, sessionID: history.sessionID, turn: turn, cwd: history.cwd,
                                             transport: ["/usr/bin/env", "python3", "-"]).get()) ?? [])
                : (SessionHistoryReader.steps(agent: agent, path: path, turn: turn, cwd: history.cwd) ?? [])
            print("\(steps.count) steps in \(String(format: "%.2f", Date().timeIntervalSince(started))) s for: \(turn.text.prefix(60)) (asked \(turn.askedAt))")
            for step in steps {
                let outcome = step.outcome?.split(separator: "\n").first.map { " ⎿ \($0.prefix(70))" } ?? ""
                let change = step.hunks.isEmpty ? "" : " [+\(step.changes.added) -\(step.changes.removed), from line \(step.hunks.first?.newStart ?? 0)]"
                print("● \(step.kind.rawValue)\(step.failed ? " FAILED" : ""): \(step.text.replacingOccurrences(of: "\n", with: " ").prefix(60))\(change)\(outcome)")
            }
        }
    }
} else if arguments.first == "--keep-probe", arguments.count > 3 {
    // `--keep-probe CODEX_HOME THREAD FOLDER`: the real Codex app-server kept open on a
    // thread in a stand-in Codex home: resumed, its lock held, then let go. No prompt is sent.
    setenv("CODEX_HOME", arguments[1], 1)
    let request = PromptSender.Request(agent: .codex, sessionID: arguments[2], host: nil, folder: arguments[3], prompt: "",
                                       model: nil, permissionMode: nil, sandbox: "read-only", effort: nil)
    switch KeptSession.open(request) {
    case .failure(let problem):
        print("didn't open: \(problem.message)")
    case .success(let kept):
        let until = Date().addingTimeInterval(30)
        while kept.state == .opening, Date() < until {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let lock = URL(fileURLWithPath: arguments[1]).appendingPathComponent("thread-writer-locks/\(arguments[2]).lock").path
        print("state: \(kept.state); thread lock held: \(FileManager.default.fileExists(atPath: lock))")
        kept.close()
        let gone = Date().addingTimeInterval(10)
        while kept.state != .closed(nil), Date() < gone {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("after letting go: \(kept.state); lock file still there: \(FileManager.default.fileExists(atPath: lock))")
    }
} else if arguments.first == "--keep-turn", arguments.count > 2,
          let index = arguments.firstIndex(of: "--env"), index + 1 < arguments.count {
    // `--keep-turn HOST THREAD --env "HOME=DIR PATH=…"`: a Codex thread in a stand-in home on
    // the server (DIR/.codex, its model a stand-in), moved here and sent one prompt, as the app does.
    let host = arguments[1], thread = arguments[2], env = arguments[index + 1]
    let ssh = Array(RemoteTokenSource.ssh(host).dropLast())
    func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    switch RemoteHistory.fetch(host: host, agent: .codex, path: nil, sessionID: thread, transport: ssh + ["env \(env) python3 -"]) {
    case .failure(let problem):
        print("couldn't read it: \(problem.message)")
    case .success(let history):
        print("the session: approvals \(history.approvalPolicy ?? "-"), reviewer \(history.approvalsReviewer ?? "-"), profile \(history.permissionProfile ?? "-")")
        let request = PromptSender.Request(history: history, host: host, prompt: "\u{2026}")
        if case .success(let plan) = PromptSender.plan(request) {
            print("a send runs: codex \(plan.arguments.joined(separator: " "))\n  \(plan.permissions); \(plan.asks)")
        }
        switch KeptSession.open(request, transport: ssh + [env]) {
        case .failure(let problem):
            print("didn't open: \(problem.message)")
        case .success(let kept):
            waitFor(60) { kept.state != .opening }
            print("kept: \(kept.state)")
            if kept.state == .ready, case .success = kept.send("Stand-in check: run one command.") {
                waitFor(180) { kept.state != .working }
                print("after the turn: \(kept.state), problem: \(kept.problem ?? "none")")
            }
            kept.close()
            waitFor(10) { kept.state == .closed(nil) }
        }
    }
} else if arguments.first == "--agent-log", arguments.count > 2, let agent = Agent(rawValue: arguments[1]) {
    // `--agent-log AGENT PATH`: a session of an agent watched through its log, as read (OpenCode: DATABASE#SESSION).
    switch AgentLogs.read(agent: agent, path: arguments[2]) {
    case .success(let session):
        let history = session.history
        print("\(agent.clientName) session \(history.sessionID): \(history.turns.count) prompts; title \(history.title ?? "-"); folder \(history.cwd ?? "-"); model \(history.model ?? "-")\(history.isSubagent ? "; a sub-agent's" : "")")
        for turn in history.turns {
            let tokens = turn.usage.reduce(TokenCounts()) { $0 + $1.counts }
            print("  [\(turn.outcome.rawValue)] \(turn.text.prefix(50).replacingOccurrences(of: "\n", with: " ")) → \(turn.answer?.prefix(40).replacingOccurrences(of: "\n", with: " ") ?? "-") | in \(tokens.input) out \(tokens.output) cached \(tokens.cacheRead)\(turn.endedAt.map { " | took \(Int($0.timeIntervalSince(turn.askedAt))) s" } ?? "")")
        }
        print("  \(session.tokens.count) replies with tokens")
    case .failure(let problem):
        print("couldn't read it: \(problem.message)")
    }
} else if arguments.first == "--agent-logs" {
    // `--agent-logs`: the sessions of the agents watched through their logs, from the last 35 days.
    for session in AgentLogs.sessions(since: Date().addingTimeInterval(-35 * 86400)) {
        print("\(session.agent.rawValue)\t\(session.modified)\t\(session.path)")
    }
} else if arguments.first == "--codex-models" {
    // `--codex-models [HOST]`: the models Codex offers here (or on the server), as the
    // message box's menu lists them. It asks Codex's app-server; no thread, no prompt.
    let host = arguments.count > 1 ? arguments[1] : nil
    let started = Date()
    switch CodexModels.list(host: host) {
    case .success(let models):
        print("\(models.count) models from \(host ?? "this Mac")'s Codex in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for model in models {
            print("  \(model.name) (\(model.id))\(model.isDefault ? ", its default" : ""): \(model.efforts.joined(separator: ", "))\(model.fast ? "; fast" : "")")
        }
    case .failure(let problem):
        print("couldn't list them: \(problem.message)")
    }
} else if arguments.first == "--put-files", arguments.count > 2 {
    // `--put-files HOST FILE…`: copies files to the server as a prompt's are sent; prints where.
    switch RemoteFiles.put(arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }, host: arguments[1]) {
    case .success(let paths): paths.forEach { print($0) }
    case .failure(let problem): print("not copied: \(problem.message)")
    }
} else if arguments.first == "--codex-writer", arguments.count > 2 {
    // `--codex-writer HOST THREAD [--home DIR] [--stop]`: who holds the thread on the server
    // (in a stand-in home there, with --home), and with --stop, stop it.
    var transport: [String]?
    if let index = arguments.firstIndex(of: "--home"), index + 1 < arguments.count {
        transport = Array(RemoteTokenSource.ssh(arguments[1]).dropLast()) + ["env HOME=\(arguments[index + 1]) python3 -"]
    }
    if let held = RemoteHistory.codexHolder(host: arguments[1], thread: arguments[2], transport: transport) {
        print("\(held.name), pid \(held.pid), holding \(held.threads.count) thread\(held.threads.count == 1 ? "" : "s")")
        if arguments.contains("--stop") {
            print("stopped: \(RemoteHistory.stopCodex(host: arguments[1], thread: arguments[2], pid: held.pid, transport: transport))")
            print("now: \(RemoteHistory.codexWriter(host: arguments[1], thread: arguments[2], transport: transport) ?? "nobody holds it")")
        }
    } else {
        print("nobody holds it")
    }
} else if arguments.first == "--zed-selection" {
    // What Zed's database says is selected now: where, and how much (not the text).
    let database = ZedSelection.database()
    if let latest = ZedSelection.latest(database: database) {
        var place = latest.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "an unsaved buffer"
        if let host = latest.host {
            place += " on \(host)"
        }
        if latest.isEmpty {
            print("Zed: a cursor in \(place), nothing selected (mark \(latest.mark))")
        } else if latest.host == nil, let path = latest.path, let data = latest.contents(database: database).map({ Data($0.utf8) })
                    ?? FileManager.default.contents(atPath: path), let excerpt = ZedSelection.excerpt(data, start: latest.start, end: latest.end) {
            print("Zed: \(excerpt.text.count) characters selected in \(place), lines \(excerpt.lines.lowerBound)–\(excerpt.lines.upperBound) (mark \(latest.mark))")
        } else {
            print("Zed: \(latest.end - latest.start) bytes selected in \(place) (mark \(latest.mark))")
        }
    } else {
        print("Zed: no selection saved")
    }
} else if arguments.first == "--codex-resets" {
    liveCodexResets()
} else if arguments.first == "--mock-ntfy" {
    #if PHONE_CHECKS
    serveMockNtfy(port: arguments.count > 1 ? UInt16(arguments[1]) ?? 0 : 0)
    #else
    print("The iPhone link's checks, and their mock ntfy server, aren't in this copy")
    exit(1)
    #endif
} else if arguments.first == "--replay", arguments.count > 1 {
    for path in arguments.dropFirst() {
        replay(path)
    }
} else {
    checkDates()
    checkClaudeUsage()
    checkCodexUsage()
    checkCodexResets()
    checkCopilotUsage()
    checkTokenLedger()
    checkRemoteCounter()
    checkStatistics()
    checkMenuValues()
    checkFolding()
    #if PHONE_CHECKS
    checkPhoneFormat()
    checkPhoneSnapshot()
    checkWindowFeed()
    checkPhoneOverHTTP()
    checkRemoteControl()
    #endif
    checkHistory()
    checkPromptSelections()
    checkRoundTrip()
    checkMissedJobs()
    checkArchive()
    checkLogImport()
    checkRemoteLookup()
    checkJobTokens()
    checkWorking()
    checkRemoteHistory()
    checkPromptSender()
    checkSendOptions()
    checkComposerSuggestions()
    checkAgentLogs()
    checkLogReading()
    checkSelections()
    checkSteps()
    checkCodexWriter()
    checkKeptSessions()
    checkPromptSenderRuns()
    checkWindowFinding()
    checkWindowMath()
    checkClaudeTracker()
    checkCodexTracker()
    checkCopilotTracker()
    checkWatcher()
    checkWatcherOnLongSession()
    checkRemoteStream()
    print(failed == 0 ? "All \(passed) checks passed." : "\(failed) of \(passed + failed) checks failed.")
    exit(failed == 0 ? 0 : 1)
}
