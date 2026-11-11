import Foundation

extension Schema {
    private static let dof = ObjectSchema(
        "dof", "Depth of field.",
        [
            Field("focus", .number(min: 0, unit: "px"), "Distance in focus (default: camera→target)."),
            Field("blur", .number(min: 0, step: 0.5, unit: "px"), "Maximum blur radius.", default: 0),
            Field(
                "range", .number(min: 0.01, step: 0.05), "Fraction of the focus distance to reach full blur.",
                default: 0.5),
        ])

    private static let shake = ObjectSchema(
        "shake", "A decaying camera jolt (e.g. on a beat).",
        [
            Field("at", .number(min: 0, step: 0.01, unit: "s"), "Scene time of the jolt."),
            Field("y", .number(unit: "px"), "Vertical amplitude.", default: 8),
            Field("roll", .number(unit: "°"), "Roll amplitude.", default: 0.35),
            Field("decay", .number(min: 0, step: 0.5), "How fast it settles (per second).", default: 9),
            Field("freq", .number(min: 0, step: 0.5, unit: "Hz"), "Shake frequency.", default: 9),
            Field("duration", .number(min: 0, step: 0.05, unit: "s"), "Length of the jolt.", default: 0.6),
        ])

    public static let camera = ObjectSchema(
        "camera", "Perspective camera for 3D layers. Without one, 3D layers line up 1:1 with the 2D canvas.",
        [
            Field("position", .vector(labels: ["x", "y", "z"], unit: "px"), "Where the camera is."),
            Field("target", .vector(labels: ["x", "y", "z"], unit: "px"), "What it looks at."),
            Field("fov", .number(min: 5, max: 150, unit: "°"), "Vertical field of view.", default: 40),
            Field("roll", .number(unit: "°"), "Tilt of the horizon.", default: 0),
            Field("dof", .object(dof), "Depth of field.", label: "Depth of field"),
            Field("shake", .list(shake), "Jolts; keep the same list in every camera keyframe.", advanced: true),
            Field("near", .number(min: 0.01), "Near clip distance.", default: 1, advanced: true),
            Field("far", .number(min: 1), "Far clip distance.", default: 100_000, advanced: true),
        ])

    public static let fog = ObjectSchema(
        "fog", "Fades 3D layers into a colour with distance.",
        [
            Field("color", .color, "Fog colour (default: background).", default: "$bg"),
            Field("near", .number(min: 0, unit: "px"), "Distance where fog starts.", default: 1000),
            Field("far", .number(min: 0, unit: "px"), "Distance of full fog.", default: 5000),
        ])

    private static let vignette = ObjectSchema(
        "vignette", "Darkened corners.",
        [
            Field("amount", zeroToOne, "Strength.", default: 0.6),
            Field("softness", zeroToOne, "Width of the falloff.", default: 0.6),
        ])
    private static let bloom = ObjectSchema(
        "bloom", "Glow around bright areas (light pools, flashes).",
        [
            Field("intensity", .number(min: 0, step: 0.05), "Glow strength.", default: 0.5),
            Field(
                "threshold", .number(min: 0, step: 0.05), "Brightness where glow starts (white text is 0.9).",
                default: 1),
            Field("levels", .integer(min: 1, max: 6), "Glow size.", default: 5, advanced: true),
        ])
    private static let motionBlur = ObjectSchema(
        "motionBlur", "Averages several sub-frames for the 3D layer (export only; cost × samples).",
        [
            Field("samples", .integer(min: 1, max: 16), "Sub-frames per frame.", default: 3),
            Field("shutter", zeroToOne, "Shutter as a fraction of a frame (0.5 = 180°).", default: 0.5),
        ])
    private static let fade = ObjectSchema(
        "fade", "Fade from/to a colour at the start/end of the scene.",
        [
            Field("in", .number(min: 0, step: 0.05, unit: "s"), "Fade-in length.", default: 0),
            Field("out", .number(min: 0, step: 0.05, unit: "s"), "Fade-out length.", default: 0),
            Field("color", .color, "Fade colour (default: background).", default: "$bg"),
        ])

    public static let post = ObjectSchema(
        "post", "Final grade. Applies to the 3D layer and background; 2D layers stay crisp unless gradeOverlay.",
        [
            Field("exposure", .number(step: 0.1, unit: "stops"), "Brightness in stops.", default: 0),
            Field("contrast", .number(min: 0, step: 0.05), "1 = unchanged.", default: 1),
            Field("saturation", .number(min: 0, step: 0.05), "0 = black and white, 1 = unchanged.", default: 1),
            Field("tonemap", .bool, "Filmic highlight roll-off.", default: false),
            Field(
                "vignette", .numberOrObject(vignette), "Darkened corners: amount, or {amount, softness}.", default: 0),
            Field("grain", .number(min: 0, max: 0.5, step: 0.005), "Film grain (over everything).", default: 0),
            Field("bloom", .numberOrObject(bloom), "Glow: intensity, or {intensity, threshold}.", default: 0),
            Field(
                "motionBlur", .numberOrObject(motionBlur), "Sub-frame motion blur: samples, or {samples, shutter}.",
                label: "Motion blur", default: 1),
            Field("fade", .object(fade), "Fade in/out."),
            Field("gradeOverlay", .bool, "Also grade 2D layers.", default: false, advanced: true),
        ])

    private static let marker = ObjectSchema(
        "marker", "A named time; snap to it, and use marker(\"name\") in expressions.",
        [
            Field("name", .string(), "Unique name, e.g. \"lock\" or \"beat-3\"."),
            Field("t", .number(min: 0, step: 0.01, unit: "s"), "Scene time."),
            Field("color", .color, "Colour on the ruler."),
        ])

    private static let audio = ObjectSchema(
        "audio", "Reference audio (voiceover, music): plays with the scene and is mixed into exports.",
        [
            Field("src", .asset("audio"), "File in assets/ (wav, aiff, mp3, m4a)."),
            Field("offset", .number(step: 0.01, unit: "s"), "Scene time where the audio starts.", default: 0),
            Field(
                "trim", .number(min: 0, step: 0.01, unit: "s"), "Seconds skipped at the start of the file.", default: 0),
            Field("gain", .number(min: 0, max: 4, step: 0.05), "Volume multiplier.", default: 1),
            Field("fadeIn", .number(min: 0, step: 0.05, unit: "s"), "Fade-in length.", default: 0),
            Field("fadeOut", .number(min: 0, step: 0.05, unit: "s"), "Fade-out at the scene end.", default: 0),
            Field("mute", .bool, "Leave out of exports.", default: false),
        ])

    public static let sceneFields: [Field] = [
        Field(
            "duration", .number(min: 0.04, step: 0.1, unit: "s"), "Length of the scene.", default: 5, animatable: false),
        Field("background", .color, "Background colour.", default: "$bg"),
        Field(
            "size", .vector(labels: ["w", "h"], unit: "px"), "Override the project canvas for this scene.",
            animatable: false),
        Field("fps", .number(min: 1, max: 240), "Override the project frame rate.", animatable: false),
        Field("camera", .object(camera), "3D camera (keyframe the whole object to move it)."),
        Field("fog", .object(fog), "Distance fog for the 3D layer."),
        Field("post", .object(post), "Final grade, bloom, grain, motion blur, fades.", label: "Look"),
        Field(
            "markers", .list(marker), "Named times (scene_apply {\"op\":\"marker\",\"name\":\"lock\",\"t\":3.4}).",
            animatable: false),
        Field("audio", .object(audio), "Reference audio track.", animatable: false),
    ]
}
