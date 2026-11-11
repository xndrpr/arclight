import Foundation
import JavaScriptCore

/// Evaluates prop expressions with JavaScriptCore.
///
/// An expression sees `t` (node-local seconds), `T` (scene seconds), `i` (instance index),
/// `d` (scene duration) and helpers: `ease(name, x)`, `clamp`, `lerp`, `rand(seed)`, `noise(x)`,
/// `wiggle(freq, amp, seed?)`. Single-statement expressions are returned implicitly;
/// use `return` for multi-statement bodies (told apart by parsing, see `form(_:)`).
public final class ExprEngine {
    let ctx: JSContext
    private var cache: [String: JSValue] = [:]
    private var lastError: String?

    static let prelude = """
        function clamp(x, a, b) { return Math.min(Math.max(x, a), b); }
        function lerp(a, b, u) { return a + (b - a) * u; }
        function rand(s) { var x = Math.sin(s * 12.9898 + 78.233) * 43758.5453; return x - Math.floor(x); }
        function noise(x) { var i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return lerp(rand(i), rand(i + 1), u); }
        function smoothstep(a, b, x) { var u = clamp((x - a) / (b - a), 0, 1); return u * u * (3 - 2 * u); }
        // Lamp switching on at time `on`: fast rise with a short flicker (0 before `on`, ~1 after).
        function lamp(t, on) {
          var k = t - on; if (k < 0) return 0;
          var I = k >= 0.09 ? 1 : 1 - Math.pow(2, -10 * k / 0.09);
          if (k < 0.16) I *= 0.55 + 0.45 * (Math.sin(k * 170) > -0.2 ? 1 : 0.25);
          return I;
        }
        // Exactly round(n * frac) instances chosen in a seeded random order. Returns the instance's rank
        // in that order (0 = first) or -1 if not chosen. Use the rank to stagger times.
        var __perm = {};
        function pick(i, n, frac, seed) {
          var key = n + '|' + seed, rank = __perm[key];
          if (!rank) {
            var idx = []; for (var j = 0; j < n; j++) idx.push(j);
            idx.sort(function(a, b) { return rand(a * 7.13 + seed * 1.37) - rand(b * 7.13 + seed * 1.37); });
            rank = new Array(n); for (var r = 0; r < n; r++) rank[idx[r]] = r;
            __perm[key] = rank;
          }
          return rank[i] < Math.round(n * frac) ? rank[i] : -1;
        }
        """

    /// Supplies live repeater stats to `litFraction(id)`, `litCount(id)` and `instanceCount(id)`.
    public var litProvider: ((String) -> (lit: Int, total: Int))?
    /// Supplies scene marker times to `marker(name)` (NaN when missing).
    public var markerProvider: ((String) -> Double?)?

    public init() {
        ctx = JSContext()!
        ctx.exceptionHandler = { [weak self] _, exc in self?.lastError = exc?.toString() ?? "error" }
        let ease: @convention(block) (String, Double) -> Double = { name, x in Easing(name).apply(x) }
        ctx.setObject(ease, forKeyedSubscript: "ease" as NSString)
        let stat: @convention(block) (String, Int) -> Double = { [weak self] id, which in
            guard let s = self?.litProvider?(id) else { return 0 }
            switch which {
            case 0: return s.total > 0 ? Double(s.lit) / Double(s.total) : 0
            case 1: return Double(s.lit)
            default: return Double(s.total)
            }
        }
        ctx.setObject(stat, forKeyedSubscript: "__stat" as NSString)
        let marker: @convention(block) (String) -> Double = { [weak self] name in self?.markerProvider?(name) ?? .nan }
        ctx.setObject(marker, forKeyedSubscript: "marker" as NSString)
        ctx.evaluateScript(ExprEngine.prelude)
        ctx.evaluateScript(
            """
            function litFraction(id) { return __stat(id, 0); }
            function litCount(id) { return __stat(id, 1); }
            function instanceCount(id) { return __stat(id, 2); }
            """)
    }

    /// How a source runs: as one expression whose value is returned, or as a statement body with its own `return`.
    enum Form: Equatable { case expression, body }

    private var formCache: [String: Form] = [:]

    /// Classifies a source by parsing it; nothing is run. It is an expression when `return (src);` parses.
    /// Otherwise it is a statement body when it parses as a function body but not as a script, which means it
    /// has a `return` of its own (outside nested functions). A source that parses nowhere is a body, so the
    /// syntax error reported is the body's; anything else (`1; 2`) stays an expression and reports its error.
    func form(_ src: String) -> Form {
        if let f = formCache[src] { return f }
        let f: Form
        if parses("(function() { return (\(src)); })") {
            f = .expression
        } else if !parses("(function() { \(src) })") {
            f = .body
        } else {
            f = parses(src) ? .expression : .body
        }
        formCache[src] = f
        return f
    }

    /// Whether `script` is syntactically valid. Only the syntax is checked; nothing is evaluated.
    private func parses(_ script: String) -> Bool {
        let s = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(s) }
        return JSCheckScriptSyntax(ctx.jsGlobalContextRef, s, nil, 1, nil)
    }

    private func wrap(_ src: String) -> String {
        let body = form(src) == .body ? src : "return (\(src));"
        return
            "(function(t, T, i, d, n) { function wiggle(f, a, s) { return (noise(t * f + (s || 0) * 31.7) * 2 - 1) * a; } \(body) })"
    }

    private func function(_ src: String) -> JSValue? {
        if let f = cache[src] { return f }
        lastError = nil
        guard let f = ctx.evaluateScript(wrap(src)), lastError == nil, f.isObject else { return nil }
        cache[src] = f
        return f
    }

    /// Returns a message if the expression fails to compile or throws at t = 0.
    public func compileError(_ src: String) -> String? {
        lastError = nil
        guard let f = function(src) else { return lastError ?? "does not compile" }
        _ = f.call(withArguments: [0, 0, 0, 1, 4])
        return lastError
    }

    private var batchCache: [String: JSValue] = [:]

    /// Evaluates an expression for instances 0..<n in one JS call (fast path for repeaters).
    /// Returns nil if it fails; non-numeric results come back as NaN.
    public func evalBatch(_ src: String, t: Double, T: Double, d: Double, n: Int) -> [Double]? {
        let f: JSValue
        if let c = batchCache[src] {
            f = c
        } else {
            let body = form(src) == .body ? "(function(){ \(src) })()" : "(\(src))"
            lastError = nil
            guard
                let made = ctx.evaluateScript(
                    """
                    (function(t, T, d, n) {
                      function wiggle(f, a, s) { return (noise(t * f + (s || 0) * 31.7) * 2 - 1) * a; }
                      var out = new Array(n);
                      for (var i = 0; i < n; i++) { out[i] = +\(body); }
                      return out;
                    })
                    """), lastError == nil, made.isObject
            else { return nil }
            batchCache[src] = made
            f = made
        }
        lastError = nil
        guard let r = f.call(withArguments: [t, T, d, n]), lastError == nil, let arr = r.toArray() else { return nil }
        return arr.map { ($0 as? NSNumber)?.doubleValue ?? .nan }
    }

    public func eval(_ src: String, t: Double, T: Double, i: Int = 0, d: Double = 0, n: Int = 1) -> JSONValue {
        guard let f = function(src) else { return .null }
        lastError = nil
        guard let r = f.call(withArguments: [t, T, i, d, n]), lastError == nil else { return .null }
        if r.isNumber { let x = r.toDouble(); return x.isFinite ? .number(x) : .null }
        if r.isString { return .string(r.toString()) }
        if r.isBoolean { return .bool(r.toBool()) }
        if r.isArray { return JSONValue(any: r.toArray()) }
        if r.isObject { return JSONValue(any: r.toDictionary()) }
        return .null
    }
}
