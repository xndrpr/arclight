import SwiftUI

/// Lays children left to right at their ideal sizes, wrapping onto new lines; each line starts at the leading edge,
/// or ends at the trailing one.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            let x0 = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: x0 + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var items: [Int] = [], xs: [CGFloat] = [], width: CGFloat = 0, height: CGFloat = 0, y: CGFloat = 0
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            var r = rows[rows.count - 1]
            if !r.items.isEmpty && r.width + spacing + s.width > maxWidth {
                rows.append(Row(y: r.y + r.height + spacing))
                r = rows[rows.count - 1]
            }
            let x = r.items.isEmpty ? 0 : r.width + spacing
            r.items.append(i); r.xs.append(x); r.width = x + s.width; r.height = max(r.height, s.height)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
