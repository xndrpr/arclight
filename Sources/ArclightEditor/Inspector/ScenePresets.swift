import ArclightCore
import SwiftUI

struct PresetMenu: View {
    let title: String
    let items: [(String, () -> Void)]
    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in Button(it.0, action: it.1) }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(UI.dim)
            }
            .foregroundStyle(UI.text)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.border))
            .hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().cursor(.pointingHand).padding(.trailing, 4)
    }
}

/// Empty state: explanation and a list of presets to start from.
struct EmptyPresets: View {
    let text: String
    let presets: [(String, String, () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true).padding(
                .bottom, 4)
            ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                Button(action: p.2) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.dim)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.0).font(UI.font).foregroundStyle(UI.text)
                            Text(p.1).font(UI.small).foregroundStyle(UI.faint).lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
                    .hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand)
            }
        }
        .padding(UI.inset)
    }
}

/// Starting points for the scene camera and look.
enum ScenePresets {
    /// (name, camera JSON, description) for a canvas size.
    static func cameras(_ size: CGSize) -> [(String, JSONValue, String)] {
        let w = Double(size.width), h = Double(size.height)
        let dist = ((h / 2) / tan(20 * .pi / 180)).rounded()
        func v(_ a: Double, _ b: Double, _ c: Double) -> JSONValue {
            [.number(a.rounded()), .number(b.rounded()), .number(c.rounded())]
        }
        return [
            (
                "Front", ["position": v(w / 2, h / 2, -dist), "target": v(w / 2, h / 2, 0), "fov": 40],
                "Matches the 2D canvas exactly — a neutral start for camera moves."
            ),
            (
                "Low angle",
                ["position": v(w / 2, h * 0.95, -dist * 0.8), "target": v(w / 2, h * 0.55, 600), "fov": 45],
                "Looking slightly up across the floor: heroic, dramatic."
            ),
            (
                "High angle",
                ["position": v(w / 2, -h * 0.5, -dist * 0.6), "target": v(w / 2, h * 0.75, 900), "fov": 40],
                "Looking down onto a crowd or field of copies."
            ),
            (
                "Telephoto",
                [
                    "position": v(w / 2, h * 0.3, -dist * 2.2), "target": v(w / 2, h * 0.7, 900), "fov": 22,
                    "dof": ["blur": 10, "range": 0.4],
                ], "Long lens, flattened depth and soft background."
            ),
        ]
    }

    struct Look {
        let name: String
        let detail: String
        let post: JSONValue
        let fog: JSONValue?
    }

    static let looks: [Look] = [
        Look(
            name: "Clean", detail: "Neutral, filmic highlights, a touch of glow.",
            post: ["tonemap": true, "bloom": ["intensity": 0.2, "threshold": 1]], fog: nil),
        Look(
            name: "Black & white film", detail: "No colour, extra contrast, grain and soft corners.",
            post: [
                "saturation": 0, "contrast": 1.15, "grain": 0.06, "tonemap": true,
                "vignette": ["amount": 0.6, "softness": 0.7],
            ], fog: nil),
        Look(
            name: "Soft glow", detail: "Strong bloom on bright areas, gentle contrast.",
            post: [
                "bloom": ["intensity": 0.8, "threshold": 0.7], "exposure": 0.1, "contrast": 0.95, "vignette": 0.3,
                "tonemap": true,
            ], fog: nil),
        Look(
            name: "Dark documentary", detail: "Low-key, muted colour, grain, vignette, distance fog and fades.",
            post: [
                "exposure": -0.3, "contrast": 1.1, "saturation": 0.7, "grain": 0.05,
                "vignette": ["amount": 0.8, "softness": 0.8],
                "bloom": ["intensity": 0.35, "threshold": 0.8], "fade": ["in": 0.6, "out": 0.6],
            ],
            fog: ["color": "$bg", "near": 1200, "far": 4000]),
    ]
}
