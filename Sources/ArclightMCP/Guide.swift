import ArclightCore

/// The MCP guide. Property references are generated from `Schema` so they always match what the engine
/// accepts; only workflow, animation, ops, export and recipes are written by hand.
enum Guide {
    static let instructions = """
        Arclight renders motion graphics from JSON scenes stored in a project folder (*.arclight).
        Workflow: project_open/project_create → editor_state (is the editor open, what the user is looking at) → guide (once per session) → \
        scene_create with ALL layers in one call → render_frames (scale 0.25) to check → scene_apply with small ops for fixes → export.
        Read scenes with scene_get (compact outline); request full JSON only for layers you will edit. \
        Use theme tokens ($fg, $display, …) instead of literal colours/fonts so styles stay consistent. \
        Every call is shown to the user in the editor's AI panel (with one-click revert), so keep changes purposeful. \
        The user can leave notes for you while watching (editor_state lists open notes); do what they ask, then note_resolve with a short reply.
        """

    /// Topics in reading order. Layer-type topics and "scene"/"common"/"symbols" are generated.
    static var topicNames: [String] {
        ["overview", "animation", "common"] + Schema.nodes.map(\.type) + [
            "scene", "symbols", "ops", "export", "recipes",
        ]
    }

    /// Old topic names still answered.
    static let aliases: [String: [String]] = [
        "nodes": ["common", "text", "shape", "symbol", "image", "group"],
        "3d": ["repeater", "light", "scene"],
        "post": ["scene"],
        "instancer": ["repeater"],
        "assets": ["symbols", "image"],
        "artwork": ["symbols", "image"],
    ]

    static func topic(_ name: String) -> String? {
        if let a = aliases[name] { return a.compactMap(topic).joined(separator: "\n\n") }
        switch name {
        case "overview": return overview
        case "animation": return animation
        case "ops": return ops
        case "export": return export
        case "recipes": return recipes
        case "common": return Schema.transformReference
        case "scene": return Schema.sceneReference
        case "symbols": return symbols
        default:
            guard Schema.node(name) != nil else { return nil }
            return Schema.reference(type: name) + (notes[name].map { "\n\n" + $0 } ?? "")
        }
    }

    static var all: String { topicNames.compactMap(topic).joined(separator: "\n\n") }

    static let overview = """
        # Arclight scene format
        Units are pixels on the canvas (default 1920x1080; vertical projects are 1080x1920). Origin top-left, y down, rotation in degrees (clockwise).
        Scene: {"id","duration","background","camera","fog","post","nodes":[...]} — layers draw in list order (later = on top).
        Layer: flat JSON. Meta keys: id, type, parent (a group's id), name, in, out (scene seconds; layer-local time t starts at `in`).
        Every other key is a property — see guide(<type>) for each type's properties. Types: \(Schema.nodes.map(\.type).joined(separator: ", ")).
        Unknown or misspelled properties are rejected with a suggestion; put custom data in keys starting with "_".
        Colours: "#RRGGBB", "#RRGGBBAA", [r,g,b,a] (0-1), names, or a theme token like "$fg"; "$fg@25" is that token's colour at 25% alpha (0-100). Tokens can hold any value (fonts, numbers).
        3D layers (repeater, light, or "3d": true) render through the scene camera into a graded 3D layer; 2D layers overlay it, crisp.
        """

    static let animation = """
        # Animation
        Any property can be: a constant, keyframes, or an expression.
          Keyframes: {"k":[[t,value],[t,value,"ease"]]} — t in layer-local seconds. The ease on a keyframe shapes the segment ARRIVING at it.
            Numbers, arrays and colours interpolate; other values hold. Objects (e.g. the camera) interpolate field by field.
          Easings: linear, hold, spring, in/out/inOut + Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back (e.g. "outExpo"), or [x1,y1,x2,y2] bezier.
          Expression: {"expr":"JS"} — t (layer s), T (scene s), d (scene duration); in repeater "instance" also i (index) and n (count).
            Helpers: ease(name,x), clamp, lerp, smoothstep(a,b,x), rand(seed) (0-1, deterministic), noise(x), wiggle(freq,amp,seed),
            lamp(t,on) (switch-on with flicker), pick(i,n,frac,seed) (rank among exactly round(n*frac) chosen copies, or -1),
            litCount(id), instanceCount(id), litFraction(id) (live stats of a repeater, for counters).
        Good defaults: entrances 0.5-0.9 s with outExpo/outCubic, staggers 0.03-0.08 s, holds ≥ 1.5 s for reading.
        """

    static let ops = """
        # scene_apply ops (atomic batch; nothing is saved if any op or validation fails)
        {"op":"add","node":{...},"before"|"after":"id"}            insert (default on top)
        {"op":"set","id":"x" | "ids":[..], "size":140, "fill":null}  merge properties/meta; null removes
        {"op":"key","id":"x","prop":"opacity","keys":[[0,0],[0.5,1,"outCubic"]],"replace":false}  merge keyframes by time
        {"op":"remove","id"|"ids"}                                  also removes children
        {"op":"move","id":"x","before"|"after":"y" | "index":0}    reorder draw order
        {"op":"duplicate","id":"x","as":"y", ...overrides}         copies the subtree (children get "-y" suffix)
        {"op":"shift","id"|"ids","by":0.5}                           retime (in/out)
        {"op":"scene","duration":6,"background":"#111","name":"..","camera":{..},"fog":{..},"post":{..},"size":[w,h],"fps":30}  (null removes)
        Pass "rev" (from scene_get / the last result) to refuse writing over a newer edit made in the editor.
        """

    static let export = """
        # Export
        export {"scenes":["id"],"format":"mp4"|"hevc"|"prores","scale":1}
          mp4: H.264, opaque. hevc: smaller files. prores: ProRes 4444 .mov with transparency for overlaying in an NLE.
          Files go to <project>/exports/<scene>.<ext> unless out_dir is given.
        render_frames {"scene":"id","times":[0,1,2.5],"scale":0.25} returns one labelled contact-sheet image.
        """

    static var symbols: String {
        let all = Symbols.all()
        let packs = Dictionary(grouping: all, by: \.pack).sorted { $0.key < $1.key }
        var lines: [String] = ["# Symbols for repeater items and symbol layers ({\"symbol\":\"pack/name\"})"]
        for (pack, items) in packs {
            let names: [String] = items.map { $0.id.split(separator: "/").last.map(String.init) ?? $0.id }
            lines.append(pack + ": " + names.joined(separator: ", "))
        }
        lines.append(
            "Projects can add packs in symbols/*.json: {\"pack\":\"brand\",\"symbols\":[{\"id\":\"logo\",\"name\":\"Logo\",\"path\":\"<svg path d>\",\"rim\":\"<optional highlight path>\"}]}"
        )
        lines.append(
            "Or use a custom silhouette inline: {\"path\":\"M…\",\"rim\":\"M…\"}. The bottom of a symbol stands on the floor."
        )
        lines.append("")
        lines.append("# Making your own artwork")
        lines.append(
            "symbol_save {\"pack\":\"brand\",\"id\":\"logo\",\"path\":\"<svg path d>\"} — vector shapes (logos, icons, pictograms): crisp at any size, filled with theme colours, usable as a symbol layer or in repeaters. Prefer this for flat graphics."
        )
        lines.append(
            "asset_write {\"name\":\"badge.png\",\"svg\":\"<svg …>…</svg>\",\"width\":1200} or {\"name\":\"photo.jpg\",\"base64\":\"…\"} — raster images for image layers (multi-colour illustrations, gradients, photos). SVG is rendered to PNG."
        )
        lines.append("asset_import {\"path\":\"/abs/file.png\"} copies an existing file on this Mac.")
        return lines.joined(separator: "\n")
    }

    static let notes: [String: String] = [
        "text": """
        Count-up: "text":"{v}%", "value":{"k":[[0,0],[1.5,45,"outExpo"]]}, "tabular":true.
        Typewriter: "reveal":{"by":"char","stagger":0.045,"duration":0.01,"from":{"opacity":0}}.
        Slide up from behind a line: "reveal":{"by":"word","mask":true,"from":{"opacity":0,"y":60}}.
        """,
        "repeater": """
        Place the repeater on the floor with x/y/z (y = floor height, larger = lower on screen) and look at it with the scene camera,
        e.g. camera {"position":[960,-50,-400],"target":[1060,830,1500]} for a floor at y=830.
        Exact share lit, in a cascade that speeds up:
          "instance":{"lit":{"expr":"var r = pick(i, n, 0.45, 7); if (r < 0) return 0; return lamp(t, 1.85 + 1.5*Math.sqrt((r+1)/Math.round(n*0.45)));"}}
        Floors, light pools, cones, contact shadows and the ambient wash are all optional looks — add only what the style needs.
        """,
    ]

    static let recipes = """
        # Recipes
        Stat with a crowd: repeater (symbol basic/person, 45% lit via pick) + text "{v}%" whose value is
          {"expr":"Math.min(45, Math.ceil(45 * litCount('crowd') / Math.round(instanceCount('crowd') * 0.45)))"} so the number tracks the lights.
        Title card: text centred (align "center", x = width/2) with reveal by word + a line shape whose trim animates [0,0]→[0,1].
        Vertical short: project_update {"size":[1080,1920]} (or a scene override {"op":"scene","size":[1080,1920]}); keep text within x 80…1000.
        Dark backdrop behind type: rect 1920x1080 at 960,540 with a linear gradient fill from opaque top-left to transparent.
        """
}
