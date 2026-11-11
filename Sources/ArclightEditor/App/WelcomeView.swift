import AppKit
import SwiftUI

/// The home screen: New Project, Open… and the recent projects.
struct WelcomeView: View {
    let open: () -> Void
    let new: () -> Void
    let openURL: (URL) -> Void
    @State private var hover: URL?
    @State private var recents = Recents.all

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Spacer().frame(height: 24)
                HStack(spacing: 8) {
                    LogoMark(height: 20)
                    Text("Arclight").font(.system(size: 22, weight: .semibold)).foregroundStyle(UI.text)
                }
                Text("Motion graphics, built with AI.").font(UI.font).foregroundStyle(UI.dim)
                Spacer()
                Button("New Project", action: new).buttonStyle(PillButtonStyle(primary: true))
                Button("Open…", action: open).buttonStyle(PillButtonStyle())
                Spacer().frame(height: 8)
            }
            .padding(28).frame(width: 240, alignment: .leading)
            Hairline(vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Recent").padding(.top, 20)
                if recents.isEmpty {
                    Text("No recent projects").font(UI.font).foregroundStyle(UI.faint).padding(12)
                }
                ScrollView {
                    ForEach(recents, id: \.self) { u in
                        Button {
                            openURL(u)
                        } label: {
                            HStack(spacing: 10) {
                                ProjectThumb(url: u).frame(width: 64, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Recents.name(u)).font(UI.font).foregroundStyle(UI.text)
                                    Text(u.deletingLastPathComponent().tildePath)
                                        .font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(
                                .vertical, 6
                            )
                            .background(hover == u ? UI.hover : .clear).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).onHover { h in hover = h ? u : nil }.cursor(.pointingHand)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Button("Remove from Recent") {
                                Recents.remove(u); recents = Recents.all
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Only empty space (around the logo, the Recent header) moves the window: a window movable by its
        // background turned tap-to-click on a moving trackpad into window drags.
        .background(WindowDragArea())
        .background(UI.bg)
        .frame(width: 620, height: 420)
    }
}
