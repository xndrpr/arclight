import AppKit
import SwiftUI

/// Help ▸ Install & Security Guide…: why macOS may block or trash Arclight (no paid Apple certificate)
/// and the exact fix. Mirrors docs/install.md.
struct InstallHelpView: View {
    let close: () -> Void
    private var appPath: String {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : "/Applications/Arclight.app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(height: 18)
                Text("Install & security").font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
            .background(WindowDragArea())
            Text(
                "Arclight is open source and isn't signed with a paid Apple certificate, so macOS may warn about it. These steps keep it installed and opening normally."
            )
            .font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20).padding(.bottom, 14)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step(
                        "Install from source (recommended)",
                        "Apps you build yourself aren't quarantined. In the Arclight folder run:",
                        "Scripts/install.sh")
                    step(
                        "“Arclight is damaged” or “Move to Trash”",
                        "Click Cancel (not Move to Trash), then run this in Terminal and open Arclight again:",
                        "xattr -cr \"\(appPath)\" && codesign --force --sign - \"\(appPath)\"")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("“Cannot verify the developer”").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.text)
                        Text(
                            "Open System Settings ▸ Privacy & Security, scroll to Security and click Open Anyway next to Arclight."
                        )
                        .font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
                        Button("Open Privacy & Security") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?General") {
                                NSWorkspace.shared.open(u)
                            }
                        }.buttonStyle(PillButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The app vanishes or quits after an update").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UI.text)
                        Text(
                            "Quit Arclight before reinstalling, and don't run it from the dist/ build folder (each build deletes it). Third-party antivirus: add Arclight to its exclusions."
                        )
                        .font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
                    }
                    step(
                        "Connect an AI agent to this installed copy",
                        "For Claude Code (other MCP clients use the same command over stdio):",
                        "claude mcp add -s user arclight -- \"\(Bundle.main.executablePath ?? appPath + "/Contents/MacOS/arclight")\" mcp"
                    )
                }
                .padding(20)
            }
            Hairline()
            HStack {
                Text("Full guide: docs/install.md").font(UI.small).foregroundStyle(UI.dim)
                Spacer()
                Button("Done", action: close).buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(
                    .defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
        .background(UI.panel)
    }

    private func step(_ title: String, _ text: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.text)
            Text(text).font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
            CommandBox(command: command)
        }
    }
}

/// A shell command in a mono box with a Copy button.
private struct CommandBox: View {
    let command: String
    @State private var copied = false
    /// Counts clicks, so each one restarts the "Copied" timer.
    @State private var copies = 0
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command).font(UI.monoSmall).foregroundStyle(UI.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                withAnimation(UI.fade) { copied = true }
                copies += 1
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { withAnimation(UI.fade) { copied = false } }
        }
    }
}
