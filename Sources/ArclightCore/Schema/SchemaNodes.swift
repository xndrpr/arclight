import Foundation

extension Schema {
    public static let nodes: [NodeSchema] = [
        NodeSchema(
            type: "text", label: "Text", icon: "textformat",
            doc: "Type with kinetic reveals and count-ups. x is the align point; y is the top of the capitals.",
            fields: [
                Field(
                    "text", .string(multiline: true),
                    "Text. \"{v}\" is replaced by value (count-ups); \\n breaks lines.", default: "Text"),
                Field("font", .font, "Font (PostScript name or a theme token like $display).", default: "$display"),
                Field("size", .number(min: 1, unit: "px"), "Font size.", default: 100),
                Field("color", .color, "Text colour.", default: "$fg"),
                Field("align", .choice(["left", "center", "right"]), "Alignment around x.", default: "left"),
                Field("tracking", .number(step: 0.5, unit: "px"), "Extra space between letters.", default: 0),
                Field("lineHeight", .number(min: 0.1, step: 0.05), "Line spacing as a multiple of size.", default: 1.1),
                Field("uppercase", .bool, "Render in capitals.", default: false),
                Field(
                    "value", .number(step: 1), "Number shown where the text has {v}; animate it for a count-up.",
                    default: 0),
                Field("decimals", .integer(min: 0, max: 6), "Decimal places for {v}.", default: 0),
                Field("thousands", .string(), "Thousands separator for {v}, e.g. \" \" or \",\".", advanced: true),
                Field("tabular", .bool, "Fixed-width digits so counters don't jitter.", default: false),
                Field("reveal", .object(reveal), "Kinetic entrance (per char/word/line)."),
            ], is3D: false),
        NodeSchema(
            type: "shape", label: "Shape", icon: "square.on.circle",
            doc: "Rectangle, ellipse or line. Rect/ellipse are centred on x,y; a line starts at x,y.",
            fields: [
                Field(
                    "shape", .choice(["rect", "ellipse", "line"]), "Kind of shape.", default: "rect", animatable: false),
                Field("width", .number(min: 0, unit: "px"), "Width (rect/ellipse).", default: 200),
                Field("height", .number(min: 0, unit: "px"), "Height (rect/ellipse).", default: 200),
                Field("radius", .number(min: 0, unit: "px"), "Corner radius (rect).", default: 0),
                Field("fill", .paint, "Fill. " + gradientDoc, default: "$fg"),
                Field("stroke", .color, "Outline colour (line colour for lines)."),
                Field("strokeWidth", .number(min: 0, step: 0.5, unit: "px"), "Outline / line thickness.", default: 0),
                Field(
                    "to", .vector(labels: ["dx", "dy"], unit: "px"), "Line end, relative to its start.",
                    default: [200, 0]),
                Field(
                    "trim", .vector(labels: ["start", "end"]), "Visible part of a line, 0–1 (animate to draw on).",
                    default: [0, 1]),
                Field("cap", .choice(["butt", "round"]), "Line ends.", default: "butt"),
            ], is3D: false),
        NodeSchema(
            type: "symbol", label: "Symbol", icon: "star.square",
            doc:
                "One vector symbol from a symbol pack (the same ones repeaters use: \"basic/star\", \"chess/knight\", project/user packs), centred on x,y. Fill, opacity, transform and keyframes work like any 2D layer.",
            fields: [
                Field(
                    "symbol", .symbol, "Symbol id \"pack/name\" (see symbol_list).", default: .string(defaultSymbol),
                    animatable: false),
                Field(
                    "size", .number(min: 0, unit: "px"),
                    "Height of a full-height symbol (shorter symbols such as a pawn keep their proportion).",
                    default: 200),
                Field("fill", .color, "Colour.", default: "$fg"),
            ], is3D: false),
        NodeSchema(
            type: "image", label: "Image", icon: "photo",
            doc: "A picture from the project's assets/ folder, centred on x,y.",
            fields: [
                Field("src", .asset("image"), "File in assets/ (or an absolute path).", animatable: false),
                Field("width", .number(min: 1, unit: "px"), "Width (keeps aspect if height is unset)."),
                Field("height", .number(min: 1, unit: "px"), "Height (keeps aspect if width is unset)."),
            ], is3D: false),
        NodeSchema(
            type: "group", label: "Group", icon: "folder",
            doc: "Moves, fades and times its children together (children set \"parent\").", fields: [], is3D: false),
        NodeSchema(
            type: "repeater", label: "Repeater", icon: "circle.grid.3x3",
            doc:
                "Many copies of a symbol standing on a floor in 3D: crowds, fields of icons, charts of dots. Per-copy values via instance.",
            fields: [
                Field(
                    "layout", .choice(["grid", "scatter", "ring", "points"]), "Arrangement.", default: "grid",
                    animatable: false),
                Field("cols", .integer(min: 1), "Columns (grid).", default: 10),
                Field("rows", .integer(min: 1), "Rows (grid).", default: 10),
                Field("spacing", .numberOrVector(labels: ["x", "z"]), "Distance between copies (grid).", default: 100),
                Field("jitter", zeroToOne, "Random offset as a fraction of spacing (grid).", default: 0),
                Field("count", .integer(min: 0), "Number of copies (scatter, ring).", default: 100),
                Field(
                    "area", .vector(labels: ["w", "d"], unit: "px"), "Area to scatter over.", default: [1000, 1000]),
                Field("radius", .number(min: 0, unit: "px"), "Ring radius.", default: 300),
                Field("points", .json, "Explicit positions [[x,z], …] (points).", advanced: true),
                Field("seed", .number(step: 1), "Random seed for jitter, scatter and variant picks.", default: 1),
                Field("items", .list(item), "What each copy looks like (variants by weight)."),
                Field("color", .color, "Sprite colour.", default: "$fg"),
                Field("instance", .object(instance), "Per-copy values (expressions with i, n)."),
                Field(
                    "facing", .choice(["camera", "fixed"]), "Billboards face the camera, or keep their yaw.",
                    default: "camera"),
                Field("rim", .number(min: 0, step: 0.05), "Edge highlight strength on lit copies.", default: 0.8),
                Field("rimColor", .color, "Edge highlight colour.", default: "$fg"),
                Field("ground", .object(ground), "Floor.", canDisable: true),
                Field("ambient", .object(ambient), "Soft wash of light under the repeater.", canDisable: true),
                Field("pool", .object(pool), "Spotlight pool under lit copies.", canDisable: true),
                Field("contact", .object(contact), "Contact shadow under every copy.", canDisable: true),
                Field("cone", .object(cone), "Light cone above lit copies.", canDisable: true),
                Field("shadow", .object(shadow), "Silhouette shadow on the floor.", canDisable: true),
                Field("beam", .object(beam), "Soft light beam above lit copies.", canDisable: true),
            ], is3D: true),
        NodeSchema(
            type: "light", label: "Light", icon: "lightbulb",
            doc:
                "A single pool of light (and optional beam) on the floor at x,y,z. Number settings inside pool and beam can be keyframed on their own, e.g. \"intensity\": {\"k\": [[0, 0], [1, 1.2]]} (as in any layer's object settings).",
            fields: [
                Field("pool", .object(pool), "The light pool."),
                Field("beam", .object(beam), "Optional beam.", canDisable: true),
            ], is3D: true),
    ]

    /// Symbol a new symbol layer shows when none is given.
    public static let defaultSymbol = "basic/star"

    public static func node(_ type: String) -> NodeSchema? { nodes.first { $0.type == type } }

    /// Transform fields + the type's own fields.
    public static func fields(for type: String) -> [Field] { transform + (node(type)?.fields ?? []) }

    public static func field(_ type: String, _ name: String) -> Field? { fields(for: type).first { $0.name == name } }

    /// The keyframes of a number setting held directly inside a layer's object setting, e.g. the `{"k": …}` of
    /// `"pool": {"intensity": {"k": [[0, 0], [1, 1.2]]}}` on a light (`type` "light", `prop` "pool", `key`
    /// "intensity"). Nil when `value` isn't keyframes or the setting isn't an animatable number: then `{"k": …}` is
    /// left as it is. The evaluator and the inspector both decide with this.
    public static func nestedKeys(type: String, prop: String, key: String, _ value: JSONValue) -> [Keyframe]? {
        guard value.object?["k"] != nil, let f = field(type, prop)?.kind.objectSchema?.field(key),
            f.kind.isNumeric, f.animatable, case .keys(let ks)? = try? Prop(json: value)
        else { return nil }
        return ks
    }
}
