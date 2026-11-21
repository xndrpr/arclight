import ArclightCore
import SwiftUI

/// The chat header's usage button: a ring for the limit that matters now (the plan's 5-hour or weekly window, or how
/// full the context is when no limit has been reported), opening into every limit with when it resets, the context,
/// and what this chat has used.
struct ChatUsageButton: View {
    let chat: ChatController
    let chats: ChatStore
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let limits = chats.limits
        let headline = limits?.headline
        let context = chat.transcript.context
        if limits != nil || context != nil || !chat.transcript.totalTokens.isEmpty {
            let fraction = headline.flatMap(Self.used) ?? context?.fraction ?? 0
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 5) {
                    UsageRing(fraction: fraction, tint: Self.tint(fraction, headline?.status ?? limits?.status))
                        .frame(width: 13, height: 13)
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(hover || open ? UI.text : UI.dim)
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover || open ? UI.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand).onHover { hover = $0 }
            .help(headline.map { "\($0.label): \(Int(((Self.used($0) ?? 0) * 100).rounded()))% used" } ?? "Usage")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ChatUsagePopover(chat: chat, limits: limits).frame(width: 290)
            }
        }
    }

    static func used(_ w: ChatLimits.Window) -> Double? {
        if let u = w.used { return u }
        guard let l = w.limit, let r = w.remaining, l > 0 else { return nil }
        return 1 - Double(r) / Double(l)
    }

    static func tint(_ fraction: Double, _ status: ChatLimits.Status?) -> Color {
        if status == .rejected || fraction >= 0.95 { return UI.danger }
        if status == .warning || fraction >= 0.8 { return UI.warning }
        return UI.accent
    }
}

/// A thin progress ring.
struct UsageRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(UI.border, lineWidth: 2.2)
            Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
    }
}

private struct ChatUsagePopover: View {
    let chat: ChatController
    let limits: ChatLimits?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let l = limits, !l.windows.isEmpty {
                section(l.source == .cli ? "Plan limits" : "Rate limits") {
                    ForEach(l.windows) { w in bar(w.label, ChatUsageButton.used(w), detail: resets(w), status: w.status) }
                    if l.usingOverage == true {
                        Label("Using extra usage", systemImage: "creditcard").font(UI.small).foregroundStyle(UI.warning)
                    }
                }
            }
            if let c = chat.transcript.context {
                section("Context") {
                    bar(
                        "\(ChatTurnFooter.tokens(c.used))" + (c.window.map { " of \(ChatTurnFooter.tokens($0))" } ?? ""),
                        c.fraction, detail: c.model, status: nil)
                }
            }
            let t = chat.transcript.totalTokens
            if !t.isEmpty {
                section("This chat") {
                    row("Tokens", ChatTurnFooter.tokens(t.total))
                    row("Read · written", "\(ChatTurnFooter.tokens(t.prompt)) · \(ChatTurnFooter.tokens(t.output))")
                    if let c = chat.transcript.totalCost { row("Cost", ChatTurnFooter.money(c)) }
                    row("Turns", "\(chat.transcript.turns.count)")
                }
            }
            if limits == nil {
                Text("Limits show up after the next reply, when the provider reports them.")
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(UI.panel)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(UI.faint)
            content()
        }
    }

    private func bar(_ title: String, _ used: Double?, detail: String?, status: ChatLimits.Status?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(UI.small).foregroundStyle(UI.text)
                Spacer()
                if let u = used { Text("\(Int((u * 100).rounded()))%").font(UI.monoSmall).foregroundStyle(UI.label2) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(UI.raised)
                    Capsule().fill(ChatUsageButton.tint(used ?? 0, status))
                        .frame(width: g.size.width * max(0.01, min(1, used ?? 0)))
                }
            }
            .frame(height: 5)
            if let d = detail { Text(d).font(.system(size: 10.5)).foregroundStyle(UI.faint) }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(UI.small).foregroundStyle(UI.dim)
            Spacer()
            Text(v).font(UI.monoSmall).foregroundStyle(UI.text)
        }
    }

    private func resets(_ w: ChatLimits.Window) -> String? {
        guard let r = w.resets else { return nil }
        let s = r.timeIntervalSinceNow
        if s <= 0 { return "Resets now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        let when = h >= 24 ? r.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : nil
        return "Resets " + (when.map { "on \($0)" } ?? (h > 0 ? "in \(h)h \(m)m" : "in \(max(1, m))m"))
    }
}
