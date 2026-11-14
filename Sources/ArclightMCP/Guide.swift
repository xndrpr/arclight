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
        YouTube thumbnails (thumbnails) live in the same project: thumbnail_create with ALL artboards and layers in one call → \
        thumbnail_render (feed:true) to check → thumbnail_apply for fixes → export {thumbnail, format:"youtube"}. See guide("thumbnails").
        For a new scene from a description, settle the direction with the user before the full build: brief → look → storyboard → motion feel, \
        each a cheap draft they choose from. See guide("direction").
        """

    /// Topics in reading order. Layer-type topics and "scene"/"common"/"symbols" are generated.
    static var topicNames: [String] {
        ["overview", "animation", "common"] + Schema.nodes.map(\.type) + [
            "scene", "symbols", "ops", "export", "direction", "thumbnails", "recipes",
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
        "previews": ["thumbnails"],
        "effects": ["thumbnails"],
        "ai": ["thumbnails"],
        "images": ["thumbnails", "image"],
        "thumbnail": ["thumbnails"],
        "preview": ["thumbnails"],
        "storyboard": ["direction"],
        "styleframes": ["direction"],
        "look": ["direction"],
    ]

    static func topic(_ name: String) -> String? {
        if let a = aliases[name] { return a.compactMap(topic).joined(separator: "\n\n") }
        switch name {
        case "overview": return overview
        case "animation": return animation
        case "ops": return ops
        case "export": return export
        case "recipes": return recipes
        case "direction": return direction
        case "thumbnails": return thumbnails
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

    static let direction = """
        # Direction: decide early, build once
        A description leaves the style open, and a full build takes long to judge. So for a new scene (or a big restyle) agree on the \
        direction in cheap steps first, and build the real thing only after that. Skip the stages the user turned off \
        (the chat says which, in <direction>), skip everything when they say "just build it" or ask for a small change, \
        and never repeat a stage they already settled.
        Each stage ends with ONE question. In the in-app chat, ask it with ask_choice and stop: the user answers by clicking. \
        Elsewhere, show the renders and ask in a short message, then wait for the answer. \
        Drafts are hidden from the editor's scene list on purpose: in the chat the user sees them only on the ask_choice card \
        (they can open each option large there), so never export files or make normal scenes just to show options.

        1. Brief (stage "brief"): 3 short lines on how you read the idea: mood and references, structure (beats), length and format. \
           ask_choice with no options: the user confirms it or writes what to change.
        2. Look (stage "look"): 3 style frames (2 for a tight brief, 4 at most): the key moment of the scene as ONE still, each a clearly \
           different direction (palette, type, composition, texture; not three shades of one idea). Each is a draft scene: \
           scene_create {id:"look-a", draft:true, duration:1, theme:{bg,fg,muted,accent,display,body…}, nodes} with at most ~10 layers and \
           no animation; style everything through tokens so the chosen theme carries over. theme_presets lists ready palettes to start from. \
           Render all of them in one render_frames call per draft (times:[0.5], scale 0.25) to check them yourself, fix what's broken, \
           then ask_choice with one option per draft: visual {scene:"look-a", time:0.5}, a 2–4 word title and a one-line note on the idea.
        3. Storyboard (stage "storyboard"): in the chosen look, 3–6 beats of the scene in order as ONE draft scene ("board") where each beat \
           holds still for 1 s (a group per beat with "in":n-1, "out":n). Real words, real layout, no motion yet. \
           ask_choice with one option: visual {scene:"board", times:[0.5, 1.5, …]}, title "Storyboard", note listing the beats. \
           If the user comments, change the board and ask again.
        4. Motion feel (stage "motion"): the hero element of the board animating in, 2–3 ways that differ in timing and character: \
           snappy (fast ease-out, ~0.35 s, slight overshoot), smooth (ease-in-out, ~0.8 s), playful (spring/bounce, staggered) — or what fits the brief. \
           Draft scenes "motion-a"… of 1.5–2 s with only that element. ask_choice with visual {scene:"motion-a", loop:true} per option.
        Then build: theme_set the chosen look's tokens on the project (so every scene shares them), scene_create the real scene with \
        copy_from "board" (drafts and their tokens are dropped from the copy) and animate the beats in the chosen motion style; \
        render_frames to check; finally scene_delete {drafts:true}.
        Keep the stages fast: drafts are small and still, one render call per draft, no export.
        """

    static let recipes = """
        # Recipes
        Stat with a crowd: repeater (symbol basic/person, 45% lit via pick) + text "{v}%" whose value is
          {"expr":"Math.min(45, Math.ceil(45 * litCount('crowd') / Math.round(instanceCount('crowd') * 0.45)))"} so the number tracks the lights.
        Title card: text centred (align "center", x = width/2) with reveal by word + a line shape whose trim animates [0,0]→[0,1].
        Vertical short: project_update {"size":[1080,1920]} (or a scene override {"op":"scene","size":[1080,1920]}); keep text within x 80…1000.
        Dark backdrop behind type: rect 1920x1080 at 960,540 with a linear gradient fill from opaque top-left to transparent.
        """

    static let thumbnails = """
        # Thumbnails (YouTube thumbnails)
        A thumbnail page (thumbnails/<id>.json) holds artboards: still images such as the 1280x720 thumbnail, its A/B variants and a 1080x1920 Shorts cover. \
        An artboard is {"id","name","size":[w,h],"x","y","background","post","nodes":[...]}; layers are exactly the scene nodes in guide(text), guide(image) and so on, \
        rendered at t=0 (no animation needed). Size presets: \(ArtboardPresets.names.joined(separator: ", ")).
        Theme and assets are shared with the motion scenes: use tokens ($fg, $accent, $display…) and the brand stays in sync. A page can take its own tokens with \
        "theme":{"detached":true,"tokens":{...}} (tokens it lacks still come from the project); "theme":"project" links it back.
        Tools: thumbnail_list · thumbnail_create · thumbnail_get (outline; artboard + ids for full JSON) · thumbnail_apply · thumbnail_render · thumbnail_delete · \
        thumbnail_variants · template_instantiate {thumbnail} · frame_extract · reference_add · reference_analyze · image_* · history {thumbnail} · export {thumbnail, artboards, format: youtube|jpg|png}.
        thumbnail_apply ops: the scene ops (add, set, key, remove, move, duplicate, scene) on the call's "artboard" (default: the first) or an op's own "artboard"; plus \
        artboard_add {id,name,size,x,y,background,copy_from}, artboard_set {id,…}, artboard_duplicate {id,as,name}, artboard_remove {id}, artboard_move {id,index}, thumbnail {name,theme}.
        Start fast: template_list {kind:"thumbnail"} → template_instantiate {template, thumbnail, params} (layouts: face + words, before/after, big number, reaction, product, minimal); \
        image params take an asset name (empty = a placeholder silhouette to swap later with thumbnail_apply set src).
        Variants for A/B tests (YouTube Test & Compare takes up to 3): thumbnail_variants {thumbnail, artboard, variants:[{name, ops}]} or {auto:"color"|"zoom"|"background", count} — \
        change ONE thing per variant (the words, the accent colour, the crop) so the test says what worked.
        Pictures: frame_extract {video, best:3} picks the sharpest frames with the best faces (or times:[…]; or scene + times for a motion scene), and with thumbnail places one as a full-bleed background.
        References: reference_add {thumbnail, source: YouTube URL | image} keeps a thumbnail the user likes; reference_analyze {asset} returns its palette, text, faces, focus and layout notes. \
        Rebuild its structure with the user's own photos, theme and words — never copy someone else's artwork or text.
        Thumbnail rules that hold up in the feed (always check with thumbnail_render feed:true; most viewers see it about 360 px wide):
        - One focal point: a large face or object filling a third or more of the frame, cut out with a strong outline or glow if the background is busy.
        - 3–5 words at most, very heavy display font, 110 px or more on a 1280x720 artboard; never repeat the video title word for word.
        - High contrast: light text on dark or the reverse, plus one accent colour. Avoid thin strokes and small detail.
        - Keep the bottom-right corner (about 20% x 15%) free of anything important: YouTube's timestamp badge covers it.
        - Leave a margin of about 40 px; the feed rounds the corners.
        Export {thumbnail, format:"youtube"} writes 1280x720 JPGs under YouTube's 2 MB limit to <project>/exports/<thumbnail>_<artboard>.jpg.

        # AI pixels (image_status says what's available)
        - image_remove_bg {layer} — on-device and free: cut a person/object out of a photo, then add effects.outline for the sticker look.
        - image_select_subject {layer} — the subject's box in canvas px (place text beside it, or use it as an image_fill rect).
        - With the user's fal.ai key: image_generate {prompt} (a new picture; no words in it — use text layers), image_fill {rect|area_layer, prompt}
          (repaint an area: remove or add things; result is a new layer), image_expand {layer, left/top/right/bottom} (outpaint a tight photo to 16:9),
          image_upscale {layer, factor}. If they return "image generation is off", tell the user they can add a key in Settings ▸ AI.
        - All take scene, or thumbnail + artboard. Results are new assets plus normal layer edits (revertible via history).

        # Layer effects (text, shape, symbol and image layers — in thumbnails and motion scenes alike)
        - "blend": "multiply" | "screen" | "overlay" | "softLight" | "add" | "color" — mixes with everything below, background included.
        - "clip": true — the layer only shows inside the layer directly below it (several clip layers in a row share that base).
        - "mask": {"node":"shapeId","mode":"alpha"|"luma","invert":false} — show the layer only where another layer is; the mask layer isn't drawn.
        - "effects": {"outline":{"color":"#FFF","width":12},"dropShadow":{"color":"#000","x":0,"y":12,"blur":24,"opacity":0.6},"glow":{"color":"$accent","radius":30,"intensity":1},"blur":0}
          Outline is the cut-out sticker look for people and objects on thumbnails; widths and blurs are in canvas px.
        - "adjust": {"brightness":0,"contrast":1,"saturation":1,"hue":0,"temperature":0}
        - Images: "fit":"cover"|"contain" with both width and height; "crop":[x,y,w,h] as fractions of the picture.
        """
}
