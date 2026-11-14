import ArclightCore
import SwiftUI

/// A direction stage the AI asks about (brief, look, storyboard, motion): the options as tiles drawn from the
/// draft scenes, a comment field and one button. Once answered it shows what was picked and stays read-only.
struct ChoiceCard: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var chat: ChatController
    let choice: ChatChoice
    @StateObject private var frames = ChoiceFrames()
    @State private var picked: [String] = []
    @State private var comment = ""
    /// The option open in the large viewer.
    @State private var viewing: Int?

    private var answered: ChatChoice.Answer? { choice.answer }
    private var waiting: Bool { answered == nil && chat.transcript.pendingChoice?.id == choice.id }
    /// A storyboard strip needs the whole width; stills and loops sit two to a row.
    private var wide: Bool {
        choice.options.contains { ($0.visual?.times.count ?? 0) > 1 } || choice.options.count == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(choice.stage)).font(.system(size: 9.5, weight: .semibold))
                SmallCapsLabel(choice.stage.label, color: UI.ai)
                Spacer(minLength: 0)
                if let answered, answered.typed { Text("answered below").font(UI.small).foregroundStyle(UI.faint) }
                if hasVisuals {
                    Button {
                        viewing = max(0, choice.options.firstIndex { picked.contains($0.id) } ?? 0)
                    } label: {
                        Label("View large", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(UI.small.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(UI.ai).cursor(.pointingHand)
                    .help("Open the options large and compare them (← → to flip)")
                }
            }
            .foregroundStyle(UI.ai)
            Text(choice.question).font(UI.font.weight(.medium)).foregroundStyle(UI.text)
                .fixedSize(horizontal: false, vertical: true)
            if let body = choice.body, !body.isEmpty {
                Text(ChatRow.markdown(body)).font(UI.small).foregroundStyle(UI.label2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !choice.options.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: wide ? 1 : 2),
                    spacing: 8
                ) {
                    ForEach(choice.options) { tile($0) }
                }
            }
            if let answered { summary(answered) } else if waiting { controls }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(UI.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(waiting ? UI.ai.opacity(0.45) : UI.border))
        .onAppear { picked = answered?.picked ?? [] }
        .sheet(
            isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })
        ) {
            ChoiceViewer(
                doc: doc, chat: chat, frames: frames, choice: choice, picked: $picked, comment: $comment,
                waiting: waiting, index: viewing ?? 0, toggle: toggle, confirm: confirm)
        }
    }

    private var hasVisuals: Bool { choice.options.contains { $0.visual != nil } }

    private func toggle(_ id: String) {
        guard waiting else { return }
        withMotion(Motion.snappy) {
            if picked.contains(id) {
                picked.removeAll { $0 == id }
            } else if choice.multiple {
                picked.append(id)
            } else {
                picked = [id]
            }
        }
    }

    // MARK: Tiles

    private func tile(_ o: ChatChoice.Option) -> some View {
        let on = picked.contains(o.id)
        let dimmed = answered != nil && !on
        return Button {
            toggle(o.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let v = o.visual {
                    ChoiceVisual(doc: doc, frames: frames, visual: v, playing: answered == nil)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                viewing = choice.options.firstIndex(of: o)
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain).padding(5).cursor(.pointingHand).help("View large")
                        }
                }
                HStack(spacing: 5) {
                    Text(o.id).font(UI.monoSmall).foregroundStyle(on ? UI.ai : UI.faint)
                    Text(o.title).font(UI.small.weight(.semibold)).foregroundStyle(UI.text).lineLimit(1)
                }
                if let n = o.note, !n.isEmpty {
                    Text(n).font(UI.small).foregroundStyle(UI.dim).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? UI.ai.opacity(0.10) : UI.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? UI.ai : UI.border, lineWidth: on ? 1.5 : 1))
            .opacity(dimmed ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(waiting ? .pointingHand : .arrow)
        .help(waiting ? "Pick \(o.title)" : o.title)
    }

    // MARK: Answer

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(
                choice.options.isEmpty ? "What should change? (optional)" : "Add a comment (optional)", text: $comment,
                axis: .vertical
            )
            .textFieldStyle(.plain).font(UI.small).lineLimit(1...4)
            .onSubmit(confirm)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
            HStack {
                Spacer()
                Button(buttonTitle, action: confirm).buttonStyle(PillButtonStyle(primary: true))
                    .disabled(!canConfirm || chat.running)
            }
        }
    }

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canConfirm: Bool { choice.options.isEmpty || !picked.isEmpty || !trimmed.isEmpty }

    private var buttonTitle: String {
        if choice.options.isEmpty { return trimmed.isEmpty ? "Looks right" : "Send changes" }
        if picked.isEmpty { return trimmed.isEmpty ? (choice.multiple ? "Pick options" : "Pick one") : "Send comment" }
        if picked.count == 1, let o = choice.options.first(where: { $0.id == picked[0] }) { return "Go with \(o.id)" }
        return "Go with these"
    }

    private func confirm() {
        guard canConfirm, waiting else { return }
        viewing = nil
        chat.answer(choice, picked: picked, comment: trimmed)
    }

    private func summary(_ a: ChatChoice.Answer) -> some View {
        let names = a.picked.compactMap { id in choice.options.first { $0.id == id }.map { "\($0.id) · \($0.title)" } }
        let line: String
        if a.typed {
            line = "You answered in the chat."
        } else if choice.options.isEmpty {
            line = a.comment.isEmpty ? "You confirmed it." : "You asked for changes: \(a.comment)"
        } else {
            line =
                (names.isEmpty ? "No pick." : "You picked \(names.joined(separator: ", ")).")
                + (a.comment.isEmpty ? "" : " “\(a.comment)”")
        }
        return HStack(alignment: .top, spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.success)
                .padding(.top, 2)
            Text(line).font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func symbol(_ s: ChatChoice.Stage) -> String {
        switch s {
        case .brief: return "text.alignleft"
        case .look: return "paintpalette"
        case .storyboard: return "rectangle.split.3x1"
        case .motion: return "wind"
        }
    }
}

/// A tile's picture: one still, a strip of stills, or the scene playing on a loop.
struct ChoiceVisual: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var frames: ChoiceFrames
    let visual: ChatChoice.Visual
    let playing: Bool
    /// Pixel width each frame is rendered at (tiles are about 150 pt wide; strips split the row; the viewer is large).
    var width: Double = 320
    /// Show only these times instead of the visual's own (the viewer's current storyboard beat).
    var times: [Double]?

    var body: some View {
        let aspect = Self.aspect(doc)
        Group {
            if let scene = frames.scene(doc, visual.scene) {
                if visual.loop {
                    loop(scene, aspect)
                } else {
                    HStack(spacing: 3) {
                        ForEach(Array((times ?? visual.times).enumerated()), id: \.offset) { _, t in
                            frame(frames.image(doc, scene, t, width), aspect)
                        }
                    }
                }
            } else {
                placeholder("Draft no longer exists", aspect)
            }
        }
    }

    private func loop(_ scene: Scene, _ aspect: Double) -> some View {
        let times = ChoiceFrames.loopTimes(scene)
        return SwiftUI.TimelineView(.animation(minimumInterval: 1 / ChoiceFrames.loopFPS, paused: !playing)) { ctx in
            let i =
                playing
                ? Int(ctx.date.timeIntervalSinceReferenceDate * ChoiceFrames.loopFPS) % times.count : times.count / 2
            // Every frame is asked for up front so the loop fills in while it plays.
            let imgs = times.map { frames.image(doc, scene, $0, width) }
            frame(imgs[i] ?? imgs.compactMap { $0 }.first, aspect)
        }
    }

    private func frame(_ img: CGImage?, _ aspect: Double) -> some View {
        ZStack {
            Checker().opacity(0.5)
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func placeholder(_ s: String, _ aspect: Double) -> some View {
        Text(s).font(UI.small).foregroundStyle(UI.faint)
            .frame(maxWidth: .infinity).aspectRatio(aspect, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 4).fill(UI.field))
    }

    static func aspect(_ doc: EditorDocument) -> Double {
        let s = doc.project.size
        return s.count == 2 && s[1] > 0 ? Double(s[0]) / Double(s[1]) : 16 / 9
    }
}
