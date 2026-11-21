import AppKit
import ArclightCore
import SwiftUI

/// The prompt field the AI bar shows.
enum AIPromptKind: String { case generate, fill, expand }

/// AI pixel tools in the editor. Network and Vision work runs off the main thread; results land as one undoable
/// edit of the working copy (the new picture stays in assets/, so undo just points the layer back).
extension EditorDocument {
    /// fal.ai when the user enabled it and saved a key.
    var falProvider: ImageProvider? { ImageSettings.enabled ? KeychainStore.falProvider() : nil }
    /// Cheap enough for every redraw: no provider is built.
    var hasFal: Bool { ImageSettings.enabled && KeychainStore.falKey() != nil }

    var selectedImageLayer: String? {
        guard let id = selection, scene.node(id)?.type == "image" else { return nil }
        return id
    }

    /// Runs an AI operation with a busy label, then applies its ops (and selects the result's layer).
    func runImageAI(
        _ label: String, _ work: @escaping @Sendable (Scene, Project, ProjectStore) async throws -> ImageAI.Result
    ) {
        guard busy == nil else { flash("Still working on the last one…"); return }
        saveNow()
        let s = scene, p = project, st = store
        busy = label
        Task.detached {
            do {
                let r = try await work(s, p, st)
                await MainActor.run {
                    self.busy = nil
                    self.libraryVersion += 1  // a new asset
                    guard !r.ops.isEmpty else { self.flash("Saved \(r.asset) to assets"); return }
                    self.apply(r.ops)
                    if !r.layer.isEmpty { self.selection = r.layer }
                    self.saveNow()
                    self.flash(r.summary.prefix(1).uppercased() + r.summary.dropFirst())
                }
            } catch {
                await MainActor.run {
                    self.busy = nil; self.flash("\(error)")
                }
            }
        }
    }

    func removeBackground() {
        guard let id = selectedImageLayer else { flash("Select an image layer first"); return }
        runImageAI("Removing background…") { s, _, st in
            try await ImageAI.removeBackground(layer: id, in: s, store: st, engine: .local)
        }
    }

    /// Sets the marquee to the subject of the selected picture (on-device).
    func selectSubject() {
        guard let id = selectedImageLayer else { flash("Select an image layer first"); return }
        do {
            if let r = try ImageAI.subjectRect(layer: id, in: scene, store: store, nodes: evaluate(at: 0)) {
                marquee = r.integral; aiPrompt = .fill
            } else {
                flash("No subject found in that picture")
            }
        } catch { flash("\(error)") }
    }

    func upscaleSelection(factor: Int = 2) {
        guard let id = selectedImageLayer else { flash("Select an image layer first"); return }
        guard let fal = falProvider else { needKey(); return }
        runImageAI("Upscaling ×\(factor)…") { s, _, st in
            try await ImageAI.upscale(layer: id, in: s, store: st, factor: factor, provider: fal)
        }
    }

    /// Expands the selected picture to fill the open artboard's aspect (or by `by` px per side).
    func expandSelection(prompt: String) {
        guard let id = selectedImageLayer else { flash("Select an image layer first"); return }
        guard let fal = falProvider else { needKey(); return }
        let (l, t, r, b) = expandSides(id)
        guard l + t + r + b > 0 else { flash("The picture already has the canvas's shape"); return }
        runImageAI("Expanding…") { s, _, st in
            try await ImageAI.expand(
                layer: id, in: s, store: st, left: l, top: t, right: r, bottom: b, prompt: prompt, provider: fal)
        }
    }

    /// Picture pixels to add so the picture gets the canvas's aspect ratio (split evenly between the sides).
    func expandSides(_ id: String) -> (Int, Int, Int, Int) {
        guard let n = scene.node(id), case .value(let v)? = n.props["src"], let src = v.string,
            let img = try? ImageData.load(AssetPath.url(src, assets: assets))
        else { return (0, 0, 0, 0) }
        let target = canvasSize.width / max(canvasSize.height, 1)
        let w = CGFloat(img.width), h = CGFloat(img.height)
        if w / h < target - 0.01 {
            let add = Int((h * target - w).rounded()); return (add / 2, 0, add - add / 2, 0)
        } else if w / h > target + 0.01 {
            let add = Int((w / target - h).rounded()); return (0, add / 2, 0, add - add / 2)
        }
        return (0, 0, 0, 0)
    }

    func generativeFill(prompt: String) {
        guard let rect = marquee else { flash("Draw a marquee first (M)"); return }
        guard let fal = falProvider else { needKey(); return }
        let r = renderer, above = selection
        runImageAI("Generative fill…") { s, p, st in
            try await ImageAI.fill(
                rect: rect, prompt: prompt, in: s, project: p, store: st, renderer: r, provider: fal, above: above)
        }
        marquee = nil
    }

    func generateImage(prompt: String) {
        guard let fal = falProvider else { needKey(); return }
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        runImageAI("Generating…") { s, p, st in
            try await ImageAI.generate(
                prompt: prompt, width: w, height: h, in: s, project: p, store: st, provider: fal, place: true)
        }
    }

    func needKey() {
        flash("Image generation needs a fal.ai key — Settings ▸ AI ▸ Image generation")
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
    }
}

/// Floating bar at the bottom of the Thumbnail canvas: AI actions for the selection (Photoshop's contextual task bar).
struct AIContextBar: View {
    let doc: EditorDocument
    @State private var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(UI.accent)
            if let kind = doc.aiPrompt {
                TextField(placeholder(kind), text: $prompt)
                    .textFieldStyle(.plain).font(UI.font).frame(minWidth: 220, idealWidth: 320, maxWidth: 380)
                    .focused($focused)
                    .onSubmit { submit(kind) }
                    .onAppear { focused = true }
                if kind == .generate { ImageModelPicker() }
                let empty = kind != .expand && prompt.trimmingCharacters(in: .whitespaces).isEmpty
                Button {
                    submit(kind)
                } label: {
                    Text(kind == .fill ? "Fill" : kind == .expand ? "Expand" : "Generate")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.onAccent)
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(Capsule().fill(UI.accent))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain).cursor(.pointingHand).disabled(empty).opacity(empty ? 0.45 : 1)
                .animation(UI.fade, value: empty)
                .help("Run it (Return)")
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(UI.dim).help("Close (Esc)")
            } else {
                if doc.selectedImageLayer != nil {
                    action("Remove background", "person.crop.rectangle", "⌥⌘B") { doc.removeBackground() }
                    action("Select subject", "viewfinder", "W") { doc.selectSubject() }
                    action("Expand", "arrow.up.left.and.arrow.down.right", nil, fal: true) { doc.aiPrompt = .expand }
                    action("Upscale ×2", "plus.magnifyingglass", nil, fal: true) { doc.upscaleSelection() }
                    Hairline(vertical: true).frame(height: 16)
                }
                if doc.marquee != nil {
                    action("Generative fill", "wand.and.stars", "⇧⌘F", fal: true) { doc.aiPrompt = .fill }
                }
                action("Generate image", "photo.badge.plus", "⌘K", fal: true) { doc.aiPrompt = .generate }
            }
            if let b = doc.busy {
                ProgressView().controlSize(.small).scaleEffect(0.6); Text(b).font(UI.small).foregroundStyle(UI.dim)
            }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Capsule().fill(UI.panel.opacity(0.97)))
        .overlay(Capsule().stroke(UI.border))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .onChange(of: doc.aiPrompt) { _, k in if k != nil { focused = true } }
        .onExitCommand { close() }
    }

    private func placeholder(_ k: AIPromptKind) -> String {
        switch k {
        case .generate: "Describe a picture to add (no text — use text layers)…"
        case .fill: "What should be in the selection? (empty area: “remove it”)…"
        case .expand: "Optional: what the extended area shows…"
        }
    }

    private func submit(_ k: AIPromptKind) {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        switch k {
        case .generate: doc.generateImage(prompt: p)
        case .fill: doc.generativeFill(prompt: p)
        case .expand: doc.expandSelection(prompt: p)
        }
        close()
    }

    private func close() { prompt = ""; doc.aiPrompt = nil; focused = false }

    private func action(
        _ title: String, _ symbol: String, _ key: String?, fal: Bool = false, _ run: @escaping () -> Void
    ) -> some View {
        let locked = fal && !doc.hasFal
        return Button(action: { locked ? doc.needKey() : run() }) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(UI.small)
                if locked { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(UI.faint) }
            }
            .foregroundStyle(locked ? UI.dim : UI.text).padding(.horizontal, 7).frame(height: 26).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand).disabled(doc.busy != nil)
        .help(title + (key.map { " (\($0))" } ?? "") + (locked ? " — needs a fal.ai key (Settings ▸ AI)" : ""))
    }
}

/// The marquee selection over the open canvas: marching-ants rectangle.
struct MarqueeOverlay: View {
    let rect: CGRect
    let scale: CGFloat
    @State private var phase: CGFloat = 0

    var body: some View {
        let r = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        ZStack {
            Path(r).stroke(Color.black, style: StrokeStyle(lineWidth: 1))
            Path(r).stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase))
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { phase = 8 } }
    }
}

/// The image model for Generate, from the same catalog as Settings ▸ AI (Auto picks one per request).
struct ImageModelPicker: View {
    @State private var models = ImageSettings.models
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 10))
                Text(name(models.generate)).font(UI.small).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(hover || open ? UI.text : UI.dim)
            .padding(.horizontal, 7).frame(height: 24)
            .background(Capsule().fill(hover || open ? UI.hover : UI.raised))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain).cursor(.pointingHand).onHover { hover = $0 }
        .animation(Motion.snappy, value: open)
        .help("Image model (price per picture)")
        .popover(isPresented: $open, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(ModelCatalog.auto, "Auto", "The best model for each picture")
                    ForEach(ModelCatalog.images) { e in
                        row(e.id, e.label, "\(e.priceNote) · \(e.bestFor)" + (e.expensive ? " · expensive" : ""))
                    }
                }
                .padding(8)
            }
            .frame(width: 340).frame(maxHeight: 380)
        }
        .onAppear { models = ImageSettings.models }
    }

    private func name(_ id: String) -> String {
        id == ModelCatalog.auto ? "Auto" : ModelCatalog.entry(id)?.label ?? id
    }

    private func row(_ id: String, _ title: String, _ detail: String) -> some View {
        let on = models.generate == id
        return Button {
            models.generate = id
            ImageSettings.models = models
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                    .foregroundStyle(on ? UI.accent : UI.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(UI.font.weight(on ? .semibold : .regular)).foregroundStyle(UI.text)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(UI.dim).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}
