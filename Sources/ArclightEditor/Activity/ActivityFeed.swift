import ArclightCore
import Foundation

/// One row of the activity feed: a single entry, or a run of consecutive editor saves shown as "You · 7 edits".
struct ActivityItem: Identifiable, Equatable {
    /// Newest first.
    var entries: [ActivityEntry]

    var id: String { entries.first?.id ?? "" }
    var lead: ActivityEntry { entries[0] }
    var oldest: ActivityEntry { entries[entries.count - 1] }
    var isGroup: Bool { entries.count > 1 }
    var date: Date? { lead.date }
    var scene: String? { lead.scene }
    var write: Bool { entries.contains { $0.write } }
    /// Rev the scene had before the first change in this item.
    var revBefore: Int? { oldest.revBefore }
    var revAfter: Int? { lead.revAfter }

    /// Changed layer ids across all entries, most frequently changed first (ties: most recent first).
    var changed: [String] {
        var count: [String: Int] = [:], order: [String] = []
        for e in entries {
            for id in e.changed ?? [] { if count[id] == nil { order.append(id) }; count[id, default: 0] += 1 }
        }
        return order.enumerated().sorted { a, b in
            let ca = count[a.element]!, cb = count[b.element]!
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
    }

    /// "7 edits · title, stat" for groups; the entry summary otherwise.
    var summary: String {
        guard isGroup else { return lead.summary }
        let ch = changed
        let names = ch.prefix(3).joined(separator: ", ") + (ch.count > 3 ? " +\(ch.count - 3)" : "")
        return "\(entries.count) edits" + (names.isEmpty ? "" : " · " + names)
    }
}

enum ActivityFeed {
    /// Raw values are stored in settings; "claude" means any AI agent.
    enum Who: String, CaseIterable { case all, ai = "claude", you }

    struct Filter: Equatable {
        var who: Who = .all
        /// Only entries for this scene (nil = every scene).
        var scene: String?
        var reads = true
    }

    /// Entries passing the filter, newest first. Failed calls always show (unless filtered by who/scene).
    static func filter(_ entries: [ActivityEntry], _ f: Filter) -> [ActivityEntry] {
        entries.reversed().filter { e in
            switch f.who {
            case .all: break
            case .ai: if !e.isAI { return false }
            case .you: if e.isAI { return false }
            }
            if let s = f.scene, e.scene != s { return false }
            return f.reads || e.write || !e.ok
        }
    }

    /// Collapses runs of consecutive editor saves to the same scene, each within `window` seconds of the next,
    /// into one item. Input and output are newest first.
    static func group(
        _ newestFirst: [ActivityEntry], window: TimeInterval = 60, calendar: Calendar = .current
    ) -> [ActivityItem] {
        var out: [ActivityItem] = []
        for e in newestFirst {
            if isEditorSave(e), var last = out.last, isEditorSave(last.oldest), last.oldest.scene == e.scene,
                let a = last.oldest.date, let b = e.date, a.timeIntervalSince(b) <= window, a >= b,
                calendar.isDate(a, inSameDayAs: b)
            {
                last.entries.append(e)
                out[out.count - 1] = last
            } else {
                out.append(ActivityItem(entries: [e]))
            }
        }
        return out
    }

    static func isEditorSave(_ e: ActivityEntry) -> Bool { e.source == ChangeSource.editor.rawValue && e.write && e.ok }

    struct Day: Identifiable, Equatable {
        var label: String
        var items: [ActivityItem]
        var id: String { (items.first?.id ?? "") + label }
    }

    /// Splits items (newest first) into day sections: "Today", "Yesterday", "Mon, Nov 3".
    static func days(_ items: [ActivityItem], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var out: [Day] = []
        for it in items {
            let label = it.date.map { dayLabel($0, now: now, calendar: calendar) } ?? "Earlier"
            if out.last?.label == label {
                out[out.count - 1].items.append(it)
            } else {
                out.append(Day(label: label, items: [it]))
            }
        }
        return out
    }

    static func dayLabel(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "Yesterday"
        }
        let f = dayFormatter
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(d, equalTo: now, toGranularity: .year) ? "EEE, MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// "now", "42s", "5m", "3h", "2d".
    static func relative(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = Int(now.timeIntervalSince(d))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Pretty-printed request JSON. scene_apply shows just its ops; truncated/unparseable detail comes back as is.
    static func pretty(_ detail: String) -> String {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(detail.utf8)) else { return detail }
        var shown = v
        if let o = v.object, let ops = o["ops"], o.keys.allSatisfy({ ["ops", "scene", "rev"].contains($0) }) {
            shown = ops
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(shown), let s = String(data: data, encoding: .utf8) else { return detail }
        return s
    }
}
