// Helper for Scripts/verify.sh, compiled on demand with swiftc (not part of the package).
//
//   verify-tool imgdiff <threshold> <max-fraction> <diff-dir>   reads "name<TAB>baseline<TAB>current[<TAB>max-fraction]"
//                                                               lines on stdin (the optional field overrides the default)
//   verify-tool mcpnorm <work-dir> <image-dir>                  JSON-RPC transcript on stdin → normalised text on stdout
//
// imgdiff: a pixel differs when any channel differs by more than <threshold> (0–255). An image passes when the
// differing pixels are at most <max-fraction> of the image and the sizes match. Failing images get a diff PNG
// (changed pixels in red over a dimmed copy of the baseline) in <diff-dir>. Exit 1 if any image fails.
import AppKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }

struct Pixels {
    let w: Int, h: Int
    var rgba: [UInt8]

    init?(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        w = img.width; h = img.height
        rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }

    func writePNG(_ url: URL) {
        var copy = rgba
        copy.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let img = ctx.makeImage(),
                let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dst, img, nil)
            CGImageDestinationFinalize(dst)
        }
    }
}

func imgdiff(threshold: Int, maxFraction: Double, diffDir: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)
    var failed = 0, total = 0
    while let line = readLine() {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { continue }
        total += 1
        let (name, a, b) = (f[0], f[1], f[2])
        let allowed = f.count > 3 ? Double(f[3]) ?? maxFraction : maxFraction
        guard let pa = Pixels(URL(fileURLWithPath: a)) else {
            print("FAIL \(name): baseline unreadable (\(a))"); failed += 1; continue
        }
        guard let pb = Pixels(URL(fileURLWithPath: b)) else {
            print("FAIL \(name): missing or unreadable (\(b))"); failed += 1; continue
        }
        guard pa.w == pb.w, pa.h == pb.h else {
            print("FAIL \(name): size \(pb.w)x\(pb.h), baseline \(pa.w)x\(pa.h)"); failed += 1; continue
        }
        var differing = 0, maxDelta = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var diff = pa
        for y in 0..<pa.h {
            for x in 0..<pa.w {
                let i = (y * pa.w + x) * 4
                var d = 0
                for c in 0..<4 { d = max(d, abs(Int(pa.rgba[i + c]) - Int(pb.rgba[i + c]))) }
                maxDelta = max(maxDelta, d)
                if d > threshold {
                    differing += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    diff.rgba[i] = 255; diff.rgba[i + 1] = 0; diff.rgba[i + 2] = 0; diff.rgba[i + 3] = 255
                } else {
                    for c in 0..<3 { diff.rgba[i + c] = pa.rgba[i + c] / 4 }
                    diff.rgba[i + 3] = 255
                }
            }
        }
        let fraction = Double(differing) / Double(pa.w * pa.h)
        let stats = String(format: "%d px differ (%.4f%%), max channel delta %d", differing, fraction * 100, maxDelta)
        if fraction > allowed {
            failed += 1
            let out = diffDir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "__"))
            diff.writePNG(out)
            // Region in top-left coordinates (CGContext rows run bottom-up).
            print(
                "FAIL \(name): \(stats), region x \(minX)–\(maxX) y \(pa.h - 1 - maxY)–\(pa.h - 1 - minY); diff: \(out.path)"
            )
        } else if differing > 0 {
            print("ok   \(name): within tolerance, \(stats)")
        }
    }
    print("images: \(total - failed)/\(total) match")
    return failed == 0 ? 0 : 1
}

// MARK: MCP transcript normalisation

/// Replaces volatile parts of the transcript: the work-dir path, ISO timestamps, durations in export lines,
/// base64 image payloads (decoded and saved to <image-dir> for a pixel comparison instead) and the server version.
func mcpnorm(work: String, imageDir: URL) -> Int32 {
    try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    var n = 0
    var lines: [String] = []
    while let line = readLine() {
        guard let data = line.data(using: .utf8), var obj = try? JSONSerialization.jsonObject(with: data) else {
            lines.append("NON-JSON: " + line); continue
        }
        obj = walk(obj) { dict in
            var d = dict
            if d["type"] as? String == "image", let b64 = d["data"] as? String {
                n += 1
                let name = "mcp-image-\(n).jpg"
                if let bytes = Data(base64Encoded: b64) { try? bytes.write(to: imageDir.appendingPathComponent(name)) }
                d["data"] = "<\(name)>"
            }
            if let info = d["serverInfo"] as? [String: Any] {
                var i = info
                if i["version"] != nil { i["version"] = "<version>" }
                d["serverInfo"] = i
            }
            return d
        }
        guard
            let out = try? JSONSerialization.data(
                withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
            var s = String(data: out, encoding: .utf8)
        else { lines.append("UNENCODABLE"); continue }
        s = s.replacingOccurrences(of: work, with: "<WORK>")
        s = s.replacingOccurrences(
            of: #"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)"#, with: "<TIME>",
            options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"frames  \d+(\.\d+)?s"#, with: "frames  <SECONDS>s", options: .regularExpression)
        lines.append(s)
    }
    print(lines.joined(separator: "\n"))
    return 0
}

func walk(_ v: Any, _ f: ([String: Any]) -> [String: Any]) -> Any {
    if let d = v as? [String: Any] { return f(d).mapValues { walk($0, f) } }
    if let a = v as? [Any] { return a.map { walk($0, f) } }
    return v
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "imgdiff":
    guard args.count == 5, let t = Int(args[2]), let m = Double(args[3]) else {
        fail("usage: imgdiff <threshold> <max-fraction> <diff-dir>")
    }
    exit(imgdiff(threshold: t, maxFraction: m, diffDir: URL(fileURLWithPath: args[4])))
case "mcpnorm":
    guard args.count == 4 else { fail("usage: mcpnorm <work-dir> <image-dir>") }
    exit(mcpnorm(work: args[2], imageDir: URL(fileURLWithPath: args[3])))
default:
    fail("usage: verify-tool imgdiff|mcpnorm …")
}
