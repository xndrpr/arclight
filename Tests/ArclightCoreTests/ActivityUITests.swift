import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

struct ActivityUITests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// `source` is a stored `ChangeSource` raw value; AI entries use the legacy value "claude" for every agent.
    func entry(
        _ source: String, _ secs: Double, scene: String = "s", changed: [String]? = nil, write: Bool = true,
        ok: Bool = true,
        rev: (Int, Int)? = nil, tool: String? = nil
    ) -> ActivityEntry {
        var e = ActivityEntry(
            source: ChangeSource(rawValue: source)!, tool: tool ?? (source == "editor" ? "edit" : "scene_apply"),
            scene: scene,
            summary: "changed " + (changed ?? []).joined(separator: ", "), changed: changed,
            revBefore: rev?.0, revAfter: rev?.1, ok: ok, write: write)
        e.time = Self.iso.string(from: Self.base.addingTimeInterval(secs))
        return e
    }

    @Test func groupsConsecutiveEditorSavesWithinAMinute() {
        // Oldest first, as the log stores them.
        let log = [
            entry("claude", 0, changed: ["bg"], rev: (1, 2)),
            entry("editor", 10, changed: ["title"], rev: (2, 3)),
            entry("editor", 40, changed: ["title", "stat"], rev: (3, 4)),
            entry("editor", 95, changed: ["title"], rev: (4, 5)),  // 55 s after the previous: same run
            entry("editor", 200, changed: ["stat"], rev: (5, 6)),  // 105 s gap: new run
            entry("editor", 210, scene: "other", changed: ["x"], rev: (1, 2)),  // other scene: new run
            entry("claude", 220, changed: ["title"], rev: (6, 7)),
            entry("editor", 225, changed: ["title"], rev: (7, 8)),
        ]
        let items = ActivityFeed.group(ActivityFeed.filter(log, .init()))
        #expect(items.map(\.entries.count) == [1, 1, 1, 1, 3, 1])
        let run = items[4]
        #expect(run.isGroup && run.revBefore == 2 && run.revAfter == 5)
        #expect(run.changed == ["title", "stat"])
        #expect(run.summary == "3 edits · title, stat")
        #expect(items[0].summary == "changed title" && !items[0].isGroup)
    }

    @Test func failedOrReadEntriesBreakRuns() {
        let log = [
            entry("editor", 0, changed: ["a"], rev: (1, 2)),
            entry("claude", 5, write: false, tool: "scene_get"),
            entry("editor", 10, changed: ["b"], rev: (2, 3)),
            entry("editor", 20, changed: ["c"], rev: (3, 4)),
        ]
        #expect(ActivityFeed.group(ActivityFeed.filter(log, .init())).map(\.entries.count) == [2, 1, 1])
        // Hiding reads lets the editor saves join up.
        #expect(ActivityFeed.group(ActivityFeed.filter(log, .init(reads: false))).map(\.entries.count) == [3])
    }

    @Test func filters() {
        let log = [
            entry("claude", 0, changed: ["a"], rev: (1, 2)),
            entry("claude", 1, write: false, tool: "scene_get"),
            entry("claude", 2, write: false, ok: false),
            entry("editor", 3, scene: "t", changed: ["b"], rev: (1, 2)),
        ]
        #expect(ActivityFeed.filter(log, .init(who: .ai)).count == 3)
        #expect(ActivityFeed.filter(log, .init(who: .you)).map(\.source) == ["editor"])
        #expect(ActivityFeed.filter(log, .init(scene: "t")).count == 1)
        // Reads off keeps writes and failures; newest first.
        #expect(ActivityFeed.filter(log, .init(reads: false)).map(\.time) == [log[3].time, log[2].time, log[0].time])
    }

    @Test func daysAndRelativeTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        #expect(ActivityFeed.dayLabel(now.addingTimeInterval(-3600), now: now, calendar: cal) == "Today")
        #expect(ActivityFeed.dayLabel(now.addingTimeInterval(-86400), now: now, calendar: cal) == "Yesterday")
        #expect(ActivityFeed.dayLabel(now.addingTimeInterval(-86400 * 7), now: now, calendar: cal) == "Tue, Nov 3")
        #expect(ActivityFeed.relative(now.addingTimeInterval(-2), now: now) == "now")
        #expect(ActivityFeed.relative(now.addingTimeInterval(-90), now: now) == "1m")
        #expect(ActivityFeed.relative(now.addingTimeInterval(-7200), now: now) == "2h")

        var a = entry("claude", 0, rev: (1, 2)); a.time = Self.iso.string(from: now.addingTimeInterval(-60))
        var b = entry("claude", 0, rev: (2, 3)); b.time = Self.iso.string(from: now.addingTimeInterval(-90000))
        let days = ActivityFeed.days(ActivityFeed.group([a, b]), now: now, calendar: cal)
        #expect(days.map(\.label) == ["Today", "Yesterday"])
    }

    @Test func prettyRequest() {
        let p = ActivityFeed.pretty(#"{"ops":[{"id":"title","op":"set","size":140}],"scene":"s"}"#)
        #expect(p.hasPrefix("[") && p.contains("\"size\" : 140") && !p.contains("\"scene\""))
        #expect(ActivityFeed.pretty(#"{"id":"s","nodes":[]}"#).contains("\"nodes\""))
        #expect(ActivityFeed.pretty("{\"ops\":[{\"op\":\"se…") == "{\"ops\":[{\"op\":\"se…")
    }
}
