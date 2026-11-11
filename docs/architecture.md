# Architecture

Arclight is one Swift package with four targets. The same `arclight` executable is the editor app, the MCP server
and the command-line renderer; which one runs depends on its arguments.

```
                      ┌──────────────────────── arclight (CLI entry point) ────────────────────────┐
                      │   no args / open        mcp                 render, export, validate, …    │
                      └──────┬──────────────────┬────────────────────────┬─────────────────────────┘
                             ▼                  ▼                        │
                      ArclightEditor       ArclightMCP                   │
                      (SwiftUI/AppKit)     (JSON-RPC on stdio)           │
                             └─────────┬────────┘                        │
                                       ▼                                 ▼
                                  ArclightCore: model, schema, evaluator, renderer, export, library
```

`ArclightEditor` and `ArclightMCP` both depend on `ArclightCore` and never on each other. The test target,
`ArclightCoreTests`, depends on all three libraries.

## Module map

### ArclightCore (`Sources/ArclightCore`)

The engine. No UI code; everything the editor, the MCP server and the CLI share.

| Folder | What's in it |
|---|---|
| `Model/` | `Scene`, `Node` and `Prop` (the JSON model), `SceneOps` (every edit, as atomic operations), `ProjectStore` (a project folder on disk: load, save with revisions, history), `Validation`, `Doctor` (`project_check` / `arclight check`), `ActivityLog`, `Notes`, `AgentPresence`, `Outline` (compact scene text for agents) |
| `Schema/` | The single description of every layer type and property: `SchemaNodes` (layer types), `SchemaScene` (scene settings), `SchemaObjects` (nested objects), `SchemaTypes`, plus `SchemaCheck` (validation against it), `Schema+Docs` (generates `docs/scene-format.md`) and `Schema+Summary` (one-line layer summaries) |
| `Animation/` | `Evaluator` (scene + time → resolved layers: keyframes, expressions, theme tokens, parenting), `Easing`, `Color`, `Matrix` |
| `Script/` | `ExprEngine`: JavaScript expressions on JavaScriptCore (`wiggle`, `smoothstep`, markers, repeater stats) |
| `Render/` | The Metal renderer, split by area: `Renderer` (setup), `Renderer+Frame` (the frame pipeline), `+World` (3D floor and repeaters), `+Cones`, `+Shapes`, `+Text`, `+Image`, `+Post`, `+Bounds`; `Camera`, `Instancer` (repeater layout), `SVGPath`, `SymbolRaster`, `Shaders` (compiled at runtime), `ImageEncoding`, `ContactSheet` |
| `Text/` | `TextLayout`: glyph layout and the glyph atlas |
| `Export/` | `Exporter`: H.264, HEVC, ProRes 4444 and PNG sequences through AVFoundation |
| `Audio/` | Waveforms and muxing the scene's audio into exports |
| `Library/` | Symbol packs (`Symbols`, `ChessPack`), templates (`Templates`, `BuiltInTemplates`), `ThemePresets`, `AssetWriter` (`symbol_save` / `asset_write`), `SymbolPreview` |
| `Support/` | Small shared pieces: `AppPaths`, `JSONFormat` (`JSONFile`, `JSONL`), `Timestamp`, `Format`, `ChangeSource`, `Version`, `LegacyMigration` (the one-time carry-over from Apogee), `AssetPath`, `URL+ExpandingPath` |

### ArclightMCP (`Sources/ArclightMCP`)

The MCP server that `arclight mcp` runs: JSON-RPC 2.0 over stdio, one process per agent session.

| File | What's in it |
|---|---|
| `Server.swift` | The protocol loop, tool dispatch and the current project |
| `Tools.swift` | Collects the tool groups below |
| `Tools+Project.swift` | `guide`, `project_create`, `project_open`, `project_get`, `project_update`, `theme_set`, `font_list` |
| `Tools+Scene.swift` | `scene_create`, `scene_get`, `scene_apply`, `scene_delete` |
| `Tools+Output.swift` | `render_frames`, `export`, `asset_import` |
| `Tools+Library.swift` | `template_list`, `template_instantiate`, `template_save`, `project_check`, `asset_write`, `symbol_save`, `symbol_list` |
| `Tools+Themes.swift` | `theme_presets`, `theme_apply`, `theme_preset_save` |
| `Tools+Editor.swift` | `editor_state`, `note_list`, `note_resolve`, `history` |
| `Tools+Shared.swift`, `ToolSupport.swift` | Validated saving, schema helpers, `ToolError` |
| `Server+Activity.swift`, `Server+Presence.swift` | Logging each call to the project's activity feed; keeping this session's presence file up to date |
| `Guide.swift` | The `guide` tool's text. Layer and scene references are generated from the schema; workflow, animation, ops, export and recipes are written by hand |

### ArclightEditor (`Sources/ArclightEditor`)

The SwiftUI and AppKit editor, one folder per area of the window.

| Folder | What's in it |
|---|---|
| `App/` | App lifecycle (`EditorApp`, `AppDelegate`, `EditorWindowController`, `MainMenu`, `KeyCommands`), the window layout (`EditorView`, `TopBar`, `LeftSidebar`, `ScenesSidebar`), `WelcomeView`, `ExportSheet`, `InstallHelp`, `Shortcuts`, `Settings/`, and the off-screen development tools `Snapshot`, `Offscreen` and `ClickProbe` |
| `Canvas/` | The Metal viewport (`Viewport`, `MetalCanvas`, `ViewportState`), the transform gizmo (`GizmoOverlay`, `GizmoSession`, `GizmoLayout`), guides, `CanvasToolbar`, `Document+Canvas` |
| `Timeline/` | `Timeline`, `Tracks`, `Ruler`, `TransportBar`, keyframe editing, the audio lane and playback, `Document+Timeline`, `Document+Playback` |
| `Layers/` | The layer list (`LayerList`, `NameRow`, `LayerTree`, `LayerThumbs`), `AddLayerMenu`, `Document+Layers` |
| `Inspector/` | The schema-driven inspector (`Inspector`, `LayerInspector`, `SceneInspector`, `FieldRow`, `Controls`), paint, font, easing and expression fields, the theme editor and popover |
| `Library/` | Templates, symbols and assets (`TemplateGallery`, `AssetsPanel`, `SymbolMenu`, `NewProjectView`, `SaveTemplateSheet`) |
| `Activity/` | The activity feed, notes, revision history (`HistoryPanel`) and the change flash overlay |
| `AI/` | The floating AI panel, agent status and rows, `AgentMonitor` (reads presence files), `ConnectGuide` (how to connect an agent) |
| `Shared/` | `EditorDocument` (the open project: working copy, undo, autosave, reloading from disk) and its `Document+Persistence` / `Document+Selection` extensions; `Theme` (the `UI` tokens), `AppTheme`, `Preferences` (`Pref`), `AppNotifications`; shared components and interaction fixes (`BaseComponents`, `BaseControls`, `HitArea`, `Interaction`, `LocalEventMonitor`, `WindowChrome`, `ClickTrace`) |

### arclight (`Sources/Arclight/main.swift`)

Argument parsing and the commands: `open`, `render`, `export`, `mcp`, `validate`, `check`, `info`, `new`, `docs`,
`snapshot`, `clickprobe`, `--version`. With no arguments, or a project path, it starts the editor.

## Data flow

### From a project on disk to a video

```
 Name.arclight/                ProjectStore             Evaluator                 Renderer           Exporter
 project.json, scenes/*.json ─▶ Project + [Scene] ──────▶ resolved layers at T ───▶ frame (Metal) ───▶ MP4 / MOV / PNGs
 assets/, fonts/, symbols/      (load, save, history)    (keyframes, expressions,  (3D, 2D, post)     (+ audio mux)
                                                          tokens, parenting)
```

- **A frame is a pure function of time.** `Evaluator` resolves a scene at time T; nothing carries over between frames,
  so the viewport, scrubbing, `render_frames`, `arclight render` and export always agree.
- **The renderer** draws the 3D world (camera, floor, repeaters, lights, fog) with depth of field and optional
  motion-blur accumulation, then the 2D layers, then bloom, grading, vignette, grain and fades, and outputs sRGB.
  Colours are linear and premultiplied internally.
- **The schema** is the one description of every property: the inspector draws its rows from it, the validator checks
  scenes against it, and the MCP guide and `docs/scene-format.md` are generated from it.

### Agent, project folder and editor

```
  AI agent ──stdio JSON-RPC──▶ arclight mcp ──SceneOps / ProjectStore──▶ project folder ◀── EditorDocument (editor)
                                    │                                     │  scenes/, .history/        │  polls every 0.5 s,
                                    │                                     │  .arclight/activity.jsonl  │  autosaves 0.4 s after
                                    │                                     │  .arclight/notes.json      │  an edit
                                    │                                     │  .state.json ──────────────┘  (selection, time)
                                    └── presence: ~/Library/Application Support/Arclight/agents/<pid>.json
                                                                           editors/<pid>.json ◀── editor
```

- **One model, three front ends.** The editor, the MCP server and the CLI all edit scenes through `SceneOps` and save
  through `ProjectStore`. A save bumps the scene's `rev`, writes a snapshot to `.history/`, and is refused if it was
  based on an older revision, so the agent and the editor can't silently overwrite each other.
- **Live reload.** `EditorDocument` polls the project folder. When a scene changes on disk it diffs the change,
  pushes the old version onto the undo stack, flashes the changed layers and says who made the change.
- **Activity.** The MCP server logs every tool call to `.arclight/activity.jsonl` with the revision before and after;
  the editor logs its own saves there too. The AI panel's activity feed shows both, and "revert" restores the
  revision from before a change as a new revision.
- **Presence.** Each `arclight mcp` process keeps a small file in `agents/` (client name, current tool, project); the
  editor's `AgentMonitor` reads them to show who is connected and what they are doing. The editor writes `editors/`
  files and `<project>/.state.json` (current scene, selection, playhead), which `editor_state` reports to the agent.
- **Notes.** Notes the user leaves for the agent are stored in `.arclight/notes.json`, pinned to a layer and a time;
  the agent reads them with `editor_state` / `note_list` and answers with `note_resolve`.

## Where to add X

| To add… | Start here | Also touch |
|---|---|---|
| A property on a layer | `ArclightCore/Schema/SchemaNodes.swift` | the drawing code in `Render/Renderer+*.swift`; tests; `arclight docs --out docs/scene-format.md` |
| A scene setting or look effect | `Schema/SchemaScene.swift`, `Schema/SchemaObjects.swift` | `Render/Renderer+Post.swift` or `Renderer+Frame.swift` |
| A layer type | `Schema/SchemaNodes.swift` | `Schema+Summary.swift`, `Model/Validation.swift`, `Render/Renderer+Frame.swift`, `Renderer+Bounds.swift`, a `Renderer+<Type>.swift`, `ArclightEditor/Layers/AddLayerMenu.swift` |
| An expression helper | `ArclightCore/Script/ExprEngine.swift` | `ExprEngineTests.swift`; the animation topic in `ArclightMCP/Guide.swift` |
| A scene operation (for `scene_apply` and the editor) | `ArclightCore/Model/SceneOps.swift` | the ops topic in `Guide.swift` |
| A project check | `ArclightCore/Model/Doctor.swift` | `DoctorCharacterizationTests.swift` |
| An export format | `ArclightCore/Export/Exporter.swift` (`ExportFormat`) | `ArclightEditor/App/ExportSheet.swift`, the `export` tool in `ArclightMCP/Tools+Output.swift`, the CLI in `Sources/Arclight/main.swift` |
| An MCP tool | the matching `ArclightMCP/Tools+<Group>.swift` | `Guide.swift`; a test; re-record `Scripts/verify.sh --record --only mcp` |
| A CLI command | `Sources/Arclight/main.swift` (`usage` and the `switch`) | README "Command line" |
| A built-in template, theme preset or symbol | `ArclightCore/Library/BuiltInTemplates.swift`, `ThemePresets.swift`, `Symbols.swift` | `TemplateTests.swift`, `ThemePresetTests.swift`, `SymbolTests.swift` |
| An editor panel or sidebar tab | `ArclightEditor/App/LeftSidebar.swift`, `App/Settings/`, `Inspector/` | a `Document+<Area>.swift` for its logic, `Shared/Preferences.swift` for settings, a `--panel` case in `App/Snapshot.swift` |
| A menu item or shortcut | `ArclightEditor/App/MainMenu.swift`, `App/KeyCommands.swift` | `App/Shortcuts.swift` (the shortcuts sheet) |
| A UI colour or shared control | `ArclightEditor/Shared/Theme.swift` (`UI`), `Shared/BaseComponents.swift`, `Shared/BaseControls.swift` | |
| A path outside projects | `ArclightCore/Support/AppPaths.swift` | |
| An example project | `Examples/<name>.arclight` | `Examples/README.md`; `Scripts/screenshots.sh` if it should appear in the README |

See [CONTRIBUTING.md](../CONTRIBUTING.md) for step-by-step versions of the most common ones and the conventions to
follow.
