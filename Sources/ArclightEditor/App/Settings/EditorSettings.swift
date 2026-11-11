import AppKit
import ArclightCore
import SwiftUI

struct EditorSettings: View {
    let doc: EditorDocument?
    @AppStorage(Pref.performance) private var performance = false
    @AppStorage(Pref.snapping) private var snapping = true
    @AppStorage(Pref.theme) private var theme = AppTheme.dark.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                label: "Theme", note: "Colours of the editor itself. Your video's colours are set by the project theme."
            ) {
                AppThemeGrid(
                    selection: Binding(get: { theme }, set: { if let t = AppTheme(rawValue: $0) { AppTheme.apply(t) } })
                )
            }
            Hairline()
            SettingRow(
                label: "Performance mode",
                note: "Preview at half resolution when playback lags. Export is always full quality."
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { doc?.performance ?? performance },
                        set: {
                            performance = $0; doc?.performance = $0
                        })
                )
                .labelsHidden().toggleStyle(.switch)
            }
            Hairline()
            SettingRow(
                label: "Snapping", note: "Snap drags to the playhead, keyframes and layer edges. Toggle anytime with N."
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { doc?.snapping ?? snapping },
                        set: {
                            snapping = $0; doc?.snapping = $0
                        })
                )
                .labelsHidden().toggleStyle(.switch)
            }
            Hairline()
            SettingRow(
                label: "Panels",
                note:
                    "Restore the default sidebar and timeline sizes, and put the AI panel back in the top-right corner."
            ) {
                Button("Reset layout") {
                    for k in [Pref.leftWidth, Pref.rightWidth, Pref.timelineHeight, Pref.aiFloat, Pref.legacyAIWidth] {
                        Pref.store.removeObject(forKey: k)
                    }
                }.buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// Swatch grid of app themes: each tile previews panel, text and accent colours.
private struct AppThemeGrid: View {
    @Binding var selection: String
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(AppTheme.allCases) { t in
                let p = t.palette, on = selection == t.rawValue
                Button {
                    selection = t.rawValue
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(p.text).frame(width: 26, height: 4)
                            Spacer()
                            Circle().fill(p.accent).frame(width: 8, height: 8)
                        }
                        RoundedRectangle(cornerRadius: 2).fill(p.dim).frame(width: 40, height: 3)
                        RoundedRectangle(cornerRadius: 3).fill(p.raised).frame(height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.border))
                        Text(t.title).font(.system(size: 11, weight: .medium)).foregroundStyle(p.text)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(p.panel))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7).stroke(on ? UI.accent : UI.border, lineWidth: on ? 2 : 1)
                    )
                    .hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand).help(t.title)
            }
        }
        .frame(maxWidth: 360)
    }
}
