import Foundation

/// The fal.ai models Arclight knows how to call well: what each is for, roughly what it costs, and how its request
/// is shaped (models disagree on how a size is given). Prices are fal's list prices, checked 2026-11-16, for one
/// default-quality result; token-billed models are estimates. Any other fal id still works (sent Flux-style).
public enum ModelCatalog {
    public enum Kind: String, Codable, Sendable { case image, model3D }

    /// How a text-to-image model takes its size.
    public enum Sizing: Equatable, Sendable {
        /// `image_size: {width, height}`, both multiples of `multiple`, area within `area` (pixels).
        case pixels(multiple: Int, area: ClosedRange<Int>)
        /// `aspect_ratio` from `ratios` plus `resolution` (e.g. "1K").
        case aspect(ratios: [String], resolution: String)
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var label: String
        /// Rough price of one result in US dollars (default settings, about 1 MP for images).
        public var price: Double
        /// How the price is shown ("$0.03", "~$0.05", "$0.30").
        public var priceNote: String
        /// One line: what it's good at.
        public var bestFor: String
        public var speed: String
        /// Takes `background: "transparent"`.
        public var transparent = false
        public var seed = false
        public var sizing: Sizing = .pixels(multiple: 16, area: 65_536...4_194_304)
        /// Added to every request (quality defaults and the like).
        public var defaults: [String: JSONValue] = [:]
        /// 3D: the field the picture goes in, and whether it is a list.
        public var imageField = "image_url"
        public var imageList = false

        /// Over this a single result counts as expensive and the AI should ask first.
        public var expensive: Bool { kind == .image ? price > 0.06 : price > 0.35 }

        public var menuLabel: String { "\(label) · \(priceNote)" }
    }

    /// Lets Arclight choose per request (see `pick`).
    public static let auto = "auto"

    static let flexibleSize = Sizing.pixels(multiple: 16, area: 65_536...4_194_304)

    public static let images: [Entry] = [
        Entry(
            id: "bytedance/seedream/v5.5/text-to-image", kind: .image, label: "Seedream 5.5", price: 0.03,
            priceNote: "$0.03", bestFor: "photoreal objects, people, textures; transparent cut-outs", speed: "~10 s",
            transparent: true, sizing: .pixels(multiple: 16, area: 921_600...4_624_220)),
        Entry(
            id: "openai/gpt-image-2.6/flare/text-to-image", kind: .image, label: "GPT Image 2.6", price: 0.05,
            priceNote: "~$0.05", bestFor: "exact prompts, lettering, layouts, transparent assets", speed: "~30 s",
            transparent: true, sizing: .pixels(multiple: 16, area: 655_360...8_294_400),
            defaults: ["quality": "high"]),
        Entry(
            id: "fal-ai/z-image/turbo", kind: .image, label: "Z-Image Turbo", price: 0.005, priceNote: "$0.005",
            bestFor: "fast, very cheap drafts and look exploration", speed: "~2 s", seed: true),
        Entry(
            id: "fal-ai/flux-2/klein/4b", kind: .image, label: "FLUX.2 klein", price: 0.009, priceNote: "$0.009",
            bestFor: "cheap drafts with good composition", speed: "~2 s", seed: true),
        Entry(
            id: "fal-ai/flux-2-pro", kind: .image, label: "FLUX.2 pro", price: 0.03, priceNote: "$0.03/MP",
            bestFor: "cinematic scenes and backgrounds", speed: "~8 s", seed: true),
        Entry(
            id: "blackforestlabs/flux-3/text-to-image", kind: .image, label: "FLUX.3", price: 0.048,
            priceNote: "$0.048", bestFor: "highest-detail environments and plates", speed: "~10 s",
            sizing: .aspect(
                ratios: ["21:9", "2:1", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16", "1:2"],
                resolution: "1k")),
        Entry(
            id: "google/nano-banana-2.1", kind: .image, label: "Nano Banana 2.1", price: 0.04, priceNote: "~$0.04",
            bestFor: "following complex scene descriptions", speed: "~15 s", seed: true,
            sizing: .aspect(
                ratios: ["21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"], resolution: "1K")),
        Entry(
            id: "fal-ai/recraft/v4.1/text-to-image", kind: .image, label: "Recraft V4.1", price: 0.035,
            priceNote: "$0.035", bestFor: "illustration, flat graphics, icons", speed: "~8 s"),
        Entry(
            id: "fal-ai/flux/dev", kind: .image, label: "FLUX.1 dev (legacy)", price: 0.025, priceNote: "$0.025/MP",
            bestFor: "older default; superseded by FLUX.2", speed: "~5 s", seed: true),
    ]

    public static let models3D: [Entry] = [
        Entry(
            id: "fal-ai/trellis", kind: .model3D, label: "Trellis", price: 0.02, priceNote: "$0.02",
            bestFor: "drafts, background props, many copies; rough up close", speed: "~30 s"),
        Entry(
            id: "fal-ai/trellis-2", kind: .model3D, label: "Trellis 2", price: 0.30, priceNote: "$0.30",
            bestFor: "hero objects: clean shape, PBR textures", speed: "~1 min",
            defaults: ["resolution": 1024, "texture_size": 2048]),
        Entry(
            id: "tripo3d/tripo/v2.5/image-to-3d", kind: .model3D, label: "Tripo 2.5", price: 0.30, priceNote: "$0.30",
            bestFor: "characters and creatures, tidy topology", speed: "~1 min", defaults: ["texture": "standard"]),
        Entry(
            id: "fal-ai/hunyuan3d-v3/image-to-3d", kind: .model3D, label: "Hunyuan 3D 3", price: 0.375,
            priceNote: "$0.375", bestFor: "most detailed geometry for close-ups", speed: "~2 min",
            imageField: "input_image_url"),
        Entry(
            id: "fal-ai/hyper3d/rodin/v2", kind: .model3D, label: "Rodin Gen-2", price: 0.40, priceNote: "$0.40",
            bestFor: "product-grade models with 4K textures", speed: "~2 min", imageField: "input_image_urls",
            imageList: true),
        Entry(
            id: "fal-ai/meshy/v6/image-to-3d", kind: .model3D, label: "Meshy 6", price: 0.80, priceNote: "$0.80",
            bestFor: "rigged, animatable characters (expensive)", speed: "~2 min"),
    ]

    public static var all: [Entry] { images + models3D }

    public static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// Default picks when the setting is Auto.
    public static let defaultImage = "bytedance/seedream/v5.5/text-to-image"
    public static let defaultModel3D = "fal-ai/trellis-2"

    /// What an image is for; Auto picks the model from it.
    public enum Purpose: String, CaseIterable, Sendable {
        case photo, draft, graphic, illustration, background
    }

    /// The model Auto uses for `purpose` (transparent cut-outs go to a model that makes them natively).
    public static func pick(_ purpose: Purpose?, transparent: Bool) -> String {
        switch purpose {
        case .draft?: return transparent ? defaultImage : "fal-ai/z-image/turbo"
        case .graphic?: return "openai/gpt-image-2.6/flare/text-to-image"
        case .illustration?: return transparent ? "openai/gpt-image-2.6/flare/text-to-image" : "fal-ai/recraft/v4.1/text-to-image"
        case .background?: return transparent ? defaultImage : "fal-ai/flux-2-pro"
        case .photo?, nil: return defaultImage
        }
    }

    /// Models to try after `id` fails with a request error (bad input, gone): one other good model, then a cheap one.
    public static func fallbacks(after id: String, transparent: Bool) -> [String] {
        let chain =
            transparent
            ? [defaultImage, "openai/gpt-image-2.6/flare/text-to-image"]
            : [defaultImage, "fal-ai/flux-2-pro", "fal-ai/z-image/turbo"]
        return Array(chain.filter { $0 != id }.prefix(2))
    }

    /// 3D: Auto uses Trellis 2, or the cheap Trellis for drafts.
    public static func pick3D(draft: Bool) -> String { draft ? "fal-ai/trellis" : defaultModel3D }

    /// A short table of the catalog for agents (image_status), cheapest first.
    public static func summary(_ kind: Kind) -> String {
        (kind == .image ? images : models3D).sorted { $0.price < $1.price }.map {
            "  \($0.id) — \($0.label), \($0.priceNote)\($0.expensive ? " (expensive: ask first)" : ""): \($0.bestFor)"
                + ($0.transparent ? " [transparent]" : "")
        }.joined(separator: "\n")
    }

    // MARK: Sizes

    /// `width`×`height` scaled (keeping the aspect) into the model's pixel limits, in multiples of `multiple`.
    static func fit(_ width: Int, _ height: Int, multiple m: Int, area: ClosedRange<Int>) -> (Int, Int) {
        var w = Double(max(width, 1)), h = Double(max(height, 1))
        let a = w * h
        if a < Double(area.lowerBound) {
            let k = (Double(area.lowerBound) / a).squareRoot(); w *= k; h *= k
        } else if a > Double(area.upperBound) {
            let k = (Double(area.upperBound) / a).squareRoot(); w *= k; h *= k
        }
        // Round up when that keeps it under the cap (so the floor is never missed), else down.
        func snap(_ v: Double, up: Bool) -> Int { max(m, Int((up ? (v / Double(m)).rounded(.up) : (v / Double(m)).rounded(.down))) * m) }
        var (sw, sh) = (snap(w, up: true), snap(h, up: true))
        if sw * sh > area.upperBound { (sw, sh) = (snap(w, up: false), snap(h, up: false)) }
        return (sw, sh)
    }

    /// The listed ratio closest to `width`/`height` (by log distance).
    static func nearestRatio(_ width: Int, _ height: Int, in ratios: [String]) -> String {
        let target = log(Double(max(width, 1)) / Double(max(height, 1)))
        func value(_ r: String) -> Double {
            let p = r.split(separator: ":").compactMap { Double($0) }
            return p.count == 2 && p[1] > 0 ? log(p[0] / p[1]) : 0
        }
        return ratios.min { abs(value($0) - target) < abs(value($1) - target) } ?? "1:1"
    }
}
