# Changelog

All notable changes to Arclight are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, minor releases may change the
project format; older projects keep loading.

## [Unreleased]

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

[Unreleased]: https://github.com/xndrpr/arclight/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/xndrpr/arclight/releases/tag/v0.1.0
