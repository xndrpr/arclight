import SwiftUI

/// The Arclight mark (an "A" with an orbit), traced from the brand artwork into a vector so it stays crisp
/// at any size and takes the current theme's colour: `ArclightLogo().fill(UI.text).frame(height: 14)`.
/// Aspect ratio is fixed (see `aspect`); use `.aspectRatio(ArclightLogo.aspect, contentMode: .fit)`.
private struct ArclightLogo: Shape {
    static let size = CGSize(width: 1000.0, height: 448.3)
    static var aspect: CGFloat { size.width / size.height }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / Self.size.width, rect.height / Self.size.height)
        let ox = rect.minX + (rect.width - Self.size.width * s) / 2,
            oy = rect.minY + (rect.height - Self.size.height * s) / 2
        var p = Path()
        let sc = Scanner(string: Self.d)
        sc.charactersToBeSkipped = .whitespaces
        while !sc.isAtEnd {
            if sc.scanString("Z") != nil { p.closeSubpath(); continue }
            guard let c = sc.scanCharacter(), let x = sc.scanDouble(), let y = sc.scanDouble() else { break }
            let pt = CGPoint(x: ox + x * s, y: oy + y * s)
            if c == "M" { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// Even-odd polygon path in a 1000.0×448.3 box (y down).
    static let d =
        "M966.4 127.5L954.9 137.7L936.3 151.7L910.9 168.6L885.6 183.6L858.9 198.1L824.1 215.4L786.8 232.4L759.4 244.1L756.6 246.2L757.1 248.8L760.8 253.8L866.9 388.8L907.1 440.8L908.0 442.5L906.8 443.7L720.4 444.0L716.2 443.9L713.6 443.2L710.8 440.6L615.4 309.0L613.9 307.4L611.8 306.6L609.4 306.9L598.8 310.5L508.7 343.0L455.0 360.9L394.9 380.2L347.4 394.6L296.6 408.9L255.1 419.6L221.7 427.4L172.8 437.1L130.6 443.8L102.5 447.2L94.0 447.4L86.3 448.3L54.9 448.2L43.1 447.1L31.3 444.7L23.9 442.3L15.9 438.4L9.9 434.6L6.6 431.4L3.1 426.2L0.8 420.9L0.1 417.3L0.0 407.6L1.2 400.1L3.8 393.0L11.5 379.0L23.9 363.1L47.2 339.8L56.0 332.2L71.8 319.8L84.4 310.7L108.7 294.8L120.2 287.9L156.4 267.6L213.3 239.4L213.8 240.0L212.4 241.1L200.2 247.3L186.5 255.3L157.5 273.1L135.4 287.9L114.1 303.5L103.8 311.6L94.5 319.7L75.5 338.7L66.9 349.7L58.8 363.3L55.9 372.4L55.4 376.2L55.5 382.6L57.4 389.3L60.4 393.9L62.0 395.5L68.6 399.8L74.7 402.4L85.8 405.4L90.9 406.3L92.8 405.8L95.0 403.8L132.4 358.7L165.1 317.6L169.3 313.1L242.1 224.1L252.0 211.2L407.2 19.0L416.1 8.3L418.0 6.9L422.9 6.4L558.6 6.4L562.7 6.7L565.0 7.6L568.9 11.4L598.4 48.1L606.9 58.1L673.1 139.5L725.2 205.7L726.4 207.6L726.5 208.7L724.6 210.4L710.1 217.6L659.8 241.1L623.6 257.1L614.2 261.7L592.2 271.1L589.6 271.4L587.0 269.0L557.4 229.1L495.5 147.7L493.9 146.4L492.8 146.3L489.8 149.3L478.4 164.0L431.5 226.7L371.7 304.9L319.9 371.4L316.9 375.7L316.8 376.6L317.6 377.1L322.5 376.1L358.5 365.5L408.8 349.5L467.4 330.0L512.4 314.2L561.6 296.0L596.0 282.7L652.5 259.9L717.3 231.3L770.9 205.7L804.2 187.9L831.0 172.3L849.0 161.0L871.8 145.8L883.7 137.1L906.0 119.3L922.4 104.1L933.1 91.0L938.7 81.3L941.2 74.1L941.0 66.0L939.0 61.5L935.3 56.5L930.2 53.0L922.2 49.0L915.1 46.3L909.0 44.8L888.7 41.3L886.9 41.5L885.6 42.4L881.5 52.4L876.8 59.6L871.8 64.4L865.0 68.5L856.0 71.4L845.4 71.5L839.9 70.5L831.4 67.0L823.6 60.7L817.5 51.6L814.6 42.6L814.5 30.9L816.4 23.1L819.0 18.1L822.0 13.5L828.6 7.1L833.2 4.1L836.9 2.4L845.5 0.1L853.9 0.0L861.0 1.6L866.8 4.4L870.2 6.5L876.2 11.4L881.8 19.8L884.3 26.0L886.0 27.6L899.7 29.1L910.4 29.3L929.8 31.6L952.4 36.1L964.2 39.5L973.6 43.2L983.0 47.9L989.7 53.1L995.4 59.3L999.5 68.3L1000.0 72.1L999.9 78.5L998.1 86.5L994.4 94.7L987.4 105.1L981.6 112.3ZM738.8 53.0L692.8 64.5L659.1 75.4L641.7 81.7L639.8 81.7L643.5 79.4L676.5 64.6L699.8 55.3L722.1 48.2L751.4 40.6L772.9 36.1L794.5 32.7L801.9 32.1L803.2 33.4L803.7 40.1L803.5 41.3L801.9 42.3L765.2 47.9Z"
}

/// The mark sized by height, in the theme's text colour.
struct LogoMark: View {
    var height: CGFloat = 14
    var color: Color = UI.text
    var body: some View {
        ArclightLogo().fill(color, style: FillStyle(eoFill: true))
            .frame(width: height * ArclightLogo.aspect, height: height)
            .accessibilityLabel("Arclight")
    }
}
