import AppKit
import ArclightCore
import SwiftUI

/// Canvas preset cards with an aspect-ratio thumbnail.
private struct CanvasPresetGrid: View {
    let current: (Int, Int)?
    let pick: (Int, Int) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
            ForEach(EditorDocument.presets, id: \.self) { p in
                let on = current.map { $0.0 == p.w && $0.1 == p.h } ?? false
                Button {
                    pick(p.w, p.h)
                } label: {
                    VStack(spacing: 6) {
                        let scale = 44.0 / Double(max(p.w, p.h))
                        RoundedRectangle(cornerRadius: 2).stroke(on ? UI.accent : UI.dim, lineWidth: 1.5)
                            .frame(width: Double(p.w) * scale, height: Double(p.h) * scale)
                            .frame(height: 46)
                        Text(p.title).font(UI.small.weight(.medium)).foregroundStyle(UI.text).lineLimit(1)
                        Text(p.subtitle.components(separatedBy: " · ").first ?? "").font(UI.small).foregroundStyle(
                            UI.label2
                        ).lineLimit(1)
                        Text(verbatim: "\(p.w)×\(p.h)").font(UI.monoSmall).foregroundStyle(UI.dim)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? UI.selected : UI.raised))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(
                            on ? UI.accent.opacity(0.7) : UI.border, lineWidth: on ? 1.5 : 1)
                    )
                    .hitArea()
                    .animation(Motion.animation(UI.fade), value: on)
                }
                .buttonStyle(.plain).cursor(.pointingHand).help("\(p.title) · \(p.subtitle) — \(p.w)×\(p.h)")
            }
        }
    }
}

private struct SizeFields: View {
    let w: Int, h: Int
    let set: (Int, Int) -> Void
    var body: some View {
        HStack(spacing: 6) {
            TextCommitField(text: "\(w)", mono: true) { if let v = Int($0) { set(v, h) } }.frame(width: 80)
            Text("×").foregroundStyle(UI.dim)
            TextCommitField(text: "\(h)", mono: true) { if let v = Int($0) { set(w, v) } }.frame(width: 80)
            IconButton(symbol: "arrow.left.arrow.right", help: "Swap portrait / landscape") { set(h, w) }
        }
    }
}

private struct FPSPicker: View {
    let value: Double
    let set: (Double) -> Void
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditorDocument.frameRates, id: \.self) { f in
                let on = abs(value - f) < 0.001
                Button {
                    set(f)
                } label: {
                    Text(fmt(f)).font(UI.monoSmall).foregroundStyle(on ? UI.onAccent : UI.label2)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background {
                            // The highlight slides to the new rate.
                            if on {
                                RoundedRectangle(cornerRadius: 5).fill(UI.accent).matchedGeometryEffect(
                                    id: "fps", in: ns)
                            } else {
                                RoundedRectangle(cornerRadius: 5).fill(UI.raised).overlay(
                                    RoundedRectangle(cornerRadius: 5).stroke(UI.border))
                            }
                        }
                        .hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand).help("\(fmt(f)) frames per second")
            }
        }
        .animation(Motion.snappy, value: value)
    }
}

struct ProjectSettings: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let p = doc.project
        let w = p.size.first ?? 1920, h = p.size.count > 1 ? p.size[1] : 1080
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(label: "Name") { TextCommitField(text: p.name) { doc.renameProject($0) } }
            Hairline()
            SettingRow(
                label: "Canvas",
                note:
                    "Used by every scene unless a scene overrides it. Layer positions are in pixels and don't move when you change it."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    CanvasPresetGrid(current: (w, h)) { doc.setProjectCanvas(width: $0, height: $1) }
                    SizeFields(w: w, h: h) { doc.setProjectCanvas(width: $0, height: $1) }
                }
            }
            Hairline()
            SettingRow(label: "Frame rate", note: "Playback, keyframe snapping and export.") {
                FPSPicker(value: p.fps) { doc.setProjectFPS($0) }
            }
            Hairline()
            SettingRow(label: "Folder") {
                HStack {
                    Text(doc.url.tildePath).font(UI.monoSmall).foregroundStyle(UI.label2)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }.buttonStyle(
                        PillButtonStyle())
                }
            }
        }
    }
}

struct SceneSettings: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let s = doc.scene
        let pw = doc.project.size.first ?? 1920, ph = doc.project.size.count > 1 ? doc.project.size[1] : 1080
        VStack(alignment: .leading, spacing: 0) {
            Text("Scene “\(s.name ?? s.id)”").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                .padding(.bottom, 6)
            SettingRow(label: "Duration", note: "Seconds. You can also drag the END marker on the timeline ruler.") {
                TextCommitField(text: fmt(s.duration), mono: true) {
                    if let d = Double($0), d > 0 { doc.setDuration(d) }
                }.frame(width: 100)
            }
            Hairline()
            SettingRow(
                label: "Canvas", note: "Override the project canvas for this scene only (e.g. a vertical cut-down)."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Use project canvas (\(pw)×\(ph))",
                        isOn: Binding(
                            get: { s.size == nil },
                            set: { on in
                                doc.setSceneCanvas(on ? nil : [pw, ph])
                            })
                    ).toggleStyle(.checkbox).font(UI.font)
                    if let sz = s.size, sz.count == 2 {
                        CanvasPresetGrid(current: (sz[0], sz[1])) { doc.setSceneCanvas([$0, $1]) }
                        SizeFields(w: sz[0], h: sz[1]) { doc.setSceneCanvas([$0, $1]) }
                    }
                }
            }
            Hairline()
            SettingRow(label: "Frame rate") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Use project frame rate (\(fmt(doc.project.fps)) fps)",
                        isOn: Binding(
                            get: { s.fps == nil },
                            set: { on in
                                doc.setSceneFPS(on ? nil : doc.project.fps)
                            })
                    ).toggleStyle(.checkbox).font(UI.font)
                    if let f = s.fps { FPSPicker(value: f) { doc.setSceneFPS($0) } }
                }
            }
        }
    }
}
