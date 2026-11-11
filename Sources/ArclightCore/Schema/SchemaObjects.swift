import Foundation

/// The registry: every layer type, every property, every nested object.
public enum Schema {
    static let zeroToOne = FieldKind.number(min: 0, max: 1, step: 0.01)

    public static let transform: [Field] = [
        Field("x", .number(unit: "px"), "Horizontal position (canvas pixels, from the left).", default: 0),
        Field(
            "y", .number(unit: "px"), "Vertical position (canvas pixels, from the top; y grows downward).", default: 0),
        Field("z", .number(unit: "px"), "Depth for 3D layers (away from the viewer).", default: 0, advanced: true),
        Field("scale", .numberOrVector(labels: ["x", "y"]), "Size multiplier: 1, or [sx, sy].", default: 1),
        Field("rotation", .number(unit: "°"), "Rotation in degrees, clockwise.", default: 0),
        Field(
            "rotationX", .number(unit: "°"), "Tilt around the horizontal axis (3D).", label: "Rotation X", default: 0,
            advanced: true),
        Field(
            "rotationY", .number(unit: "°"), "Turn around the vertical axis (3D).", label: "Rotation Y", default: 0,
            advanced: true),
        Field(
            "anchor", .vector(labels: ["x", "y"], unit: "px"),
            "Pivot point for rotation and scale, in layer pixels. x,y position the anchor point, so changing anchor alone shifts the drawing; to scale a bar from its bottom edge, put y at the bottom edge and anchor at [0, h/2].",
            default: [0, 0], advanced: true),
        Field("opacity", zeroToOne, "0 = invisible, 1 = solid. Multiplies down to children.", default: 1),
        Field("visible", .bool, "Hide the layer without deleting it.", default: true, animatable: false),
        Field(
            "3d", .bool, "Render through the scene camera into the 3D layer (inherited by children).", label: "3D",
            default: false, animatable: false, advanced: true),
    ]

    static let revealFrom = ObjectSchema(
        "from", "Where each unit starts before animating to its rest state.",
        [
            Field("opacity", zeroToOne, "Starting opacity.", default: 0),
            Field("x", .number(unit: "px"), "Starting horizontal offset.", default: 0),
            Field("y", .number(unit: "px"), "Starting vertical offset (positive = from below).", default: 40),
            Field("scale", .number(step: 0.01), "Starting scale.", default: 1),
            Field("rotation", .number(unit: "°"), "Starting rotation.", default: 0),
            Field("skew", .number(unit: "°"), "Starting slant, easing to upright.", default: 0),
        ])

    static let reveal = ObjectSchema(
        "reveal", "Kinetic entrance: animates characters, words or lines one after another.",
        [
            Field("by", .choice(["char", "word", "line"]), "Unit that animates.", default: "char"),
            Field("stagger", .number(min: 0, step: 0.005, unit: "s"), "Delay between units.", default: 0.04),
            Field(
                "duration", .number(min: 0, step: 0.05, unit: "s"), "Duration of each unit's animation.", default: 0.6),
            Field(
                "delay", .number(step: 0.05, unit: "s"), "Wait before the first unit starts (layer time).", default: 0),
            Field("ease", .easing, "Easing curve.", default: "outExpo"),
            Field("from", .object(revealFrom), "Start state of each unit."),
            Field("mask", .bool, "Clip each line to its own box (slide up from behind a line).", default: false),
            Field(
                "order", .choice(["forward", "reverse", "center", "random"]), "Order in which units start.",
                default: "forward"),
        ])

    static let gradientDoc =
        "A colour, or a gradient: {\"linear\":[x0,y0,x1,y1] | \"radial\":[cx,cy,r], \"stops\":[[0,\"#000\"],[1,\"#0000\"]]} in layer pixels from the centre."

    static let item = ObjectSchema(
        "item", "One kind of sprite in a repeater. Variants are picked randomly by weight.",
        [
            Field(
                "symbol", .symbol,
                "Vector symbol, e.g. \"basic/person\", \"chess/knight\", or one from a project/user pack."),
            Field("height", .number(min: 1, unit: "px"), "Height in world pixels.", default: 100),
            Field(
                "weight", .number(min: 0, step: 0.1), "How often this variant appears relative to the others.",
                default: 1),
            Field("widthScale", .number(min: 0.1, step: 0.05), "Narrow (<1) or widen (>1) the silhouette.", default: 1),
            Field(
                "rim", .bool, "Set false to drop the symbol's edge highlight.", default: true, animatable: false,
                advanced: true),
            Field(
                "rimWidth", .number(min: 0, step: 0.005), "Highlight stroke width as a fraction of height.",
                default: 0.025, advanced: true),
            Field(
                "path", .string(), "Custom SVG path data instead of a symbol (bottom stands on the floor).",
                advanced: true),
            Field(
                "fillRule", .choice(["nonzero", "evenodd"]), "Fill rule for a custom path.", default: "nonzero",
                advanced: true),
            Field("glyph", .string(), "A text character or emoji instead of a symbol.", advanced: true),
            Field("font", .font, "Font for a glyph.", advanced: true),
            Field("src", .asset("image"), "An image file instead of a symbol.", advanced: true),
            Field("shape", .choice(["ellipse", "rect"]), "A plain shape instead of a symbol.", advanced: true),
            Field("width", .number(min: 1, unit: "px"), "Width of a plain shape.", advanced: true),
            Field("piece", .choice(ChessPieces.names), "Legacy alias for symbol \"chess/<piece>\".", advanced: true),
        ])

    static let instance = ObjectSchema(
        "instance", "Per-copy values. Use expressions with i (index) and n (count) to vary each copy.",
        [
            Field("x", .number(unit: "px"), "Offset along the floor's x."),
            Field("y", .number(unit: "px"), "Offset up/down (negative = up)."),
            Field("z", .number(unit: "px"), "Offset along the floor's depth."),
            Field("scale", .number(step: 0.01), "Size multiplier."),
            Field("opacity", zeroToOne, "Opacity multiplier."),
            Field(
                "lit", .number(min: 0, max: 2, step: 0.01), "0 = dark, 1 = lit (pools, cones, rim light), >1 = flash."),
            Field("variant", .integer(min: 0), "Index into items (overrides the random pick)."),
            Field("color", .color, "Tint for this copy."),
            Field("yaw", .number(unit: "°"), "Turn for facing \"fixed\"."),
            Field("rotation", .number(unit: "°"), "Same as yaw.", advanced: true),
            Field("visible", .bool, "Hide this copy."),
        ])

    private static let checker = ObjectSchema(
        "checker", "Checkerboard on the floor, cells centred on grid positions.",
        [
            Field("size", .number(min: 1, unit: "px"), "Cell size (default: grid spacing)."),
            Field("color", .color, "Colour of the lighter cells.", default: "$fg"),
            Field("opacity", zeroToOne, "Strength of the lighter cells.", default: 0.045),
        ])

    static let ground = ObjectSchema(
        "ground", "Floor plane under a repeater.",
        [
            Field("color", .color, "Floor colour.", default: "#0B0B0B"),
            Field(
                "size", .vector(labels: ["w", "d"], unit: "px"), "Floor size (default: fits the layout).",
                advanced: true),
            Field("checker", .object(checker), "Optional checkerboard.", canDisable: true),
        ])

    static let ambient = ObjectSchema(
        "ambient", "Soft wash of light under the whole repeater, growing as more copies are lit.",
        [
            Field("intensity", .number(min: 0, step: 0.005), "Base brightness.", default: 0.035),
            Field("grow", .number(min: 0, step: 0.005), "Extra brightness × fraction lit.", default: 0.07),
            Field("radius", .number(min: 1, unit: "px"), "Size of the wash (default: fits the layout)."),
            Field("color", .color, "Light colour.", default: "$fg"),
            Field(
                "center", .vector(labels: ["x", "z"], unit: "px"), "Centre on the floor (default: layout centre).",
                advanced: true),
        ])

    private static let spill = ObjectSchema(
        "spill", "Wide faint glow around each pool that lifts neighbouring silhouettes.",
        [
            Field("radius", .number(min: 1, step: 0.1), "Size as a multiple of the pool radius.", default: 3),
            Field("intensity", .number(min: 0, step: 0.01), "Brightness.", default: 0.16),
        ])

    static let pool = ObjectSchema(
        "pool", "Spotlight pool on the floor under each lit copy (additive, blooms).",
        [
            Field("radius", .number(min: 1, unit: "px"), "Pool radius.", default: 44),
            Field("color", .color, "Light colour.", default: "#FFFFFF"),
            Field("intensity", .number(min: 0, step: 0.05), "Brightness (above 1 glows with bloom).", default: 1.2),
            Field("softness", zeroToOne, "Edge softness (0 = hard disc, 1 = all falloff).", default: 0.5),
            Field("falloff", .number(min: 0, step: 0.1), "How quickly it fades from the centre.", default: 1),
            Field("spill", .object(spill), "Optional wide glow.", canDisable: true),
        ])

    static let contact = ObjectSchema(
        "contact", "Dark disc under every copy, as if lit from straight above.",
        [
            Field("radius", .number(min: 0, step: 0.01), "Radius as a fraction of item height.", default: 0.17),
            Field("opacity", zeroToOne, "Darkness.", default: 0.85),
            Field("softness", zeroToOne, "Edge softness.", default: 0.3),
        ])

    static let cone = ObjectSchema(
        "cone", "Light cone from a lamp above each lit copy down to its pool.",
        [
            Field("height", .number(min: 0.5, step: 0.1), "Lamp height as a multiple of item height.", default: 5.4),
            Field("radius", .number(min: 1, unit: "px"), "Cone base radius (default: pool radius)."),
            Field("intensity", .number(min: 0, step: 0.05), "Brightness.", default: 1),
            Field("color", .color, "Light colour.", default: "$fg"),
        ])

    static let shadow = ObjectSchema(
        "shadow", "Silhouette laid on the floor, pointing away from the light.",
        [
            Field("opacity", zeroToOne, "Darkness.", default: 0.6),
            Field("length", .number(min: 0, step: 0.05), "Length as a multiple of item height.", default: 1),
            Field("angle", .number(unit: "°"), "Direction on the floor (0 = away from camera).", default: 0),
            Field("litOnly", .bool, "Only lit copies cast shadows.", default: true),
        ])

    static let beam = ObjectSchema(
        "beam", "Soft billboard light beam above each lit copy (lighter than cone).",
        [
            Field("height", .number(min: 1, unit: "px"), "Beam height.", default: 900),
            Field("width", .number(min: 1, unit: "px"), "Beam width.", default: 160),
            Field("intensity", .number(min: 0, step: 0.01), "Brightness.", default: 0.12),
            Field("color", .color, "Light colour.", default: "#FFFFFF"),
        ])

}
