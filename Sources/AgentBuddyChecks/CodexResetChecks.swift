import Foundation
import AgentBuddyCore

/// codex-reset.com's forecast, as `GET /api/forecast` gives it.
func checkCodexResets() {
    print("Everyone's Codex resets (codex-reset.com)")
    let quiet = json("""
    {"mode": "model", "updated_at": "2026-10-26T06:14:48.876Z",
     "probabilities": {"raw_24h": 0.528, "raw_48h": 0.777, "rounded_24h": 53, "rounded_48h": 78, "range_24h": {"lower": 0.3, "upper": 0.75}},
     "confidence": "medium", "last_reset_at": "2026-10-26T06:08:46.000Z", "age_days": 0, "official_signal": null,
     "time_window": {"start_hour": 12, "end_hour": 15, "label": "12 PM - 3 PM", "timezone": "Asia/Singapore"},
     "latest_alert": {"id": "2114588174249071102", "kind": "reset", "state": "confirmed", "source_at": "2026-10-26T06:08:46.000Z",
                      "summary": "Reset observed by operator.", "url": "https://x.com/thsottiaux/status/2114588174249071102",
                      "score": null, "window": null, "corrected": true}}
    """)
    if let forecast = CodexResetForecast.parse(quiet) {
        check(forecast.lastResetAt == Dates.parse("2026-10-26T06:08:46.000Z"), "the last reset for everyone")
        check(forecast.chance24h == 53 && forecast.chance48h == 78 && forecast.confidence == "medium", "the chances of the next, and how sure")
        check(forecast.usualHours == "12 PM - 3 PM", "the hours resets usually come, in this Mac's zone")
        check(forecast.announced == nil, "a confirmed reset isn't one to come")
    } else {
        check(false, "the forecast reads")
    }
    let watch = json("""
    {"updated_at": "2026-10-27T01:00:00Z", "probabilities": {"rounded_24h": 93, "rounded_48h": 97}, "confidence": "high",
     "last_reset_at": "2026-10-26T06:08:46.000Z", "official_signal": {"kind": "watch"},
     "latest_alert": {"id": "1", "kind": "watch", "state": "active", "source_at": "2026-10-27T00:40:00Z",
                      "summary": "Tibo: resetting limits for everyone in a few hours.", "url": "https://x.com/thsottiaux/status/1",
                      "score": 93, "corrected": false,
                      "window": {"label": "tonight", "start_at": "2026-10-27T02:00:00Z", "end_at": "2026-10-27T06:00:00Z",
                                 "time_zone": "America/Los_Angeles", "target_at": "2026-10-27T03:00:00Z"}}}
    """)
    if let announced = CodexResetForecast.parse(watch)?.announced {
        check(announced.summary.hasPrefix("Tibo: resetting") && announced.url?.host == "x.com", "a reset said to be coming, with its post")
        check(announced.window == "tonight" && announced.target == Dates.parse("2026-10-27T03:00:00Z")
              && announced.end == Dates.parse("2026-10-27T06:00:00Z"), "and when")
    } else {
        check(false, "an announced reset reads")
    }
    var expired = watch.raw as? [String: Any] ?? [:]
    var alert = expired["latest_alert"] as? [String: Any] ?? [:]
    alert["state"] = "expired"
    expired["latest_alert"] = alert
    check(CodexResetForecast.parse(JSON(expired))?.announced == nil, "an announcement whose time passed is gone")
    check(CodexResetForecast.parse(json(#"{"confidence": "low"}"#)) == nil, "no chances, no forecast")
}

/// `AgentBuddyChecks --codex-resets`: asks codex-reset.com once and prints its forecast.
func liveCodexResets() {
    switch CodexResetSource.fetch() {
    case .success(let forecast):
        print("last reset for everyone: \(forecast.lastResetAt.map { "\($0)" } ?? "-")")
        print("within 24 h: \(forecast.chance24h)%, within 48 h: \(forecast.chance48h)% (\(forecast.confidence ?? "-") confidence)")
        print("usual hours here: \(forecast.usualHours ?? "-")")
        print("announced: \(forecast.announced.map { "\($0.summary) \($0.window ?? "")" } ?? "none")")
        print("Data: codex-reset.com")
    case .failure(let failure):
        print("couldn't read codex-reset.com: \(failure)")
        exit(1)
    }
}
