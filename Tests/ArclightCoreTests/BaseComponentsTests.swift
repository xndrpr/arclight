import AppKit
import SwiftUI
import Testing

@testable import ArclightEditor

/// The shared components draw exactly like the hand-built views they replace.
@MainActor @Suite struct BaseComponentsTests {
    /// Draws through Core Graphics. `ImageRenderer.cgImage` sometimes antialiased a few edge pixels one step
    /// differently under load (2-11 px, 1/255), so equal views compared unequal.
    func png<V: View>(_ v: V) -> Data? {
        let r = ImageRenderer(content: v.frame(width: 240).environment(\.colorScheme, .dark))
        var cg: CGImage?
        r.render { size, draw in
            let w = Int((size.width * 2).rounded(.up)), h = Int((size.height * 2).rounded(.up))
            guard
                let ctx = CGContext(
                    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: 2, y: 2)
            draw(ctx)
            cg = ctx.makeImage()
        }
        guard let cg else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func same<A: View, B: View>(_ a: A, _ b: B) {
        let pa = png(a), pb = png(b)
        #expect(pa != nil)
        #expect(pa == pb)
    }

    @Test func fieldButtonMatchesHandBuiltChrome() {
        same(
            FieldButton(action: {}) { Text("center").font(UI.mono).foregroundStyle(UI.text) },
            Button {
            } label: {
                HStack {
                    Text("center").font(UI.mono).foregroundStyle(UI.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(UI.dim)
                }
                .padding(.horizontal, 8).frame(height: UI.rowHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder, lineWidth: 1))
                .hitArea()
            }.buttonStyle(.plain))
        // ThemeFontField: tighter spacing, warning border for a missing font.
        for border in [UI.fieldBorder, UI.warning.opacity(0.6)] {
            same(
                FieldButton(spacing: 6, border: border, action: {}) {
                    Text("Avenir Next").font(.custom("Avenir Next", size: 12.5))
                },
                Button {
                } label: {
                    HStack(spacing: 6) {
                        Text("Avenir Next").font(.custom("Avenir Next", size: 12.5))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(UI.dim)
                    }
                    .fieldChrome(border: border)
                }.buttonStyle(.plain))
        }
    }

    @Test func smallCapsLabel() {
        same(SmallCapsLabel("Theme tokens"), Text("THEME TOKENS").font(UI.label).tracking(0.8).foregroundStyle(UI.dim))
        same(
            SmallCapsLabel("Today", color: UI.faint),
            Text("TODAY").font(UI.label).tracking(0.8).foregroundStyle(UI.faint))
    }

    @Test func popoverChrome() {
        same(Text("Easing").popoverChrome(), Text("Easing").padding(14).background(UI.panel))
        same(
            Text("Symbols").popoverChrome(width: 200),
            Text("Symbols").padding(14).frame(width: 200).background(UI.panel))
    }

    @Test func disclosureButton() {
        for open in [false, true] {
            same(
                DisclosureButton(open: open, toggle: {}) {
                    Text("Items"); Text("3")
                },
                Button {
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(
                            UI.faint
                        )
                        .rotationEffect(.degrees(open ? 90 : 0))
                        Text("Items"); Text("3")
                        Spacer(minLength: 0)
                    }
                    .hitArea()
                }.buttonStyle(.plain))
        }
    }

    @Test func rendererSeesTheDifference() {
        // Guards the comparisons above against blank renders.
        #expect(
            png(DisclosureButton(open: true, toggle: {}) { Text("Items") })
                != png(DisclosureButton(open: false, toggle: {}) { Text("Items") }))
        #expect(png(FieldButton(action: {}) { Text("a") }) != png(FieldButton(action: {}) { Text("b") }))
    }

    @Test func hoverButtonStyleAtRest() {
        same(
            Button {
            } label: {
                Text("Compare").font(.system(size: 11, weight: .medium))
            }.buttonStyle(HoverButtonStyle()),
            Button {
            } label: {
                Text("Compare").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.label2)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(UI.raised))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.border, lineWidth: 1))
                    .hitArea()
            }.buttonStyle(.plain))
    }

    /// The tab label as the sidebar, Settings and activity filters built it by hand.
    private struct HandBuiltTab: View {
        let selected: Bool
        let hitHeight: CGFloat?
        @Namespace private var ns
        var body: some View {
            let pill = Text("Scenes").font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? UI.text : UI.dim)
                .padding(.horizontal, 8).frame(height: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6).fill(UI.selected).matchedGeometryEffect(id: "tab", in: ns)
                    }
                }
                .padding(.horizontal, 1)
            if let hitHeight {
                pill.frame(height: hitHeight).hitArea()
            } else {
                pill.frame(maxHeight: .infinity).hitArea()
            }
        }
    }

    private struct SharedTab: View {
        let selected: Bool
        let hitHeight: CGFloat?
        @Namespace private var ns
        var body: some View {
            Text("Scenes").font(.system(size: 12, weight: selected ? .semibold : .regular))
                .tabPill(
                    selected: selected, padding: 8, height: 26, cornerRadius: 6, gap: 1, hitHeight: hitHeight,
                    id: "tab", in: ns)
        }
    }

    @Test func tabPillMatchesHandBuiltTabs() {
        for selected in [false, true] {
            for hit: CGFloat? in [nil, 40] {
                same(
                    HStack(spacing: 0) { SharedTab(selected: selected, hitHeight: hit) }.frame(height: 40),
                    HStack(spacing: 0) { HandBuiltTab(selected: selected, hitHeight: hit) }.frame(height: 40))
            }
        }
    }
}
