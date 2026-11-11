import AppKit
import ArclightCore
import SwiftUI

/// Top-bar badge: project problems (missing fonts/assets/symbols, invalid properties, broken expressions,
/// undefined tokens). Click to list them; click a problem to jump to its scene and layer.
struct ProblemsButton: View {
    @ObservedObject var doc: EditorDocument
    @State private var problems: [Problem] = []
    @State private var open = false

    var body: some View {
        let errors = problems.filter { $0.severity == .error }.count
        Group {
            if !problems.isEmpty {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: errors > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("\(problems.count)").font(UI.monoSmall)
                    }
                    .foregroundStyle(errors > 0 ? UI.danger : UI.warning)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Capsule().fill(UI.raised)).overlay(Capsule().stroke(UI.border))
                    .barHit()
                }
                .buttonStyle(.plain).cursor(.pointingHand)
                .help("\(problems.count) problem\(problems.count == 1 ? "" : "s") in this project")
                .popover(isPresented: $open, arrowEdge: .bottom) { list }
            }
        }
        .task(id: CheckKey(scene: doc.scene.id, rev: doc.scene.rev, theme: doc.project.theme)) { await recheck() }
    }

    /// What a re-check depends on: the whole theme, since changing a token's value can add or clear a problem.
    private struct CheckKey: Equatable {
        let scene: String
        let rev: Int
        let theme: [String: JSONValue]
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Problems").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text).padding(12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(problems) { p in
                        Button {
                            jump(p)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: p.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                    .font(.system(size: 11)).foregroundStyle(
                                        p.severity == .error ? UI.danger : UI.warning
                                    ).frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(p.scene)\(p.node.map { " / " + $0 } ?? "") · \(p.kind)").font(UI.monoSmall)
                                        .foregroundStyle(UI.dim)
                                    Text(p.message).font(UI.small).foregroundStyle(UI.text).fixedSize(
                                        horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).cursor(.pointingHand)
                        Hairline()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 420).background(UI.panel)
    }

    private func jump(_ p: Problem) {
        if p.scene != doc.scene.id { doc.open(scene: p.scene) }
        if let n = p.node { doc.selection = n }
        open = false
    }

    /// Runs the doctor on a fresh store off the main thread (it compiles expressions).
    private func recheck() async {
        try? await Task.sleep(nanoseconds: 600_000_000)  // let autosave land first
        let url = doc.url
        let found: [Problem] = await Task.detached(priority: .utility) {
            guard let store = try? ProjectStore(url: url) else { return [] }
            return Doctor.check(store)
        }.value
        problems = found
    }
}
