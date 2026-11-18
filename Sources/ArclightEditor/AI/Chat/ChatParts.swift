import AppKit
import ArclightCore
import SwiftUI

/// What the message list draws: a row, or a run of tool calls folded into one line.
enum ChatBlock: Identifiable {
    case item(ChatItem)
    case tools([ChatItem])

    var id: String {
        switch self {
        case .item(let i): return i.id
        case .tools(let t): return "tools-" + (t.first?.id ?? "")
        }
    }

    /// Two or more tool calls in a row become one group.
    static func group(_ items: [ChatItem]) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var run: [ChatItem] = []
        func flush() {
            if run.count == 1 { out.append(.item(run[0])) } else if !run.isEmpty { out.append(.tools(run)) }
            run = []
        }
        for i in items {
            if i.kind == .tool { run.append(i) } else { flush(); out.append(.item(i)) }
        }
        flush()
        return out
    }
}

/// A run of tool calls: one line saying what happened (or what is happening), opening into each call.
struct ChatToolGroup: View, Equatable {
    let tools: [ChatItem]
    @State private var open = false

    static func == (a: Self, b: Self) -> Bool { a.tools == b.tools }

    var body: some View {
        let running = tools.last { $0.ok == nil }
        let failed = tools.filter { $0.ok == false }.count
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if running != nil {
                            ProgressView().controlSize(.mini)
                        } else if failed > 0 {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(UI.warning)
                        } else {
                            Image(systemName: "checkmark").foregroundStyle(UI.success)
                        }
                    }
                    .font(.system(size: 9, weight: .bold)).frame(width: 12)
                    Text(summary(running: running, failed: failed)).font(UI.small).foregroundStyle(UI.label2)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(UI.dim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.raised))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand).help(open ? "Hide the steps" : "Show each step")
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { ChatToolRow(item: $0) }
                }
                .padding(.leading, 12).transition(.opacity)
            }
        }
    }

    private func summary(running: ChatItem?, failed: Int) -> String {
        if let running { return ChatToolNames.doing(running.tool ?? "") + "…  (\(tools.count) steps)" }
        // Distinct actions, in order.
        var seen: [String] = []
        for t in tools {
            let d = ChatToolNames.done(t.tool ?? "")
            if !seen.contains(d) { seen.append(d) }
        }
        var s =
            "\(tools.count) steps: "
            + seen.prefix(3).map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: ", ")
        if seen.count > 3 { s += "…" }
        if failed > 0 { s += " · \(failed) failed" }
        return s
    }
}

/// The AI's reply: Markdown blocks, a copy button on hover, and Copy in the context menu.
struct ChatAssistantRow: View {
    let text: String
    let live: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatMarkdown(text: text)
            if !live {
                HStack(spacing: 2) {
                    IconButton(symbol: "doc.on.doc", help: "Copy message") { ChatRow.copy(text) }
                        .opacity(hover ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { Button("Copy Message") { ChatRow.copy(text) } }
    }
}

/// Markdown the model writes, block by block: paragraphs, headings, bullet and numbered lists, code fences.
/// Inline styles (bold, italic, code, links) inside each block.
struct ChatMarkdown: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String)
        case heading(String, Int)
        case bullet(String, Int)
        case numbered(String, String)
        case code(String)
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))) }
            para = []
        }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flush()
                out.append(
                    .heading(
                        String(line[h...]).trimmingCharacters(in: .whitespaces),
                        line.distance(from: line.startIndex, to: h)))
                continue
            }
            let indent = raw.prefix { $0 == " " }.count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(String(line.dropFirst(2)), indent)); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
                line[..<dot].allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex,
                line[line.index(after: dot)] == " "
            {
                flush()
                out.append(.numbered(String(line[line.index(dot, offsetBy: 2)...]), String(line[..<dot])))
                continue
            }
            para.append(raw)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .paragraph(let s):
            Text(ChatRow.markdown(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            Text(ChatRow.markdown(s)).font(.system(size: level <= 1 ? 15 : level == 2 ? 14 : 13, weight: .semibold))
                .foregroundStyle(UI.text).padding(.top, 2)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").font(ChatRow.body).foregroundStyle(UI.dim)
                Text(ChatRow.markdown(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14 + 2)
        case .numbered(let s, let n):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n + ".").font(ChatRow.body).foregroundStyle(UI.dim).monospacedDigit()
                Text(ChatRow.markdown(s)).font(ChatRow.body).foregroundStyle(UI.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(UI.monoSmall).foregroundStyle(UI.label2).padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
        }
    }
}

/// The chat header's model picker: which fal model makes images and 3D models (with prices), or Auto.
struct ChatModelMenu: View {
    @State private var models = ImageSettings.models
    @State private var hasKey = KeychainStore.falKey() != nil

    var body: some View {
        Menu {
            if !hasKey {
                Button("Add a fal.ai key for images and 3D…") { ChatSettingsLink.open() }
                Divider()
            }
            Section("Images") {
                choice(ModelCatalog.auto, label: "Auto — best model for each picture", kp: \.generate)
                ForEach(ModelCatalog.images) { e in choice(e.id, label: label(e), kp: \.generate) }
            }
            Section("3D models") {
                choice(ModelCatalog.auto, label: "Auto — Trellis 2 ($0.30), Trellis ($0.02) for drafts", kp: \.model3D)
                ForEach(ModelCatalog.models3D) { e in choice(e.id, label: label(e), kp: \.model3D) }
            }
            Divider()
            Button("Custom model ids…") { ChatSettingsLink.open() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo.stack").font(.system(size: 10, weight: .medium))
                Text(short(models.generate)).font(UI.small).lineLimit(1)
            }
            .foregroundStyle(UI.label2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Image model: \(name(models.generate)) · 3D model: \(name(models.model3D)). Prices are per result.")
        .onAppear {
            models = ImageSettings.models
            hasKey = KeychainStore.falKey() != nil
        }
    }

    private func label(_ e: ModelCatalog.Entry) -> String {
        "\(e.label)  ·  \(e.priceNote)  ·  \(e.bestFor)" + (e.expensive ? "  (expensive)" : "")
    }

    private func name(_ id: String) -> String {
        id == ModelCatalog.auto ? "Auto" : ModelCatalog.entry(id)?.label ?? id
    }

    private func short(_ id: String) -> String { name(id) }

    private func choice(_ id: String, label: String, kp: WritableKeyPath<FalProvider.Models, String>) -> some View {
        Button {
            models[keyPath: kp] = id
            ImageSettings.models = models
        } label: {
            if models[keyPath: kp] == id { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}
