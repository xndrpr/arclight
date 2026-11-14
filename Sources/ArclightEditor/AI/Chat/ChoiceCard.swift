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
    }

    // MARK: Tiles

    private func tile(_ o: ChatChoice.Option) -> some View {
        let on = picked.contains(o.id)
        let dimmed = answered != nil && !on
        return Button {
            guard waiting else { return }
            withMotion(Motion.snappy) {
                if on {
                    picked.removeAll { $0 == o.id }
                } else if choice.multiple {
                    picked.append(o.id)
                } else {
                    picked = [o.id]
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let v = o.visual { ChoiceVisual(doc: doc, frames: frames, visual: v, playing: answered == nil) }
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
private struct ChoiceVisual: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var frames: ChoiceFrames
    let visual: ChatChoice.Visual
    let playing: Bool
    /// Pixel width each frame is rendered at (tiles are about 150 pt wide; strips split the row).
    private let width: Double = 320

    var body: some View {
        let aspect = Self.aspect(doc)
        Group {
            if let scene = frames.scene(doc, visual.scene) {
                if visual.loop {
                    loop(scene, aspect)
                } else {
                    HStack(spacing: 3) {
                        ForEach(Array(visual.times.enumerated()), id: \.offset) { _, t in
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

/// Renders the frames choice tiles show, one at a time on the main thread (the editor's renderer), cached by
/// scene revision. Draft scenes are read straight from disk so a tile never waits for the editor's next poll.
final class ChoiceFrames: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var scenes: [String: (scene: Scene?, read: Date)] = [:]
    private var queue: [(key: String, job: () -> CGImage?)] = []
    private var running = false

    static let loopFPS: Double = 12

    /// Times of a looping tile's frames: the whole scene at `loopFPS`, at most 36 frames.
    static func loopTimes(_ s: Scene) -> [Double] {
        let d = max(0.1, s.duration)
        let n = max(2, min(36, Int((d * loopFPS).rounded())))
        return (0..<n).map { Double($0) * d / Double(n) }
    }

    func scene(_ doc: EditorDocument, _ id: String) -> Scene? {
        // Re-read at most once a second (an agent may change a draft before the user answers).
        if let c = scenes[id], Date().timeIntervalSince(c.read) < 1 { return c.scene }
        let url = doc.url.appendingPathComponent("scenes").appendingPathComponent("\(id).json")
        let s = JSONFile.read(Scene.self, from: url) ?? doc.store.scenes[id]
        // Keep the last copy after the drafts are deleted, so answered cards keep their pictures this session.
        let kept = s ?? scenes[id]?.scene
        DispatchQueue.main.async { self.scenes[id] = (kept, Date()) }
        return kept
    }

    func image(_ doc: EditorDocument, _ s: Scene, _ t: Double, _ width: Double) -> CGImage? {
        let k = "\(s.id):\(s.rev):\(Int((t * 1000).rounded())):\(Int(width))"
        if let img = images[k] { return img }
        if !queue.contains(where: { $0.key == k }) {
            queue.append((k, { [weak doc] in doc?.preview(s, time: t, width: width) }))
            DispatchQueue.main.async { self.pump() }
        }
        return nil
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.running = false
            guard !self.queue.isEmpty else { return }
            let next = self.queue.removeFirst()
            if let img = next.job() {
                if self.images.count > 600 { self.images.removeAll() }
                self.images[next.key] = img
            }
            self.pump()
        }
    }
}
