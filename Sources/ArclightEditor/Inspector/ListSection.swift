import ArclightCore
import SwiftUI

/// A list of objects (repeater items, camera shakes): add / remove / reorder rows, each row a sub-section.
struct ListSection: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let schema: ObjectSchema
    @State private var open = true
    @State private var picking = false
    @Environment(\.inspectorIndent) private var indent

    private var rows: [JSONValue] { slot.stored?.array ?? [] }
    private var isItems: Bool { schema.field("symbol") != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.indices), id: \.self) { i in
                        ListRow(doc: doc, list: slot, schema: schema, index: i, count: rows.count)
                    }
                    if rows.isEmpty {
                        Text("Empty").font(UI.small).foregroundStyle(UI.faint).frame(height: 20)
                    }
                }
                .padding(.leading, UI.nestIndent)
                .environment(\.inspectorIndent, indent + UI.nestIndent)
                .overlay(alignment: .leading) { Rectangle().fill(UI.border).frame(width: 1) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DisclosureButton(open: open, toggle: { open.toggle() }) {
                Text(slot.field.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(
                    rows.isEmpty ? UI.dim : UI.text)
                Text("\(rows.count)").font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            .help(slot.field.doc)
            if isItems {
                IconButton(symbol: "plus", help: "Add a variant from the symbol library") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .leading) {
                        SymbolBrowser(project: doc.url, selected: nil) { id in
                            add(["symbol": .string(id), "height": .number(rows.last?["height"]?.double ?? 100)])
                            picking = false
                        }
                    }
            } else {
                IconButton(symbol: "plus", help: "Add") { add(newRow()) }
            }
        }
        .frame(height: 24)
    }

    private func newRow() -> JSONValue {
        var o: [String: JSONValue] = [:]
        if schema.field("at") != nil { o["at"] = .number(rounded(doc.time, places: 2)) }
        for f in schema.fields where !f.advanced && f.name != "at" { if let d = f.defaultValue { o[f.name] = d } }
        return .object(o)
    }

    private func add(_ row: JSONValue) { doc.write(slot, .array(rows + [row])) }
}

private struct ListRow: View {
    @ObservedObject var doc: EditorDocument
    let list: Slot
    let schema: ObjectSchema
    let index: Int
    let count: Int
    @State private var open: Bool?
    @Environment(\.inspectorIndent) private var indent

    private var row: JSONValue { list.stored?.array?[safe: index] ?? .null }

    var body: some View {
        let expanded = open ?? (count <= 2)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                DisclosureButton(open: expanded, chevronSize: 8, spacing: 6, toggle: { open = !expanded }) {
                    if let sym = row["symbol"]?.string ?? row["piece"]?.string.map({ "chess/" + $0 }) {
                        SymbolThumb(id: sym, project: doc.url).frame(width: 18, height: 18)
                    }
                    Text(summary).font(UI.small).foregroundStyle(UI.label2).lineLimit(1)
                }
                IconButton(symbol: "arrow.up", help: "Move up") { move(-1) }.disabled(index == 0).opacity(
                    index == 0 ? 0.3 : 1)
                IconButton(symbol: "arrow.down", help: "Move down") { move(1) }.disabled(index == count - 1).opacity(
                    index == count - 1 ? 0.3 : 1)
                IconButton(symbol: "plus.square.on.square", help: "Duplicate") { duplicate() }
                IconButton(symbol: "minus", help: "Remove") {
                    doc.write(doc.child(list, ["\(index)"], list.field), nil)
                }
            }
            .frame(height: 22)
            if expanded {
                FieldList(doc: doc, fields: schema.fields) { f in doc.child(list, ["\(index)", f.name], f) }
                    .padding(.leading, UI.nestIndent)
                    .environment(\.inspectorIndent, indent + UI.nestIndent)
            }
        }
    }

    private var summary: String {
        if let s = row["symbol"]?.string {
            return "\(index + 1)  " + (s.split(separator: "/").last.map(String.init) ?? s) + weight
        }
        if let at = row["at"]?.double { return "\(index + 1)  at \(fmt(at)) s" }
        return "\(index + 1)"
    }

    private var weight: String { row["weight"]?.double.map { "  ×\(fmt($0))" } ?? "" }

    private func move(_ d: Int) {
        guard var a = list.stored?.array, a.indices.contains(index), a.indices.contains(index + d) else { return }
        a.swapAt(index, index + d)
        doc.write(list, .array(a))
    }

    private func duplicate() {
        guard var a = list.stored?.array, a.indices.contains(index) else { return }
        a.insert(a[index], at: index + 1)
        doc.write(list, .array(a))
    }
}
