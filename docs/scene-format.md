# Arclight scene format

Generated from the schema in `Sources/ArclightCore/Schema/`. Do not edit by hand.

A colour is "#RRGGBB", "#RRGGBBAA", [r, g, b, a] (0–1), a name, a theme token such as "$fg", or a token colour at NN % alpha (0–100) such as "$fg@25".

## Common properties

| Property | Kind | Default | Description |
|---|---|---|---|
| `x` | number (px) | `0` | Horizontal position (canvas pixels, from the left). |
| `y` | number (px) | `0` | Vertical position (canvas pixels, from the top; y grows downward). |
| `z` | number (px) | `0` | Depth for 3D layers (away from the viewer). |
| `scale` | number or [x, y] | `1` | Size multiplier: 1, or [sx, sy]. |
| `rotation` | number (°) | `0` | Rotation in degrees, clockwise. |
| `rotationX` | number (°) | `0` | Tilt around the horizontal axis (3D). |
| `rotationY` | number (°) | `0` | Turn around the vertical axis (3D). |
| `anchor` | [x, y] | `[0,0]` | Pivot point for rotation and scale, in layer pixels. x,y position the anchor point, so changing anchor alone shifts the drawing; to scale a bar from its bottom edge, put y at the bottom edge and anchor at [0, h/2]. |
| `opacity` | number | `1` | 0 = invisible, 1 = solid. Multiplies down to children. |
| `visible` | bool | `true` | Hide the layer without deleting it. Not animatable. |
| `3d` | bool | `false` | Render through the scene camera into the 3D layer (inherited by children). Not animatable. |

## `text` — Text

Type with kinetic reveals and count-ups. x is the align point; y is the top of the capitals.

| Property | Kind | Default | Description |
|---|---|---|---|
| `text` | string | `"Text"` | Text. "{v}" is replaced by value (count-ups); \n breaks lines. |
| `font` | font | `"$display"` | Font (PostScript name or a theme token like $display). |
| `size` | number (px) | `100` | Font size. |
| `color` | color | `"$fg"` | Text colour. |
| `align` | "left"\|"center"\|"right" | `"left"` | Alignment around x. |
| `tracking` | number (px) | `0` | Extra space between letters. |
| `lineHeight` | number | `1.1` | Line spacing as a multiple of size. |
| `uppercase` | bool | `false` | Render in capitals. |
| `value` | number | `0` | Number shown where the text has {v}; animate it for a count-up. |
| `decimals` | integer | `0` | Decimal places for {v}. |
| `thousands` | string |  | Thousands separator for {v}, e.g. " " or ",". |
| `tabular` | bool | `false` | Fixed-width digits so counters don't jitter. |
| `reveal` | {reveal} |  | Kinetic entrance (per char/word/line). |

## `shape` — Shape

Rectangle, ellipse or line. Rect/ellipse are centred on x,y; a line starts at x,y.

| Property | Kind | Default | Description |
|---|---|---|---|
| `shape` | "rect"\|"ellipse"\|"line" | `"rect"` | Kind of shape. Not animatable. |
| `width` | number (px) | `200` | Width (rect/ellipse). |
| `height` | number (px) | `200` | Height (rect/ellipse). |
| `radius` | number (px) | `0` | Corner radius (rect). |
| `fill` | color or gradient | `"$fg"` | Fill. A colour, or a gradient: {"linear":[x0,y0,x1,y1] | "radial":[cx,cy,r], "stops":[[0,"#000"],[1,"#0000"]]} in layer pixels from the centre. |
| `stroke` | color |  | Outline colour (line colour for lines). |
| `strokeWidth` | number (px) | `0` | Outline / line thickness. |
| `to` | [dx, dy] | `[200,0]` | Line end, relative to its start. |
| `trim` | [start, end] | `[0,1]` | Visible part of a line, 0–1 (animate to draw on). |
| `cap` | "butt"\|"round" | `"butt"` | Line ends. |

## `symbol` — Symbol

One vector symbol from a symbol pack (the same ones repeaters use: "basic/star", "chess/knight", project/user packs), centred on x,y. Fill, opacity, transform and keyframes work like any 2D layer.

| Property | Kind | Default | Description |
|---|---|---|---|
| `symbol` | symbol id | `"basic/star"` | Symbol id "pack/name" (see symbol_list). Not animatable. |
| `size` | number (px) | `200` | Height of a full-height symbol (shorter symbols such as a pawn keep their proportion). |
| `fill` | color | `"$fg"` | Colour. |

## `image` — Image

A picture from the project's assets/ folder, centred on x,y.

| Property | Kind | Default | Description |
|---|---|---|---|
| `src` | image file |  | File in assets/ (or an absolute path). Not animatable. |
| `width` | number (px) |  | Width (keeps aspect if height is unset). |
| `height` | number (px) |  | Height (keeps aspect if width is unset). |

## `group` — Group

Moves, fades and times its children together (children set "parent").

_Only the common properties._

## `repeater` — Repeater

Many copies of a symbol standing on a floor in 3D: crowds, fields of icons, charts of dots. Per-copy values via instance.

| Property | Kind | Default | Description |
|---|---|---|---|
| `layout` | "grid"\|"scatter"\|"ring"\|"points" | `"grid"` | Arrangement. Not animatable. |
| `cols` | integer | `10` | Columns (grid). |
| `rows` | integer | `10` | Rows (grid). |
| `spacing` | number or [x, z] | `100` | Distance between copies (grid). |
| `jitter` | number | `0` | Random offset as a fraction of spacing (grid). |
| `count` | integer | `100` | Number of copies (scatter, ring). |
| `area` | [w, d] | `[1000,1000]` | Area to scatter over. |
| `radius` | number (px) | `300` | Ring radius. |
| `points` | JSON |  | Explicit positions [[x,z], …] (points). |
| `seed` | number | `1` | Random seed for jitter, scatter and variant picks. |
| `items` | [{item}] |  | What each copy looks like (variants by weight). |
| `color` | color | `"$fg"` | Sprite colour. |
| `instance` | {instance} |  | Per-copy values (expressions with i, n). |
| `facing` | "camera"\|"fixed" | `"camera"` | Billboards face the camera, or keep their yaw. |
| `rim` | number | `0.8` | Edge highlight strength on lit copies. |
| `rimColor` | color | `"$fg"` | Edge highlight colour. |
| `ground` | {ground} |  | Floor. `false` turns it off. |
| `ambient` | {ambient} |  | Soft wash of light under the repeater. `false` turns it off. |
| `pool` | {pool} |  | Spotlight pool under lit copies. `false` turns it off. |
| `contact` | {contact} |  | Contact shadow under every copy. `false` turns it off. |
| `cone` | {cone} |  | Light cone above lit copies. `false` turns it off. |
| `shadow` | {shadow} |  | Silhouette shadow on the floor. `false` turns it off. |
| `beam` | {beam} |  | Soft light beam above lit copies. `false` turns it off. |

## `light` — Light

A single pool of light (and optional beam) on the floor at x,y,z. Number settings inside pool and beam can be keyframed on their own, e.g. "intensity": {"k": [[0, 0], [1, 1.2]]} (as in any layer's object settings).

| Property | Kind | Default | Description |
|---|---|---|---|
| `pool` | {pool} |  | The light pool. |
| `beam` | {beam} |  | Optional beam. `false` turns it off. |

## Scene settings

| Property | Kind | Default | Description |
|---|---|---|---|
| `duration` | number (s) | `5` | Length of the scene. Not animatable. |
| `background` | color | `"$bg"` | Background colour. |
| `size` | [w, h] |  | Override the project canvas for this scene. Not animatable. |
| `fps` | number |  | Override the project frame rate. Not animatable. |
| `camera` | {camera} |  | 3D camera (keyframe the whole object to move it). |
| `fog` | {fog} |  | Distance fog for the 3D layer. |
| `post` | {post} |  | Final grade, bloom, grain, motion blur, fades. |
| `markers` | [{marker}] |  | Named times (scene_apply {"op":"marker","name":"lock","t":3.4}). Not animatable. |
| `audio` | {audio} |  | Reference audio track. Not animatable. |

### `camera` object

Perspective camera for 3D layers. Without one, 3D layers line up 1:1 with the 2D canvas.

| Property | Kind | Default | Description |
|---|---|---|---|
| `position` | [x, y, z] |  | Where the camera is. |
| `target` | [x, y, z] |  | What it looks at. |
| `fov` | number (°) | `40` | Vertical field of view. |
| `roll` | number (°) | `0` | Tilt of the horizon. |
| `dof` | {dof} |  | Depth of field. |
| `shake` | [{shake}] |  | Jolts; keep the same list in every camera keyframe. |
| `near` | number | `1` | Near clip distance. |
| `far` | number | `100000` | Far clip distance. |

### `dof` object

Depth of field.

| Property | Kind | Default | Description |
|---|---|---|---|
| `focus` | number (px) |  | Distance in focus (default: camera→target). |
| `blur` | number (px) | `0` | Maximum blur radius. |
| `range` | number | `0.5` | Fraction of the focus distance to reach full blur. |

### `shake` object

A decaying camera jolt (e.g. on a beat).

| Property | Kind | Default | Description |
|---|---|---|---|
| `at` | number (s) |  | Scene time of the jolt. |
| `y` | number (px) | `8` | Vertical amplitude. |
| `roll` | number (°) | `0.35` | Roll amplitude. |
| `decay` | number | `9` | How fast it settles (per second). |
| `freq` | number (Hz) | `9` | Shake frequency. |
| `duration` | number (s) | `0.6` | Length of the jolt. |

### `fog` object

Fades 3D layers into a colour with distance.

| Property | Kind | Default | Description |
|---|---|---|---|
| `color` | color | `"$bg"` | Fog colour (default: background). |
| `near` | number (px) | `1000` | Distance where fog starts. |
| `far` | number (px) | `5000` | Distance of full fog. |

### `post` object

Final grade. Applies to the 3D layer and background; 2D layers stay crisp unless gradeOverlay.

| Property | Kind | Default | Description |
|---|---|---|---|
| `exposure` | number (stops) | `0` | Brightness in stops. |
| `contrast` | number | `1` | 1 = unchanged. |
| `saturation` | number | `1` | 0 = black and white, 1 = unchanged. |
| `tonemap` | bool | `false` | Filmic highlight roll-off. |
| `vignette` | number or {vignette} | `0` | Darkened corners: amount, or {amount, softness}. |
| `grain` | number | `0` | Film grain (over everything). |
| `bloom` | number or {bloom} | `0` | Glow: intensity, or {intensity, threshold}. |
| `motionBlur` | number or {motionBlur} | `1` | Sub-frame motion blur: samples, or {samples, shutter}. |
| `fade` | {fade} |  | Fade in/out. |
| `gradeOverlay` | bool | `false` | Also grade 2D layers. |

### `vignette` object

Darkened corners.

| Property | Kind | Default | Description |
|---|---|---|---|
| `amount` | number | `0.6` | Strength. |
| `softness` | number | `0.6` | Width of the falloff. |

### `bloom` object

Glow around bright areas (light pools, flashes).

| Property | Kind | Default | Description |
|---|---|---|---|
| `intensity` | number | `0.5` | Glow strength. |
| `threshold` | number | `1` | Brightness where glow starts (white text is 0.9). |
| `levels` | integer | `5` | Glow size. |

### `motionBlur` object

Averages several sub-frames for the 3D layer (export only; cost × samples).

| Property | Kind | Default | Description |
|---|---|---|---|
| `samples` | integer | `3` | Sub-frames per frame. |
| `shutter` | number | `0.5` | Shutter as a fraction of a frame (0.5 = 180°). |

### `fade` object

Fade from/to a colour at the start/end of the scene.

| Property | Kind | Default | Description |
|---|---|---|---|
| `in` | number (s) | `0` | Fade-in length. |
| `out` | number (s) | `0` | Fade-out length. |
| `color` | color | `"$bg"` | Fade colour (default: background). |

### `marker` object

A named time; snap to it, and use marker("name") in expressions.

| Property | Kind | Default | Description |
|---|---|---|---|
| `name` | string |  | Unique name, e.g. "lock" or "beat-3". |
| `t` | number (s) |  | Scene time. |
| `color` | color |  | Colour on the ruler. |

### `audio` object

Reference audio (voiceover, music): plays with the scene and is mixed into exports.

| Property | Kind | Default | Description |
|---|---|---|---|
| `src` | audio file |  | File in assets/ (wav, aiff, mp3, m4a). |
| `offset` | number (s) | `0` | Scene time where the audio starts. |
| `trim` | number (s) | `0` | Seconds skipped at the start of the file. |
| `gain` | number | `1` | Volume multiplier. |
| `fadeIn` | number (s) | `0` | Fade-in length. |
| `fadeOut` | number (s) | `0` | Fade-out at the scene end. |
| `mute` | bool | `false` | Leave out of exports. |

### `reveal` object

Kinetic entrance: animates characters, words or lines one after another.

| Property | Kind | Default | Description |
|---|---|---|---|
| `by` | "char"\|"word"\|"line" | `"char"` | Unit that animates. |
| `stagger` | number (s) | `0.04` | Delay between units. |
| `duration` | number (s) | `0.6` | Duration of each unit's animation. |
| `delay` | number (s) | `0` | Wait before the first unit starts (layer time). |
| `ease` | easing | `"outExpo"` | Easing curve. |
| `from` | {from} |  | Start state of each unit. |
| `mask` | bool | `false` | Clip each line to its own box (slide up from behind a line). |
| `order` | "forward"\|"reverse"\|"center"\|"random" | `"forward"` | Order in which units start. |

### `from` object

Where each unit starts before animating to its rest state.

| Property | Kind | Default | Description |
|---|---|---|---|
| `opacity` | number | `0` | Starting opacity. |
| `x` | number (px) | `0` | Starting horizontal offset. |
| `y` | number (px) | `40` | Starting vertical offset (positive = from below). |
| `scale` | number | `1` | Starting scale. |
| `rotation` | number (°) | `0` | Starting rotation. |
| `skew` | number (°) | `0` | Starting slant, easing to upright. |

### `item` object

One kind of sprite in a repeater. Variants are picked randomly by weight.

| Property | Kind | Default | Description |
|---|---|---|---|
| `symbol` | symbol id |  | Vector symbol, e.g. "basic/person", "chess/knight", or one from a project/user pack. |
| `height` | number (px) | `100` | Height in world pixels. |
| `weight` | number | `1` | How often this variant appears relative to the others. |
| `widthScale` | number | `1` | Narrow (<1) or widen (>1) the silhouette. |
| `rim` | bool | `true` | Set false to drop the symbol's edge highlight. Not animatable. |
| `rimWidth` | number | `0.025` | Highlight stroke width as a fraction of height. |
| `path` | string |  | Custom SVG path data instead of a symbol (bottom stands on the floor). |
| `fillRule` | "nonzero"\|"evenodd" | `"nonzero"` | Fill rule for a custom path. |
| `glyph` | string |  | A text character or emoji instead of a symbol. |
| `font` | font |  | Font for a glyph. |
| `src` | image file |  | An image file instead of a symbol. |
| `shape` | "ellipse"\|"rect" |  | A plain shape instead of a symbol. |
| `width` | number (px) |  | Width of a plain shape. |
| `piece` | "pawn"\|"rook"\|"knight"\|"bishop"\|"queen"\|"king" |  | Legacy alias for symbol "chess/<piece>". |

### `instance` object

Per-copy values. Use expressions with i (index) and n (count) to vary each copy.

| Property | Kind | Default | Description |
|---|---|---|---|
| `x` | number (px) |  | Offset along the floor's x. |
| `y` | number (px) |  | Offset up/down (negative = up). |
| `z` | number (px) |  | Offset along the floor's depth. |
| `scale` | number |  | Size multiplier. |
| `opacity` | number |  | Opacity multiplier. |
| `lit` | number |  | 0 = dark, 1 = lit (pools, cones, rim light), >1 = flash. |
| `variant` | integer |  | Index into items (overrides the random pick). |
| `color` | color |  | Tint for this copy. |
| `yaw` | number (°) |  | Turn for facing "fixed". |
| `rotation` | number (°) |  | Same as yaw. |
| `visible` | bool |  | Hide this copy. |

### `ground` object

Floor plane under a repeater.

| Property | Kind | Default | Description |
|---|---|---|---|
| `color` | color | `"#0B0B0B"` | Floor colour. |
| `size` | [w, d] |  | Floor size (default: fits the layout). |
| `checker` | {checker} |  | Optional checkerboard. `false` turns it off. |

### `checker` object

Checkerboard on the floor, cells centred on grid positions.

| Property | Kind | Default | Description |
|---|---|---|---|
| `size` | number (px) |  | Cell size (default: grid spacing). |
| `color` | color | `"$fg"` | Colour of the lighter cells. |
| `opacity` | number | `0.045` | Strength of the lighter cells. |

### `ambient` object

Soft wash of light under the whole repeater, growing as more copies are lit.

| Property | Kind | Default | Description |
|---|---|---|---|
| `intensity` | number | `0.035` | Base brightness. |
| `grow` | number | `0.07` | Extra brightness × fraction lit. |
| `radius` | number (px) |  | Size of the wash (default: fits the layout). |
| `color` | color | `"$fg"` | Light colour. |
| `center` | [x, z] |  | Centre on the floor (default: layout centre). |

### `pool` object

Spotlight pool on the floor under each lit copy (additive, blooms).

| Property | Kind | Default | Description |
|---|---|---|---|
| `radius` | number (px) | `44` | Pool radius. |
| `color` | color | `"#FFFFFF"` | Light colour. |
| `intensity` | number | `1.2` | Brightness (above 1 glows with bloom). |
| `softness` | number | `0.5` | Edge softness (0 = hard disc, 1 = all falloff). |
| `falloff` | number | `1` | How quickly it fades from the centre. |
| `spill` | {spill} |  | Optional wide glow. `false` turns it off. |

### `spill` object

Wide faint glow around each pool that lifts neighbouring silhouettes.

| Property | Kind | Default | Description |
|---|---|---|---|
| `radius` | number | `3` | Size as a multiple of the pool radius. |
| `intensity` | number | `0.16` | Brightness. |

### `contact` object

Dark disc under every copy, as if lit from straight above.

| Property | Kind | Default | Description |
|---|---|---|---|
| `radius` | number | `0.17` | Radius as a fraction of item height. |
| `opacity` | number | `0.85` | Darkness. |
| `softness` | number | `0.3` | Edge softness. |

### `cone` object

Light cone from a lamp above each lit copy down to its pool.

| Property | Kind | Default | Description |
|---|---|---|---|
| `height` | number | `5.4` | Lamp height as a multiple of item height. |
| `radius` | number (px) |  | Cone base radius (default: pool radius). |
| `intensity` | number | `1` | Brightness. |
| `color` | color | `"$fg"` | Light colour. |

### `shadow` object

Silhouette laid on the floor, pointing away from the light.

| Property | Kind | Default | Description |
|---|---|---|---|
| `opacity` | number | `0.6` | Darkness. |
| `length` | number | `1` | Length as a multiple of item height. |
| `angle` | number (°) | `0` | Direction on the floor (0 = away from camera). |
| `litOnly` | bool | `true` | Only lit copies cast shadows. |

### `beam` object

Soft billboard light beam above each lit copy (lighter than cone).

| Property | Kind | Default | Description |
|---|---|---|---|
| `height` | number (px) | `900` | Beam height. |
| `width` | number (px) | `160` | Beam width. |
| `intensity` | number | `0.12` | Brightness. |
| `color` | color | `"#FFFFFF"` | Light colour. |

