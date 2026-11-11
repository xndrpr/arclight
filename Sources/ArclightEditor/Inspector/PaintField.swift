import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// Colour or gradient. Gradients: `{"linear":[x0,y0,x1,y1] | "radial":[cx,cy,r], "stops":[[pos, colour]…]}` in
/// layer pixels from the centre, up to 4 stops.
struct PaintField: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot

    var body: some View {
        if let g = slot.shown?.object {
            GradientEditor(doc: doc, slot: slot, gradient: g)
        } else {
            HStack(spacing: 4) {
                ColorField(doc: doc, value: slot.shown?.string ?? "") { doc.write(slot, .string($0)) }
                IconButton(symbol: "circle.lefthalf.filled", help: "Use a gradient") { makeGradient() }
            }
        }
    }

    private func makeGradient() {
        let c = slot.shown?.string ?? "$fg"
        let w = doc.currentValue(slot.host, "width")?.double ?? 200
        doc.write(
            slot,
            [
                "linear": [.number(-w / 2), 0, .number(w / 2), 0],
                "stops": [[0, .string(c)], [1, .string(transparent(c))]],
            ])
    }

    private func transparent(_ c: String) -> String {
        guard let rgba = RGBA.parse(doc.renderer.evaluator.resolve(.string(c))) else { return "#FFFFFF00" }
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: 0).hex
    }
}

private struct GradientEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let gradient: [String: JSONValue]

    private var radial: Bool { gradient["radial"] != nil }
    private var stops: [(Double, String)] {
        (gradient["stops"]?.array ?? []).compactMap { s in
            guard let a = s.array, a.count >= 2, let p = a[0].double else { return nil }
            return (p, a[1].string ?? "#FFFFFF")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SegmentedChoice(value: radial ? "radial" : "linear", options: ["linear", "radial"]) {
                    setType($0 == "radial")
                }
                Button {
                    doc.write(slot, .string(stops.first?.1 ?? "$fg"))
                } label: {
                    Text("Solid").padding(.horizontal, 6).frame(height: UI.rowHeight).hitArea()
                }
                .buttonStyle(.plain).font(UI.small).foregroundStyle(UI.dim).cursor(.pointingHand).help(
                    "Back to a single colour")
            }
            preview
            geometry
            ForEach(Array(stops.enumerated()), id: \.offset) { i, s in stopRow(i, s) }
            if stops.count < 4 {
                Button {
                    addStop()
                } label: {
                    Label("Add stop", systemImage: "plus").font(UI.small).frame(height: 22).hitArea()
                }
                .buttonStyle(.plain).foregroundStyle(UI.label2).cursor(.pointingHand)
            }
        }
    }

    private var preview: some View {
        let gs = stops.map {
            Gradient.Stop(
                color: Color(arclight: doc.renderer.evaluator.resolve(.string($0.1))) ?? .clear, location: CGFloat($0.0)
            )
        }
        return ZStack {
            CheckerSwatch()
            if radial {
                RadialGradient(gradient: Gradient(stops: gs), center: .center, startRadius: 0, endRadius: 60)
            } else {
                LinearGradient(gradient: Gradient(stops: gs), startPoint: .leading, endPoint: .trailing)
            }
        }
        .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.fieldBorder))
    }

    @ViewBuilder private var geometry: some View {
        if radial {
            let r = gradient["radial"]?.doubles ?? [0, 0, 100]
            VectorFields(labels: ["cx", "cy", "r"], values: r) { i, d in setCoord("radial", r, i, d) }
        } else {
            let l = gradient["linear"]?.doubles ?? [-100, 0, 100, 0]
            VectorFields(labels: ["x0", "y0", "x1", "y1"], values: l) { i, d in setCoord("linear", l, i, d) }
            HStack(spacing: 6) {
                Text("Angle").font(UI.small).foregroundStyle(UI.label2).frame(width: 40, alignment: .leading)
                TextCommitField(text: fmt((angle(l) * 10).rounded() / 10), mono: true) { s in
                    if let a = Double(s) { setAngle(l, a) }
                }
                .frame(width: 70)
                Text("°").font(UI.monoSmall).foregroundStyle(UI.faint)
                Spacer()
            }
        }
    }

    private func stopRow(_ i: Int, _ s: (Double, String)) -> some View {
        HStack(spacing: 4) {
            TextCommitField(text: fmt(s.0), mono: true) { str in
                if let p = Double(str) { setStop(i, pos: min(max(p, 0), 1), color: nil) }
            }
            .frame(width: 46)
            ColorField(doc: doc, value: s.1) { setStop(i, pos: nil, color: $0) }
            if stops.count > 2 { IconButton(symbol: "minus", help: "Remove stop") { removeStop(i) } }
        }
    }

    // MARK: Writes

    private func write(_ g: [String: JSONValue]) { doc.write(slot, .object(g)) }

    private func stopsJSON(_ s: [(Double, String)]) -> JSONValue { .array(s.map { [.number($0.0), .string($0.1)] }) }

    private func setType(_ toRadial: Bool) {
        guard toRadial != radial else { return }
        var g = gradient
        let l = gradient["linear"]?.doubles ?? [-100, 0, 100, 0]
        let r = gradient["radial"]?.doubles ?? [0, 0, 100]
        if toRadial {
            g["linear"] = nil
            g["radial"] = [
                .number((l[0] + l[2]) / 2), .number((l[1] + l[3]) / 2),
                .number(max(1, hypot(l[2] - l[0], l[3] - l[1]) / 2)),
            ]
        } else {
            g["radial"] = nil
            g["linear"] = [.number(r[0] - r[2]), .number(r[1]), .number(r[0] + r[2]), .number(r[1])]
        }
        write(g)
    }

    private func setCoord(_ key: String, _ cur: [Double], _ i: Int, _ d: Double) {
        var a = cur; guard a.indices.contains(i) else { return }
        a[i] = d
        var g = gradient; g[key] = .array(a.map { .number($0) }); write(g)
    }

    private func angle(_ l: [Double]) -> Double { atan2(l[3] - l[1], l[2] - l[0]) * 180 / .pi }

    /// Rotates the gradient line around its centre, keeping its length.
    private func setAngle(_ l: [Double], _ deg: Double) {
        let cx = (l[0] + l[2]) / 2, cy = (l[1] + l[3]) / 2, h = hypot(l[2] - l[0], l[3] - l[1]) / 2
        let a = deg * .pi / 180
        let r = { (v: Double) in (v * 10).rounded() / 10 }
        var g = gradient
        g["linear"] = [
            .number(r(cx - cos(a) * h)), .number(r(cy - sin(a) * h)), .number(r(cx + cos(a) * h)),
            .number(r(cy + sin(a) * h)),
        ]
        write(g)
    }

    private func setStop(_ i: Int, pos: Double?, color: String?) {
        var s = stops; guard s.indices.contains(i) else { return }
        if let pos { s[i].0 = pos }
        if let color { s[i].1 = color }
        var g = gradient; g["stops"] = stopsJSON(s.sorted { $0.0 < $1.0 }); write(g)
    }

    private func addStop() {
        var s = stops
        let last = s.last ?? (1, "#FFFFFF")
        let prev = s.count > 1 ? s[s.count - 2] : (0, last.1)
        s.insert(((prev.0 + last.0) / 2, last.1), at: max(0, s.count - 1))
        var g = gradient; g["stops"] = stopsJSON(s); write(g)
    }

    private func removeStop(_ i: Int) {
        var s = stops; s.remove(at: i)
        var g = gradient; g["stops"] = stopsJSON(s); write(g)
    }
}

/// File picker that copies the chosen file into the project's assets/ folder.
struct AssetField: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let kind: String

    var body: some View {
        HStack(spacing: 4) {
            TextCommitField(text: slot.shown?.string ?? "", mono: true, placeholder: "assets/…") { s in
                doc.write(slot, s.isEmpty ? nil : .string(s))
            }
            Button("Choose…") { choose() }.buttonStyle(PillButtonStyle()).fixedSize()
        }
    }

    private func choose() {
        guard
            let url = FilePicker.files(
                kind == "image" ? [.image] : [],
                message: "Choose a file — it will be copied into the project's assets folder"
            ).first
        else { return }
        do {
            let name = try doc.store.importAsset(from: url)
            doc.write(slot, .string(name))
        } catch { doc.flash("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
