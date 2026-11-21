import ArclightCore
import SwiftUI

/// The options of a choice card, large: one at a time on a dark stage, with a filmstrip of all of them below.
/// ← → flip between options (and storyboard beats), Space picks, Return goes with the pick, Esc closes.
struct ChoiceViewer: View {
    let doc: EditorDocument
    let chat: ChatController
    @ObservedObject var frames: ChoiceFrames
    let choice: ChatChoice
    @Binding var picked: [String]
    @Binding var comment: String
    let waiting: Bool
    @State var index: Int
    let toggle: (String) -> Void
    let confirm: () -> Void
    @State private var beat = 0
    @FocusState private var stageFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var options: [ChatChoice.Option] { choice.options }
    private var current: ChatChoice.Option? { options.indices.contains(index) ? options[index] : nil }
    private var beats: [Double] { current?.visual?.times ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(UI.border)
            stage.focusable().focusEffectDisabled().focused($stageFocused)
                .onKeyPress(.leftArrow) {
                    step(-1); return .handled
                }
                .onKeyPress(.rightArrow) {
                    step(1); return .handled
                }
                .onKeyPress(.space) {
                    if let c = current { toggle(c.id) }
                    return .handled
                }
                .onKeyPress(.return) {
                    if canConfirm { confirm() }
                    return .handled
                }
            info
            Divider().overlay(UI.border)
            footer
        }
        .frame(minWidth: 880, idealWidth: 1180, minHeight: 640, idealHeight: 820)
        .background(UI.panel)
        .onAppear { stageFocused = true }
        .onChange(of: index) { _, _ in beat = 0 }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ChoiceCard.symbol(choice.stage)).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UI.ai)
            SmallCapsLabel(choice.stage.label, color: UI.ai)
            Text(choice.question).font(.system(size: 14, weight: .medium)).foregroundStyle(UI.text).lineLimit(1)
            Spacer(minLength: 8)
            if options.count > 1 {
                Text("\(index + 1) of \(options.count)").font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var stage: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", -1)
            ZStack {
                if let v = current?.visual {
                    ChoiceVisual(
                        doc: doc, frames: frames, visual: v, playing: true, width: v.loop ? 960 : 1600,
                        times: beats.count > 1 ? [beats[min(beat, beats.count - 1)]] : nil
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .id("\(index):\(beat)")
                    .transition(.opacity)
                } else if let c = current {
                    Text(c.title).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            arrow("chevron.right", 1)
        }
        .background(Color(white: 0.07))
        .overlay(alignment: .bottom) { if beats.count > 1 { beatStrip } }
    }

    private func arrow(_ symbol: String, _ d: Int) -> some View {
        let enabled = beats.count > 1 || options.count > 1
        return Button {
            step(d)
        } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 44, height: 80).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0).disabled(!enabled).cursor(.pointingHand)
    }

    /// Storyboard beats: small frames along the bottom of the stage.
    private var beatStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(beats.enumerated()), id: \.offset) { i, t in
                if let v = current?.visual {
                    Button {
                        withMotion(UI.fade) { beat = i }
                    } label: {
                        ChoiceVisual(doc: doc, frames: frames, visual: v, playing: false, width: 320, times: [t])
                            .frame(width: 96)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == beat ? UI.ai : .clear, lineWidth: 2))
                            .opacity(i == beat ? 1 : 0.6)
                    }
                    .buttonStyle(.plain).cursor(.pointingHand).help("Beat \(i + 1)")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5)))
        .padding(.bottom, 12)
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 12) {
            if let c = current {
                Text(c.id).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(UI.ai)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(UI.ai.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                    if let n = c.note, !n.isEmpty {
                        Text(n).font(UI.font).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
                    }
                    if beats.count > 1 {
                        Text("Beat \(beat + 1) of \(beats.count)").font(UI.small).foregroundStyle(UI.faint)
                    }
                }
                Spacer(minLength: 8)
                if waiting {
                    let on = picked.contains(c.id)
                    Button {
                        toggle(c.id)
                    } label: {
                        Label(on ? "Picked" : "Pick \(c.id)", systemImage: on ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(PillButtonStyle(primary: on))
                    .help("Space")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, o in thumb(i, o) }
                }
                .padding(.vertical, 2)
            }
            if waiting {
                TextField("Comment (optional)", text: $comment, axis: .vertical)
                    .textFieldStyle(.plain).font(UI.small).lineLimit(1...3)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
                    .frame(width: 240)
                Button(goTitle, action: confirm).buttonStyle(PillButtonStyle(primary: true))
                    .disabled(!canConfirm || chat.running)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func thumb(_ i: Int, _ o: ChatChoice.Option) -> some View {
        let on = picked.contains(o.id)
        return Button {
            withMotion(UI.fade) { index = i }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let v = o.visual {
                    ChoiceVisual(
                        doc: doc, frames: frames, visual: v, playing: false, width: 320, times: [v.times.first ?? 0])
                }
                HStack(spacing: 4) {
                    Text(o.id).font(UI.monoSmall).foregroundStyle(on ? UI.ai : UI.faint)
                    Text(o.title).font(UI.small).foregroundStyle(UI.text).lineLimit(1)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.ai)
                    }
                }
            }
            .frame(width: 120)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? UI.selected : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 7).stroke(on ? UI.ai : (i == index ? UI.border : .clear), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }

    // MARK: Actions

    /// Through the storyboard's beats first, then to the next option.
    private func step(_ d: Int) {
        withMotion(UI.fade) {
            if beats.count > 1, beats.indices.contains(beat + d) {
                beat += d
            } else if options.count > 1 {
                index = (index + d + options.count) % options.count
            }
        }
    }

    private var canConfirm: Bool {
        waiting && (!picked.isEmpty || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var goTitle: String {
        if picked.count == 1 { return "Go with \(picked[0])" }
        return picked.isEmpty ? "Send comment" : "Go with these"
    }
}
