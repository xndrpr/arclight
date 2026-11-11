import AppKit
import ArclightCore
import SwiftUI

/// Theme popover: preset grid, the token editor and "Save as preset…".
struct ThemePopover: View {
    @ObservedObject var doc: EditorDocument
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: "Presets")
                    ThemePresetGrid(doc: doc).padding(.horizontal, UI.inset - 3).padding(.bottom, 12)
                    Hairline()
                    SectionTitle(title: "Tokens")
                    ThemeTokenList(doc: doc).padding(.horizontal, UI.inset).padding(.bottom, 12)
                }
            }
            .frame(maxHeight: 520)
            Hairline()
            SavePresetBar(doc: doc).padding(.horizontal, UI.inset).padding(.vertical, 10)
        }
        .frame(width: 344)
        .background(UI.panel)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 4)
        .onAppear { withAnimation(reduceMotion ? nil : UI.snappy) { appeared = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project theme").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                Text("Colours and fonts shared by every scene").font(UI.small).foregroundStyle(UI.dim)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.uturn.backward", help: "Undo the last theme change") {
                withAnimation(UI.fade) { _ = doc.undoTheme() }
            }
            .disabled(!doc.canUndoTheme).opacity(doc.canUndoTheme ? 1 : 0.35)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo") { withAnimation(UI.fade) { _ = doc.redoTheme() } }
                .disabled(!doc.canRedoTheme).opacity(doc.canRedoTheme ? 1 : 0.35)
        }
        .padding(.leading, UI.inset).padding(.trailing, UI.inset - 4).padding(.vertical, 10)
    }
}

/// Every preset as a small preview tile (background, text in the display font, accent); click applies.
private struct ThemePresetGrid: View {
    @ObservedObject var doc: EditorDocument
    @State private var presets = ThemePresets.all()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = doc.currentThemePreset?.id
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(presets) { p in
                ThemePresetTile(preset: p, selected: p.id == current) {
                    withAnimation(reduceMotion ? nil : UI.fade) { doc.applyThemePreset(p) }
                } delete: {
                    delete(p)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .themePresetsChanged)) { _ in presets = ThemePresets.all()
        }
    }

    private func delete(_ p: ThemePreset) {
        do {
            try ThemePresets.delete(p.id); NotificationCenter.default.post(name: .themePresetsChanged, object: nil)
        } catch { doc.flash("\(error)") }
    }
}

private struct ThemePresetTile: View {
    let preset: ThemePreset
    let selected: Bool
    let apply: () -> Void
    let delete: () -> Void
    @State private var hover = false

    private func c(_ k: String) -> Color { Color(arclight: preset.tokens[k]) ?? .clear }

    var body: some View {
        Button(action: apply) {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(c("bg"))
                    Text("45%").font(
                        .custom(preset.tokens["display"]?.string ?? "HelveticaNeue-CondensedBlack", size: 19)
                    )
                    .foregroundStyle(c("fg")).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 3) {
                        Capsule().fill(c("accent")).frame(width: 14, height: 3)
                        Capsule().fill(c("muted")).frame(width: 8, height: 3)
                    }
                    .padding(6)
                }
                .frame(height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(
                        selected ? UI.accent : UI.fieldBorder, lineWidth: selected ? 2 : 1))
                HStack(spacing: 3) {
                    Text(preset.name).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected || hover ? UI.text : UI.label2).lineLimit(1)
                    if !preset.isBuiltIn {
                        Image(systemName: "person.fill").font(.system(size: 7.5)).foregroundStyle(UI.faint)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UI.hover : .clear))
            .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
        .help((preset.description ?? preset.name) + (preset.isBuiltIn ? "" : "\nYour preset — right-click to delete"))
        .contextMenu {
            Button("Apply \(preset.name)", action: apply)
            if !preset.isBuiltIn { Button("Delete preset", role: .destructive, action: delete) }
        }
        .accessibilityLabel("Theme preset \(preset.name)" + (selected ? ", current" : ""))
    }
}

/// "Save as preset…": expands into a name field and saves the current tokens to the user library.
private struct SavePresetBar: View {
    @ObservedObject var doc: EditorDocument
    @State private var naming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if naming {
                FieldBox { TextField("Preset name", text: $name).focused($focused).onSubmit(save) }
                    .frame(maxWidth: .infinity)
                Button("Cancel") { withAnimation(UI.fade) { naming = false } }.buttonStyle(PillButtonStyle())
                    .fixedSize()
                Button("Save", action: save).buttonStyle(PillButtonStyle(primary: true)).fixedSize()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).opacity(
                        name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            } else {
                Text("Saved presets are available in every project.").font(UI.small).foregroundStyle(UI.faint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Save as preset…") {
                    name = doc.currentThemePreset.map { $0.isBuiltIn ? "" : $0.name } ?? ""
                    withAnimation(UI.fade) { naming = true }
                    DispatchQueue.main.async { focused = true }
                }
                .buttonStyle(PillButtonStyle()).fixedSize()
            }
        }
        .frame(minHeight: 28)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        do {
            let p = try ThemePresets.save(name: n, tokens: doc.project.theme)
            NotificationCenter.default.post(name: .themePresetsChanged, object: nil)
            doc.flash("Saved theme preset “\(p.name)”")
            withAnimation(UI.fade) { naming = false }
        } catch { doc.flash("Couldn't save the preset: \(error)") }
    }
}

/// Off-screen rendering of the popover content for `arclight snapshot --panel themepopover`.
struct ThemePopoverSnapshot: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        ThemePopover(doc: doc).frame(maxHeight: .infinity, alignment: .top).background(UI.bg)
    }
}
