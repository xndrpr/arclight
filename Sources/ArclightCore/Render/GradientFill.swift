import simd

/// Gradient fill for shapes: `{"linear":[x0,y0,x1,y1],"stops":[[0,"#000"],[1,"#0000"]]}` or
/// `{"radial":[cx,cy,r],"stops":[...]}`, in the shape's local units (origin at its centre). Up to 4 stops.
struct GradientFill {
    var grad: SIMD4<Float>, info: SIMD4<Float>, stops: SIMD4<Float>, colors: [SIMD4<Float>]

    init?(_ v: JSONValue?, opacity: Double) {
        guard let o = v?.object, let stops = o["stops"]?.array, !stops.isEmpty else { return nil }
        if let l = o["linear"]?.doubles, l.count == 4 {
            grad = SIMD4(Float(l[0]), Float(l[1]), Float(l[2]), Float(l[3])); info = SIMD4(1, 0, 0, 0)
        } else if let r = o["radial"]?.doubles, r.count == 3 {
            grad = SIMD4(Float(r[0]), Float(r[1]), Float(r[2]), 0); info = SIMD4(2, 0, 0, 0)
        } else {
            return nil
        }
        var pos: [Float] = [], cols: [SIMD4<Float>] = []
        for s in stops.prefix(4) {
            guard let a = s.array, a.count == 2, let p = a[0].double, let c = RGBA.parse(a[1]) else { continue }
            pos.append(Float(p)); cols.append(c.linearPremultiplied(opacity: opacity))
        }
        guard !pos.isEmpty else { return nil }
        info.y = Float(pos.count)
        while pos.count < 4 { pos.append(pos.last!); cols.append(cols.last!) }
        self.stops = SIMD4(pos[0], pos[1], pos[2], pos[3]); colors = cols
    }

    func apply(_ u: inout ShapeU) {
        u.grad = grad; u.gradInfo = info; u.gStops = stops
        u.gC0 = colors[0]; u.gC1 = colors[1]; u.gC2 = colors[2]; u.gC3 = colors[3]
    }
}
