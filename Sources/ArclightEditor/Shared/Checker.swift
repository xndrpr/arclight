import SwiftUI

/// Dark checkerboard behind thumbnails.
struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.05)))
            let s: CGFloat = 4.5
            var p = Path()
            for row in 0..<Int(size.height / s + 1) {
                for col in 0..<Int(size.width / s + 1) where (row + col) % 2 == 0 {
                    p.addRect(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s))
                }
            }
            ctx.fill(p, with: .color(Color(white: 0.1)))
        }
    }
}
