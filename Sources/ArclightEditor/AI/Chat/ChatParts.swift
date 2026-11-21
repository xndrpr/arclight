import AppKit
import ArclightCore
import SwiftUI

/// What the message list draws: a message, or the AI's work between messages (its thinking and tool calls) folded
/// into one line per turn.
enum ChatBlock: Identifiable {
    case item(ChatItem)
    case work([ChatItem])

    var id: String {
        switch self {
        case .item(let i): return i.id
        case .work(let w): return "work-" + (w.first?.id ?? "")
        }
    }

    static func group(_ items: [ChatItem]) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var run: [ChatItem] = []
        func flush() {
            if !run.isEmpty { out.append(.work(run)) }
            run = []
        }
        for i in items {
            if i.kind == .tool || i.kind == .thinking { run.append(i) } else { flush(); out.append(.item(i)) }
        }
        flush()
        return out
    }
}

/// The AI's work between two messages: "Worked for 42s · 7 steps: read the scene, edited the scene". While it
/// runs: the step in progress, with the newest lines of its thinking. Click for every step.
struct ChatWorkGroup: View, Equatable {
    let steps: [ChatItem]
    let live: Bool
    @State private var open = false

    static func == (a: Self, b: Self) -> Bool { a.live == b.live && a.steps == b.steps }

    var body: some View {
        let failed = steps.filter { $0.kind == .tool && $0.ok == false }.count
        let current = live ? steps.last : nil
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Group {
                        if live {
                            ProgressView().controlSize(.mini)
                        } else if failed > 0 {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(UI.warning)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(UI.success.opacity(0.85))
                        }
                    }
                    .font(.system(size: 11)).frame(width: 14)
                    Text(title(current, failed: failed)).font(UI.small).foregroundStyle(live ? UI.label2 : UI.dim)
                        .lineLimit(1).truncationMode(.tail).shimmering(live)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(UI.raised.opacity(0.7)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).cursor(.pointingHand).help(open ? "Hide the steps" : "Show each step")
            if live, !open, let t = current, t.kind == .thinking, !t.text.isEmpty {
                ChatThinkingTail(text: t.text).padding(.leading, 31)
            }
            if open {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps) { s in
                        if s.kind == .thinking {
                            ChatThinkingRow(item: s, live: live && s.id == steps.last?.id && s.duration == nil)
                        } else {
                            ChatToolRow(item: s)
                        }
                    }
                }
                .padding(.leading, 12).padding(.vertical, 2)
                .overlay(alignment: .leading) { Rectangle().fill(UI.border).frame(width: 1).padding(.leading, 16) }
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
    }

    private func title(_ current: ChatItem?, failed: Int) -> String {
        let tools = steps.filter { $0.kind == .tool }
        if let c = current {
            if c.kind == .thinking { return "Thinking…" }
            return ChatToolNames.doing(c.tool ?? "") + "…" + (tools.count > 1 ? "  ·  step \(tools.count)" : "")
        }
        var s = Self.span(steps).map { "Worked for " + Self.duration($0) } ?? (tools.isEmpty ? "Thought" : "Worked")
        if !tools.isEmpty {
            var seen: [String] = []
            for t in tools {
                let d = ChatToolNames.done(t.tool ?? "")
                if !seen.contains(d) { seen.append(d) }
            }
            s += " · \(tools.count) step\(tools.count == 1 ? "" : "s"): "
                + seen.prefix(3).map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: ", ")
            if seen.count > 3 { s += "…" }
        }
        if failed > 0 { s += " · \(failed) failed" }
        return s
    }

    /// From the first step's start to the last one's end, where the steps know their times.
    static func span(_ steps: [ChatItem]) -> TimeInterval? {
        let starts = steps.compactMap(\.started)
        guard let first = starts.min() else { return nil }
        let end = steps.compactMap { s in s.started.map { $0.addingTimeInterval(s.duration ?? 0) } }.max() ?? first
        let d = end.timeIntervalSince(first)
        return d >= 1 ? d : nil
    }

    static func duration(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        return s < 60 ? "\(s)s" : s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s"
    }
}

/// The AI's reply: Markdown blocks, a copy button on hover, and Copy in the context menu.
struct ChatAssistantRow: View {
    let text: String
    let live: Bool
    /// When the reply began, for its "✦ Arclight · 14:32" line (shown on a turn's first reply only).
    var author: Date? = nil
    var showsAuthor = false
    /// The turn this reply ends, for the line under it.
    var turn: ChatTurn?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsAuthor {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(
                            LinearGradient(colors: [UI.ai, UI.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "sparkles").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    Text("Arclight").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.label2)
                    if let d = author {
                        Text(d.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(UI.faint)
                    }
                }
                .padding(.bottom, 2)
            }
            ChatMarkdown(text: text, live: live)
            // Its room is kept while the reply is written, so the reply doesn't jump when it ends.
            HStack(spacing: 6) {
                if let turn { ChatTurnFooter(turn: turn) }
                Spacer(minLength: 0)
                IconButton(symbol: "doc.on.doc", help: "Copy message") { ChatRow.copy(text) }
                    .opacity(hover && !live ? 1 : 0).disabled(live)
            }
            .frame(height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { Button("Copy Message") { ChatRow.copy(text) } }
    }
}

/// Markdown the model writes, block by block: paragraphs, headings, bullet and numbered lists, code fences.
/// Inline styles (bold, italic, code, links) inside each block.
struct ChatMarkdown: View {
    let text: String
    /// Still being written: its new blocks fade in.
    var live = false

    private static let parsed: NSCache<NSString, Boxed<[Block]>> = {
        let c = NSCache<NSString, Boxed<[Block]>>()
        c.countLimit = 600
        return c
    }()

    /// `blocks`, remembered (a long chat is scrolled through many times). A reply being written only grows at its
    /// end: what comes before its last blank line outside a code fence is final, so only the rest is parsed again.
    static func cachedBlocks(_ text: String, live: Bool) -> [Block] {
        if live, let cut = settledEnd(text) {
            return cachedBlocks(String(text[..<cut.lowerBound]), live: false) + blocks(String(text[cut.upperBound...]))
        }
        if live { return blocks(text) }
        if let hit = parsed.object(forKey: text as NSString) { return hit.value }
        let b = blocks(text)
        parsed.setObject(Boxed(b), forKey: text as NSString)
        return b
    }

    /// The last blank line of `s` that isn't inside a code fence.
    private static func settledEnd(_ s: String) -> Range<String.Index>? {
        var end = s.endIndex
        while let gap = s.range(of: "\n\n", options: .backwards, range: s.startIndex..<end) {
            let fences = s[..<gap.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix("```") }.count
            if fences % 2 == 0 { return gap }
            end = gap.lowerBound
        }
        return nil
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(String, Int)
        case bullet(String, Int)
        case numbered(String, String)
        case code(String)
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))) }
            para = []
        }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flush()
                out.append(
                    .heading(
                        String(line[h...]).trimmingCharacters(in: .whitespaces),
                        line.distance(from: line.startIndex, to: h)))
                continue
            }
            let indent = raw.prefix { $0 == " " }.count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(String(line.dropFirst(2)), indent)); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
                line[..<dot].allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex,
                line[line.index(after: dot)] == " "
            {
                flush()
                out.append(.numbered(String(line[line.index(dot, offsetBy: 2)...]), String(line[..<dot])))
                continue
            }
            para.append(raw)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        let blocks = Self.cachedBlocks(text, live: live)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                let md = { (s: String) in
                    live && i == blocks.count - 1 ? ChatRow.liveMarkdown(s) : ChatRow.markdown(s)
                }
                block(b, md).modifier(FadeIn(enabled: live))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: Block, _ md: (String) -> AttributedString) -> some View {
        switch b {
        case .paragraph(let s):
            Text(md(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            Text(md(s)).font(.system(size: level <= 1 ? 15 : level == 2 ? 14 : 13, weight: .semibold))
                .foregroundStyle(UI.text).padding(.top, 2)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").font(ChatRow.body).foregroundStyle(UI.dim)
                Text(md(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14 + 2)
        case .numbered(let s, let n):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n + ".").font(ChatRow.body).foregroundStyle(UI.dim).monospacedDigit()
                Text(md(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(UI.monoSmall).foregroundStyle(UI.label2).padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
        }
    }
}

/// Fades a view in when it first appears (a new block of a reply being written), without animating the layout
/// around it.
private struct FadeIn: ViewModifier {
    let enabled: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content.opacity(!enabled || shown ? 1 : 0)
            .onAppear { if enabled { withMotion(.easeOut(duration: 0.35)) { shown = true } } }
    }
}

/// The chat header's model picker: which fal model makes images and 3D models (with prices), or Auto.
struct ChatModelMenu: View {
    @State private var models = ImageSettings.models
    @State private var hasKey = KeychainStore.falKey() != nil

    var body: some View {
        Menu {
            if !hasKey {
                Button("Add a fal.ai key for images and 3D…") { ChatSettingsLink.open() }
                Divider()
            }
            Section("Images") {
                choice(ModelCatalog.auto, label: "Auto — best model for each picture", kp: \.generate)
                ForEach(ModelCatalog.images) { e in choice(e.id, label: label(e), kp: \.generate) }
            }
            Section("3D models") {
                choice(ModelCatalog.auto, label: "Auto — Trellis 2 ($0.30), Trellis ($0.02) for drafts", kp: \.model3D)
                ForEach(ModelCatalog.models3D) { e in choice(e.id, label: label(e), kp: \.model3D) }
            }
            Divider()
            Button("Custom model ids…") { ChatSettingsLink.open() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo.stack").font(.system(size: 10, weight: .medium))
                Text(short(models.generate)).font(UI.small).lineLimit(1)
            }
            .foregroundStyle(UI.label2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().cursor(.pointingHand)
        .help("Image model: \(name(models.generate)) · 3D model: \(name(models.model3D)). Prices are per result.")
        .onAppear {
            models = ImageSettings.models
            hasKey = KeychainStore.falKey() != nil
        }
    }

    private func label(_ e: ModelCatalog.Entry) -> String {
        "\(e.label)  ·  \(e.priceNote)  ·  \(e.bestFor)" + (e.expensive ? "  (expensive)" : "")
    }

    private func name(_ id: String) -> String {
        id == ModelCatalog.auto ? "Auto" : ModelCatalog.entry(id)?.label ?? id
    }

    private func short(_ id: String) -> String { name(id) }

    private func choice(_ id: String, label: String, kp: WritableKeyPath<FalProvider.Models, String>) -> some View {
        Button {
            models[keyPath: kp] = id
            ImageSettings.models = models
        } label: {
            if models[keyPath: kp] == id { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}

/// One line of the message list: a block and what is drawn with it.
struct ChatLine: Identifiable {
    let block: ChatBlock
    /// The first reply of a turn: shows who wrote it and when.
    var author = false
    /// The first line of a new day ("Today", "Yesterday", "Mon 18 Nov"), drawn above it.
    var day: String?
    /// The last line of a finished turn: the turn's time, length, tokens and cost, drawn below it.
    var turn: ChatTurn?
    var id: String { block.id }
    /// The line is an assistant reply (which draws its turn's line itself).
    var isReply: Bool { if case .item(let i) = block { i.kind == .assistant } else { false } }

    static func lines(_ items: [ChatItem], turns: [ChatTurn], running: Bool, now: Date = Date()) -> [ChatLine] {
        let byItem = Dictionary(turns.compactMap { t in t.item.map { ($0, t) } }, uniquingKeysWith: { _, b in b })
        var out: [ChatLine] = []
        var lastDay: DateComponents?
        var open: ChatTurn?
        func close() {
            if let t = open, !t.running, !out.isEmpty { out[out.count - 1].turn = t }
            open = nil
        }
        for block in ChatBlock.group(items) {
            var line = ChatLine(block: block)
            if case .item(let i) = block {
                if i.kind == .user || (i.kind == .choice && byItem[i.id] != nil) {
                    close()
                    open = byItem[i.id]
                }
                if i.kind == .user, let d = i.created {
                    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                    if c != lastDay {
                        line.day = Self.day(d, now: now)
                        lastDay = c
                    }
                }
                if i.kind == .assistant {
                    if case .item(let p)? = out.last?.block, p.kind == .assistant {} else { line.author = true }
                }
            }
            out.append(line)
        }
        if !running { close() }
        return out
    }

    static func day(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// "Today", centred between two hairlines.
struct ChatDayDivider: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(UI.border).frame(height: 1)
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.faint).fixedSize()
            Rectangle().fill(UI.border).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// Under a finished turn: when it ended, how long it took, the tokens it used and what it cost.
struct ChatTurnFooter: View {
    let turn: ChatTurn

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                if i > 0 { Text("·").foregroundStyle(UI.faint.opacity(0.6)) }
                Text(p)
            }
            if turn.outcome == .stopped { Text("· stopped").foregroundStyle(UI.warning) }
            if turn.outcome == .failed { Text("· failed").foregroundStyle(UI.danger) }
        }
        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(UI.faint)
        .help(details)
    }

    private var parts: [String] {
        var p: [String] = []
        if let d = turn.duration { p.append(ChatWorkGroup.duration(max(1, d))) }
        if !turn.tokens.isEmpty { p.append(Self.tokens(turn.tokens.total) + " tokens") }
        if let c = turn.cost { p.append(Self.money(c)) }
        return p
    }

    private var details: String {
        let t = turn.tokens
        var lines: [String] = []
        if let m = turn.model { lines.append("Model: \(m)") }
        if !t.isEmpty {
            lines.append(
                "Tokens: \(Self.tokens(t.input)) in, \(Self.tokens(t.output)) out, "
                    + "\(Self.tokens(t.cacheRead)) from the cache, \(Self.tokens(t.cacheWrite)) cached")
        }
        if turn.requests > 0 { lines.append("Model requests: \(turn.requests)") }
        if turn.tools > 0 { lines.append("Tool calls: \(turn.tools)") }
        if let c = turn.context { lines.append("Context: \(Self.tokens(c))" + (turn.contextWindow.map { " of \(Self.tokens($0))" } ?? "")) }
        if let c = turn.cost { lines.append("Cost: \(Self.money(c))" + (turn.backend == .api ? " (estimated from list prices)" : "")) }
        return lines.joined(separator: "\n")
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    static func money(_ v: Double) -> String { v < 0.01 ? "<$0.01" : String(format: "$%.2f", v) }
}
