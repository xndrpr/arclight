import SwiftUI

/// Request JSON in a code box, capped in length, with copy.
struct RequestView: View {
    let text: String
    @State private var all = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cap = 40
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SmallCapsLabel("Request", color: UI.faint)
                Spacer()
                IconButton(symbol: "doc.on.doc", help: "Copy request JSON") { MCPSetup.copy(text) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(all || lines.count <= cap ? text : lines.prefix(cap).joined(separator: "\n"))
                    .font(UI.monoSmall).foregroundStyle(UI.label2).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.border, lineWidth: 1))
            if lines.count > cap {
                Button {
                    all.toggle()
                } label: {
                    Text(all ? "Show less" : "Show all \(lines.count) lines").font(UI.small).foregroundStyle(UI.dim)
                        .padding(.vertical, 2).hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand)
            }
        }
    }
}
