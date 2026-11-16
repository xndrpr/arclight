# Changelog

All notable changes to Arclight are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, minor releases may change the
project format; older projects keep loading.

## [Unreleased]

## [0.1.3] - 2026-11-16

Sound and moving models: the AI scores a scene with effects, music and voiceover, and 3D models play their own
animation.

### Added

- 3D models play their own animation: a .glb/.gltf with bones, shape keys or moving parts plays its first clip on loop
  on a model layer. New model fields `clip` (name or number, or "none"), `clipSpeed`, `clipOffset` (put copies out of
  step), `clipLoop` and `clipTime` (keyframe to scrub), in the inspector's Animation section. `asset_import` lists a
  model's clips and exports a .blend to .glb through Blender when it is installed.
- Sound for the AI: scenes take any number of sound clips (`sounds`) over the reference audio, each at its own time,
  played in the editor (a new Sounds lane on the timeline) and mixed into exports. `scene_apply {"op":"sound",…}`
  adds, moves and removes them.
- `sound_search` / `sound_import`: free Creative Commons sound effects and music from the web (Openverse: Freesound,
  Jamendo, Wikimedia), commercial-use licences by default; credits are written to `assets/CREDITS.md`.
- `sound_synth`: 20 motion-graphics effects made on the device for free (whoosh, swipe, riser, reverse, impact, boom,
  hit, pop, click, tick, blip, beep, ding, chime, success, error, glitch, typing, sparkle, drop).
- `voice_generate`: voiceover with the Mac's system voices (free, offline) or ElevenLabs on fal.ai.
- `sound_generate`: AI sound effects and music on fal.ai (ElevenLabs Sound Effects and Music, Stable Audio).
- `audio_analyze`: tempo, beats, onsets, phrases between pauses and the loudest moment; can write them as scene
  markers (`beat-1`, `bar-1`, `hit-1`, `line-1`…) to animate to. New guide topic `sound`.
- Audio clips take `length` (seconds played); a clip's fade-out now ends where it stops being heard.
- Assets ▸ Audio: add a file as a sound clip at the playhead; + Layer ▸ Sound Effect….

- Free asset library: `library_search` and `library_import` find and import ready-made CC0 3D models (~500) and
  tiling textures (~900) from Poly Haven at no cost. A model's glTF is packed into one .glb. The AI looks there
  before paying to generate a model or texture.
- Web search in the in-app chat (Anthropic's web search and fetch, about 1 cent per search, up to 5 per reply),
  shown as steps in the chat; turn it off in Settings ▸ AI ▸ Chat. If the organization has web search disabled, the
  chat carries on without it.

- AI model picker in the chat header and Settings ▸ AI: image and 3D models with their fal.ai prices, or Auto, which
  picks by purpose (Seedream 5.5 for photos and cut-outs, GPT Image 2.6 for graphics, Z-Image Turbo for drafts;
  Trellis 2 for 3D, Trellis for drafts).
- `image_generate` takes `purpose`, `transparent`, `quality` and raw `options`; `model_generate` takes `model` and
  `quality`. Results say which model made them and its price.
- Chat progress bar: the AI posts its plan (`update_plan`), shown as goal, step n of m and what it is doing now.
- Chat history: New chat keeps the old one; reopen or delete past chats from the history menu.
- Full-size AI panel (button in the panel bar, or double-click it).
- Chat replies show lists, headings and code, with a copy button; runs of tool calls fold into one line.

### Fixed

- GPT Image on fal.ai failed with HTTP 422 (the size was sent as "1536x1024"); each model now gets its size in the
  shape it takes, within its pixel limits, and a rejected request falls back to another model.
- ⌘C and ⌘A copied or selected layers instead of the selected chat text.
- The chat's message box sometimes jumped to full height until you clicked elsewhere.
- The chat is saved when you send and during long turns, not only when a turn ends.

## [0.1.2] - 2026-11-16

3D spaces: the AI can build a whole place and move the camera through it.

### Added

- **Depth-correct 3D**: a solid 3D layer now hides what is behind it whatever the list order, so walls, floors,
  furniture and figures stay right as the camera moves. Layers on one plane (a label on a panel) still draw in list
  order.
- **Box layer** (`box`): blocks and furniture, or a whole room with `"inside": true`. Each face takes a colour or a
  tiled image and is shaded from one light direction; seen from outside, a room's near walls drop away like a
  dollhouse.
- **Model layer** (`model`): 3D models from `.glb`/`.gltf` (built-in reader), `.obj`, `.usdz`, `.ply` and `.stl`,
  lit (matte, glossy or clay), solid, with fog and depth of field. Add one with **Model (3D)…** or drop the file on
  the canvas.
- **Relief images**: an image with a depth map (`depth`, `depthAmount`) becomes a 3D surface with real parallax.
- **AI**: `model_generate` makes a 3D model of one object from a prompt or a picture (fal.ai image-to-3D) and can
  place it in a scene; `image_depth` makes the depth map for a relief. Both need your fal.ai key. The guide has a
  `space` topic (rooms, things in them, light, camera moves including the dolly zoom) and the chat builds a place
  as one space when the story happens in one.

## [0.1.1] - 2026-11-16

Thumbnails, AI pixel tools and a chat with the AI inside the editor.

### Added

- **Thumbnails workspace** (**⌘1** Motion, **⌘2** Thumbnails): YouTube thumbnails live in the same project as your
  scenes, as pages of artboards that share the project's theme (or detach from it). A board canvas shows all
  artboards, with a tool bar (move, text, rectangle, ellipse, line, place image, hand, zoom) and Figma/Photoshop-style
  keys. A feed preview shows the thumbnail at YouTube's sizes with the timestamp badge. Export is PNG or JPG, with a
  YouTube preset that stays under 2 MB.
- **Layer effects** for text, shape, symbol and image layers, in thumbnails and motion scenes: blend modes, clip to
  the layer below, masks (alpha or luma), outline, drop shadow, glow, blur and colour adjustments. Images take `fit`
  (cover or contain) and `crop`.
- **Thumbnail helpers**: six built-in thumbnail templates, A/B variants that change one thing at a time, the best
  frames from your video (by face and sharpness), and references (a YouTube thumbnail by URL, analysed on-device for
  palette, text, faces and layout).
- **AI pixel tools**: remove a background and select the subject on-device with Apple Vision, no key needed. With
  your own fal.ai key (**Settings ▸ AI ▸ Image generation**, stored in the Keychain): generate, generative fill,
  expand and upscale. Each result is a new asset and one undoable edit. Agents can choose the generation model per
  call.
- **Chat in the editor**: a Chat tab in the AI panel (**⌥⌘A**) with your Anthropic API key (**Settings ▸ AI ▸ Chat**).
  It streams replies and thinking, shows each tool call with its pictures, and takes pasted or dropped images and
  files. Before building a new scene it settles the direction with you on cards: a brief, a few looks, a storyboard
  and the motion feel, each a cheap draft scene you pick with a click (**View large** to compare full size).
- **MCP**: `thumbnail_*` tools, `image_*` tools, `frame_extract`, `reference_add`, `reference_analyze` and
  `thumbnail_variants`; `guide("thumbnails")` and `guide("direction")`; draft scenes (`draft: true`, hidden from the
  scene list and exports, cleared with `scene_delete {drafts: true}`) with their own theme tokens.

### Changed

- The AI panel's notes, agents and activity feed moved to an **Activity** tab next to Chat.
- Switching between Motion and Thumbnails, and between scenes, is much faster on large scenes.

### Fixed

- A text layer's font `size` was refused in thumbnail edits, and variant names with non-Latin letters made invalid
  artboard ids.
- Importing a symlinked file copied a dangling link into `assets/`.

## [0.1.0] - 2026-11-11

The first public release, **Arclight 0.1.0 (alpha)**: a native macOS editor and renderer for motion graphics,
made to be driven by AI agents over MCP. It's early software. Expect rough edges, and please
[report what you find](https://github.com/xndrpr/arclight/issues).

### Added

- **Live editor**: Metal viewport, timeline with keyframes, layer list with thumbnails, a schema-driven inspector,
  DaVinci Resolve-style shortcuts, undo, autosave, a cinema viewer and vertical or square canvases.
- **AI agents over MCP** (`arclight mcp`): agents build a scene in one call, edit it with small atomic operations,
  check their work with preview images, create their own artwork (`symbol_save` for vector shapes, `asset_write`
  for images from SVG or PNG/JPEG data) and export. Every call appears in the editor's floating AI panel, with
  one-click revert. Works with any MCP client that runs a server over stdio.
- **Layers**: text (per-character, word or line reveals, count-ups), shapes (gradients, lines that draw on),
  symbols (vector icons and logos), images, groups, repeaters (hundreds of symbols on a 3D floor: crowds, fields of
  icons) and lights.
- **Look**: perspective camera with depth of field and shake, fog, bloom, vignette, film grain, colour grade, motion
  blur and fades.
- **Animation**: keyframes with easing, JavaScript expressions (`wiggle`, `smoothstep`, live repeater stats),
  markers, and reference audio with a waveform. Number settings inside a layer's object settings take their own
  keyframes, such as a light's `"pool": {"intensity": {"k": [[0, 0], [1, 1.2]]}}`; the inspector shows their value at
  the playhead and edits them through the object's *Edit as JSON…*.
- **Design system**: theme tokens (`$fg`, `$display`), theme presets, templates with parameters and symbol packs
  (SVG paths). A colour can be a token at a given opacity, `"$accent@25"` (0–100 %), anywhere a colour is accepted,
  gradient stops included.
- **Export**: H.264, HEVC, ProRes 4444 with alpha, or PNG sequences, with your voiceover mixed in.
- **Project format**: a `.arclight` folder of small JSON files (one per scene) plus assets, fonts, symbols,
  templates and a full revision history. The reference is generated from the engine's schema:
  [docs/scene-format.md](docs/scene-format.md).
- **Command line** (`arclight`): `render`, `export`, `validate`, `info`, `new`, `docs` and `mcp`, plus `check`, which
  reports every problem the MCP `project_check` tool finds (schema, expressions, missing fonts, assets and symbols,
  unknown theme tokens) and exits non-zero if there are any. The off-screen `snapshot` and `clickprobe` tools are
  for development and CI.
- **Notes for the agent**: leave a request pinned to a layer and a moment in time while you watch; the agent sees it
  through `editor_state` and answers with `note_resolve`.
- **Eight example projects** in `Examples/`, each in a different style: `kinetic-type`, `data-bars`,
  `spotlight-crowd`, `quote-card`, `lower-third`, `social-vertical` (9:16), `logo-sting` (a custom symbol) and
  `three-steps-light`. All of them pass `arclight validate` and `arclight check`, and use only fonts that ship with
  macOS. Each one is described in `Examples/README.md`.
- No third-party dependencies: Swift, Metal, AVFoundation and JavaScriptCore. Builds with the Command Line Tools;
  Xcode isn't needed.

### Changed

- The project was previously developed under the name Apogee. Upgrading keeps everything:
  - `.apogee` projects still open in the app, the command line and the MCP server. The first time one is opened, its
    hidden `.apogee/` folder (activity log and notes) is copied to `.arclight/`.
  - The first time the app, or an `arclight` command that uses your library (`mcp`, `render`, `export`, `check`),
    runs, it copies `~/Library/Application Support/Apogee` and `~/Library/Logs/Apogee` into the Arclight folders,
    without overwriting anything, and leaves the old folders in place. One-shot commands such as `docs`,
    `validate`, `info` and `new` don't.
  - The app reads the old `com.xndrpr.apogee` settings once, if it has none of its own yet.
  - The MCP server is now called `arclight`. Re-register it in your agent; see
    [docs/install.md](docs/install.md#upgrading-from-apogee).

### Fixed

Found while preparing the release and fixed before it:

- **Security:** ids and names that an MCP agent passes (`template_instantiate` scene ids, `asset_import` names,
  `template_save` ids) could contain `../` and write files outside the project or library. Ids and file names must
  now be plain names (letters, digits, `-` and `_`, plus the extension for assets); anything else is rejected with
  an error, never rewritten. The editor goes through the same check.
- **Data loss:** importing a file that was already in the project's `assets/` folder deleted it. Deleting the open
  scene kept its undo history, so ⌘Z wrote the deleted scene back to disk.
- The MCP server and the CLI no longer crash on huge, negative or non-finite numbers; they answer with an error.
  Limits: canvas sides up to 16384 px, frame rate up to 1000 fps, scene duration up to 86400 s. A hand-edited
  project with numbers beyond them fails to export with a clear error. `project_create` checks size and fps like
  `project_update`, and `template_instantiate` changes nothing when it fails.
- CLI: a bad number (`--time abc`, `--scale 0`) is an error with a non-zero exit instead of a silent default;
  `render` with several times suffixes only the file name; `export` lists `png` in its usage and errors.
- Bloom includes 2D layers when `post.bloom` is set (it used to light only 3D layers). Scenes that set bloom and
  have 2D layers now glow.
- Centred and right-aligned text with tracking no longer counts the trailing tracking, so it sits where its `x`
  says. No hairline shows where glyphs touch (negative tracking).
- Rendering: glyph and symbol caches are keyed by size; symbol sprites and atlases update when their art changes,
  and aren't shared between projects; export always draws at full quality, whatever the viewer was set to.
- Expressions containing the word `return` inside a string are evaluated as expressions. `arclight check` and
  `project_check` classify problems by where they come from.
- Editor: canvas snapping follows the one *Snapping* setting (an old canvas-only switch is read once); hover never
  shifts layer or template rows; clicking a keyframe stops playback; zoom limits include the Fit scale; numbers
  that round to a whole value print without a trailing dot; a renamed project retitles its own window.

### Known limitations

- **The app is ad-hoc signed and not notarized.** macOS warns the first time you open a downloaded copy. To open
  it:
  1. Unzip `Arclight-0.1.0.zip` and move `Arclight.app` to `/Applications`.
  2. Open it once and dismiss the warning. Then open **System Settings ▸ Privacy & Security**, scroll to
     *Security* and click **Open Anyway** next to "Arclight was blocked". Confirm with your password or Touch ID.
     (On macOS 15 and later, right-click ▸ Open no longer skips this step.)
  3. If macOS says the app "is damaged" or offers *Move to Trash*, click **Cancel** and run:

     ```bash
     xattr -cr /Applications/Arclight.app
     codesign --force --sign - /Applications/Arclight.app
     ```

  Building from source with `Scripts/install.sh` avoids the warning entirely. See
  [docs/install.md](docs/install.md). A Developer ID signed and notarized release is planned.
- Requires macOS 14 or later on a Mac with Metal.
- The project format may still change before 1.0. Old projects will keep loading.

[Unreleased]: https://github.com/xndrpr/arclight/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/xndrpr/arclight/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/xndrpr/arclight/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/xndrpr/arclight/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/xndrpr/arclight/releases/tag/v0.1.0
