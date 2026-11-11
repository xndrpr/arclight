import ArclightCore
import SwiftUI

/// "Notes for the AI": requests the user leaves while watching, tied to the selected layer and playhead.
/// The AI agent sees open notes in `editor_state` / `note_list` and closes them with `note_resolve`.
struct NotesSection: View {
    @ObservedObject var doc: EditorDocument
    @State private var notes: [Note] = []
    @State private var draft = ""
    @State private var showResolved = false
    @AppStorage(Pref.notesCollapsed) private var collapsed = false
    @FocusState private var focused: Bool

    var body: some View {
        let open = notes.filter(\.isOpen).reversed()
        let resolved = notes.filter { !$0.isOpen }.sorted { ($0.resolvedAt ?? "") > ($1.resolvedAt ?? "") }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withMotion(Motion.snappy) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.faint)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    SmallCapsLabel("Notes for the AI")
                    if !open.isEmpty {
                        Text("\(open.count)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(UI.onAccent)
                            .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(UI.accent))
                            .contentTransition(.numericText())
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand)
            .help(collapsed ? "Show notes for the AI" : "Hide notes for the AI")
            if !collapsed {
                VStack(alignment: .leading, spacing: 6) {
                    if notes.isEmpty {
                        Text(
                            "Leave a request while you watch. It's pinned to the selected layer and the playhead; the AI agent sees it and replies when done."
                        )
                        .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    }
                    let rows = open.count + (showResolved ? resolved.count : 0)
                    if rows > 4 {
                        ScrollView { list(Array(open), resolved) }.frame(height: 210)
                    } else {
                        list(Array(open), resolved)
                    }
                    addField
                    if !resolved.isEmpty {
                        Button {
                            withMotion(Motion.snappy) { showResolved.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                                    .rotationEffect(.degrees(showResolved ? 90 : 0))
                                Text("\(resolved.count) resolved").font(UI.small)
                            }
                            .foregroundStyle(UI.dim).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).cursor(.pointingHand)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
                .transition(Motion.row)
            }
        }
        .clipped()
        .onAppear(perform: reload)
        .onChange(of: doc.activity.last?.id) { _, _ in reload() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    private func list(_ open: [Note], _ resolved: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(open) { NoteRow(doc: doc, note: $0, changed: reload).transition(Motion.row) }
            if showResolved {
                ForEach(resolved) { NoteRow(doc: doc, note: $0, changed: reload).transition(Motion.row) }
            }
        }
    }

    private var target: String {
        var parts: [String] = []
        if let s = doc.selection { parts.append(s) }
        parts.append(String(format: "%gs", (doc.time * 100).rounded() / 100))
        return parts.joined(separator: " @ ")
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                FieldBox {
                    TextField("Ask the AI to change something…", text: $draft, axis: .vertical)
                        .font(UI.small).lineLimit(1...4).focused($focused)
                        .onSubmit(add)
                }
                IconButton(symbol: "arrow.up", help: "Add note (↩)") { add() }.disabled(
                    draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("attaches " + target).font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let n = Note(text: t, scene: doc.scene.id, layer: doc.selection, time: (doc.time * 1000).rounded() / 1000)
        do { try Notes.add(n, project: doc.url); draft = ""; reload() } catch {
            doc.flash("Could not save note: \(error)")
        }
    }

    private func reload() {
        let n = Notes.load(project: doc.url)
        guard n != notes else { return }
        // Added / resolved / AI replies animate in, except during playback.
        if doc.playing { notes = n } else { withMotion(Motion.snappy) { notes = n } }
    }
}

private struct NoteRow: View {
    @ObservedObject var doc: EditorDocument
    let note: Note
    let changed: () -> Void
    @State private var hover = false

    var body: some View {
        let n = note
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: n.isOpen ? "circle" : "checkmark.circle.fill").font(.system(size: 10))
                .foregroundStyle(n.isOpen ? UI.dim : UI.faint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.text).font(UI.small).foregroundStyle(n.isOpen ? UI.text : UI.dim).fixedSize(
                    horizontal: false, vertical: true)
                Button {
                    doc.reveal(scene: n.scene, layer: n.layer, time: n.time)
                } label: {
                    Text(targetLabel).font(UI.monoSmall).foregroundStyle(hover ? UI.label2 : UI.faint).lineLimit(1)
                        .hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand).help("Go to this layer and time")
                if let r = n.reply {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "sparkle").font(.system(size: 8)).foregroundStyle(UI.ai)
                        Text(r).font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(n.isOpen ? UI.raised : .clear))
        // Floats over the top-right corner instead of joining the layout: showing it never resizes the row or
        // re-wraps the text (which moved the row under the pointer and flickered).
        .overlay(alignment: .topTrailing) { actions(n) }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(n.isOpen ? UI.border : UI.border.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withMotion(UI.fade) { hover = h } }
    }

    private func actions(_ n: Note) -> some View {
        HStack(spacing: 0) {
            if n.isOpen {
                IconButton(symbol: "checkmark", help: "Mark resolved") {
                    update { _ = try? Notes.resolve(n.id, project: doc.url) }
                }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Reopen") {
                    update { _ = try? Notes.reopen(n.id, project: doc.url) }
                }
            }
            IconButton(symbol: "trash", help: "Delete note") { update { try? Notes.delete(n.id, project: doc.url) } }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(n.isOpen ? UI.raised : UI.panel))
        .padding(3)
        .opacity(hover ? 1 : 0)
        .allowsHitTesting(hover)
    }

    /// Resolve / reopen / delete: the list re-sorts with a short animation instead of jumping.
    private func update(_ change: () -> Void) {
        change()
        withMotion(Motion.snappy) { changed() }
    }

    private var targetLabel: String {
        var s = note.scene == doc.scene.id ? "" : note.scene + " · "
        s += note.layer ?? "canvas"
        if let t = note.time { s += String(format: " @ %gs", (t * 100).rounded() / 100) }
        return s
    }
}
