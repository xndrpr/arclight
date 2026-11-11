# Contributing to Arclight

Thanks for helping. Arclight is a small project, and pull requests of every size are welcome: bug fixes, examples,
documentation, new layer types, MCP tools.

Please read the [code of conduct](CODE_OF_CONDUCT.md) first. Report security problems privately, as described in
[SECURITY.md](SECURITY.md), not in a public issue.

## Setup

You need macOS 14 or later and the Swift 6.1 toolchain. The Command Line Tools are enough; Xcode is not needed.

```bash
xcode-select --install            # Command Line Tools
git clone https://github.com/xndrpr/arclight.git && cd arclight
swift build                       # debug build
swift test                        # unit, render and editor-model tests
swift run arclight                # run the editor from the build folder
```

Shaders are compiled at runtime from `Sources/ArclightCore/Render/Shaders.swift`, so no Metal toolchain is needed.

To build the app bundle: `Scripts/bundle.sh` writes `dist/Arclight.app` (ad-hoc signed), and `Scripts/install.sh`
also installs it to `/Applications` (see [docs/install.md](docs/install.md)).

[docs/architecture.md](docs/architecture.md) explains how the code is organised and where things go.

## Checks

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs these on every pull request. Run them locally
before you push:

```bash
swift format lint --strict -r Sources Tests Scripts Package.swift    # formatting (config: .swift-format)
swift build -c release -Xswiftc -warnings-as-errors                 # no warnings allowed
swift test
# The CLI with an empty home folder, so it doesn't read or write your ~/Library (see below):
arc() { mkdir -p /tmp/arclight-home; CFFIXED_USER_HOME=/tmp/arclight-home "$(swift build --show-bin-path)/arclight" "$@"; }
swift build && arc docs --out docs/scene-format.md                  # must leave no diff
for p in Examples/*.arclight; do arc validate "$p" && arc check "$p"; done
Scripts/verify.sh --smoke                                           # renders every example, runs an MCP session
```

`swift format format --in-place -r Sources Tests Scripts Package.swift` fixes most lint findings.

### Keeping the CLI off your ~/Library

Every `arclight` command uses your real user folders unless told otherwise: `~/Library/Application Support/Arclight`
(templates, themes, symbols, presence files), `~/Library/Logs/Arclight` and `~/Library/Caches/Arclight`, and the
commands that use the library (the editor, `mcp`, `render`, `export`, `check`) first copy the old Apogee folders
there once. To run the CLI against an empty home instead, set:

| Variable | Effect |
|---|---|
| `CFFIXED_USER_HOME=<folder>` | The home folder for every path above (a Foundation variable). Use an empty folder |
| `ARCLIGHT_PRESENCE_DIR=<folder>` | Only the presence files (`agents/`, `editors/`), for example to keep them apart from an empty home you reuse |

`CFFIXED_USER_HOME` does **not** move settings: macOS keeps `UserDefaults` in the real `~/Library/Preferences`, in a
domain named after the executable (`arclight` for the CLI). So the editor reads and writes its settings through
`Pref.store`: the standard domain in the app, but a throwaway domain in a temporary folder (removed at exit) in the
off-screen `snapshot` and `clickprobe` commands and in test runs, so neither reads nor changes your settings.
`Scripts/verify.sh` and `Scripts/screenshots.sh` set both variables for every CLI call and run a copy of the binary
under its own name (`verify-cli`, `screenshots-cli`); a settings domain of that name that appears during a run is
deleted at the end (one that existed before is left alone). Tests that need a settings domain of their own use
`TempDefaults` (`Tests/ArclightCoreTests/Support/TestSupport.swift`), whose domains live in a temporary folder.

Tests that need a Metal device skip with a message when there is none (GitHub's macOS runners may have no usable
GPU), so a green run there doesn't prove rendering works. Run the tests on your Mac too.

### Scripts/verify.sh: the behaviour safety net

`Scripts/verify.sh` reruns every surface of the app and compares the results with a baseline:

| Section | What it checks |
|---|---|
| `build` | release build with warnings as errors (always runs; the other sections need the CLI) |
| `test` | `swift test` passes, with no compiler warnings and no fewer tests than the baseline |
| `docs` | `arclight docs` output is byte-identical |
| `validate` | `arclight validate` and `arclight check` output for every example |
| `render` | every example scene rendered at 0, 1.5 and 3 s and its last frame, compared pixel by pixel with a small tolerance |
| `snapshot` | off-screen snapshots of the editor and its panels in several themes and sizes |
| `clickprobe` | the off-screen click probes (do buttons still receive clicks) |
| `mcp` | a scripted MCP JSON-RPC session: tool list, guide, create, edit, symbol, asset, preview and export |

The baseline lives in `out/baseline/` and is **not** in git: renders and UI snapshots depend on your Mac (GPU,
fonts, macOS version), so you record it yourself, on your machine, **before** you start a change:

```bash
git switch main && git pull
Scripts/verify.sh --record        # record out/baseline from the unchanged code
git switch -c my-change
# … make your change …
Scripts/verify.sh                 # compare; outputs in out/verify, diff images in out/verify/diff
Scripts/verify.sh --only render,mcp    # rerun some sections
Scripts/verify.sh --smoke         # no baseline: renders and the MCP session must run without errors (what CI runs)
```

It never opens a window: it uses the off-screen `render`, `snapshot` and `clickprobe` commands, an empty home folder
and throwaway settings, so your preferences don't affect it and it doesn't change them.

Several checkouts on one Mac (worktrees) share the machine, so run one verify.sh at a
time: wrap it in a lock, `lockf -t 3600 /tmp/arclight-verify.lock Scripts/verify.sh`. A run queued on the lock
belongs to whoever started it: never kill a `lockf` or `verify.sh` process by pid from another checkout. A run that
is killed after it started prints `verify: interrupted` and exits 130; a killed `lockf` waiter prints nothing at all.
Either way, rerun before trusting the result.

A difference isn't always a bug. If you changed behaviour on purpose (a new MCP tool changes the tool list, a new
example adds renders, a UI change changes snapshots), look at the diff, say in the pull request what changed and why,
and re-record that section (`Scripts/verify.sh --record --only mcp`). Refactors should produce no differences.

## Conventions

The code follows one way of doing each thing. New code should match it, and reviews will ask for it.

**General**

- Files stay under about 300 lines, with one responsibility each. Large types are split into extensions in
  `Type+Area.swift` files (for example `Renderer+Text.swift`, `Document+Timeline.swift`).
- Clear, descriptive names. Private by default; `public` only for API that another module uses.
- Comments explain *why*, not *what*. Keep doc comments on public API, and give every workaround a one- or two-line
  comment naming the bug it prevents. No narration, history notes or commented-out code.
- No TODO comments without an issue number.
- Behaviour changes and bug fixes go in their own commits, with a test, never inside a refactor.
- The "AI" or "agent" is any MCP client. Don't name a specific product in code or UI text, except where it really
  means that product (such as the Claude Code setup command).

**Core and MCP**

- Every scene edit goes through `SceneOps`, and every save through `ProjectStore`, which bumps the revision, writes
  history and refuses stale writes.
- JSON on disk uses `JSONFormat.pretty` (sorted keys); MCP text output and logs use `JSONFormat.compact`. Read and
  write files with `JSONFile`, append to logs with `JSONL`.
- Timestamps come from `Timestamp`, paths outside projects from `AppPaths`, numbers in output text from
  `Format.number`.
- Keep error types and their messages stable: MCP output is part of the interface, and `Scripts/verify.sh` diffs it.
- File-format changes must keep old projects loading (old names such as `instancer` and `piece`, the `.apogee`
  extension and folder, and the stored activity source `"claude"` are all still read).

**Editor**

- Colours come from the `UI.*` tokens in `Shared/Theme.swift`; drawing over the video uses `OverlayInk`. No
  colour literals in views.
- Settings keys live in the `Pref` enum (`Shared/Preferences.swift`), used as `@AppStorage(Pref.x)`; notification
  names live in `Shared/AppNotifications.swift`.
- Views change the document by calling intent methods on `EditorDocument`, defined in the `Document+<Area>.swift`
  file for that area; `edit {}` is only called inside those files.
- Reuse the shared pieces in `Shared/` (`FieldButton`, `.fieldChrome()`, `HoverButtonStyle`, `SmallCapsLabel`,
  `.popoverChrome(width:)`, `DisclosureButton`, `Checker`, `FilePicker`) instead of building new chrome.

**UI rules that each fixed a real bug.** Builds, tests and snapshots did not catch these, so follow them even when
something else seems to work:

- **An `NSEvent` local monitor returns the handler's result directly**: `guard let self else { return e }; return
  self.handle(e)`, and `nil` for every event it handled. Use `LocalEventMonitor`. Never write
  `self?.handle(e) ?? e`: it passes consumed events on, which made Space beep and applied timeline gestures twice.
- **Use `Button` with `.hitArea()`** (`.barHit()` inside bars that set `barHitHeight`), `.onClick` for rows and
  labels, `clickCount` for double-clicks, and `PressTracker` for custom drags. Not `onTapGesture`: it gives up when
  the pointer moves a few points during a click, and a plain button is only clickable where it draws.
- **Tabs have full-height, gap-free hit areas**, so a click between two tabs still lands on one.
- **Keep `ScrollClickGuard` installed.** It drops zero-movement trackpad scroll events while the mouse button is
  down; they cancelled SwiftUI button presses.
- **Window drags must not steal clicks**: host SwiftUI in `AppHostingView` (`mouseDownCanMoveWindow = false`), set
  windows up with `AppWindows.configure`, and make only `WindowDragArea` drag the window.
- **The top bar lives in the title-bar row** (compact unified toolbar; `TopBar.leading(for:)` and `height(for:)`
  handle the traffic lights and safe area). Snapshots have no title bar, so check changes there with
  `arclight clickprobe hits` and `clickprobe titlebar`, and in a real window.
- **`AppTheme.apply` is the only way to change the app theme.** It updates windows, appearance, the Metal clear
  colour and observers together; anything else leaves stale colours behind.
- **Inspector text fields use `FieldDraft`**: they follow the value while you scrub, unless the user has typed.
- **The key handler defers only to editable text views.** A read-only label that swallowed Space made AppKit beep.
- **Hover never changes layout.** Show hover state with overlays or opacity; inserting views on hover makes rows
  flicker and moves click targets.
- **Re-check state after every async hop** (`DispatchQueue.main.asyncAfter`, a background render returning): the
  document, queue or selection may have changed. Removing from an emptied queue crashed the history thumbnails.
- **Borderless `Menu`s are for real menus only.** Their clickable band is about 6 points tall whatever the label
  frame, so don't use them as buttons.

### Debugging UI bugs

Record the real app before you change anything. **Help ▸ Record Click Diagnostics** writes every mouse event and
which control fired to `~/Library/Logs/Arclight/clicks.log` (**Help ▸ Show Click Log** opens it). Off-screen:

```bash
swift build                                    # then `arc` from "Checks" above (an empty home folder)
arc snapshot Tests/Fixtures/UI.arclight --out ui.png --select counter --time 3
arc snapshot Tests/Fixtures/UI.arclight --out ai.png --setup ai,agent:editing
arc snapshot Tests/Fixtures/UI.arclight --out settings.png --panel settings --theme light
arc clickprobe                                 # moving and jittery clicks into test buttons
arc clickprobe hits Tests/Fixtures/UI.arclight
```

`snapshot` options are documented at the top of `Sources/ArclightEditor/App/Snapshot.swift`. Attach a snapshot to
pull requests that change the UI.

When you probe a new region with `clickprobe grid`, avoid SwiftUI `Menu`s and text fields (including the project
and scene names, which become text fields on click): off-screen, they start a tracking loop that never ends. Only
controls that report to `ClickTrace` (`IconButton`, sidebar tabs, `.onClick` rows) show up in a grid, and a sheet
opened by a click (Export, the keyboard-shortcuts icon) makes the window ignore every later click in the same process.

## How to add…

### A property or a layer type

1. Describe it in the schema. Layer types and their properties are in
   `Sources/ArclightCore/Schema/SchemaNodes.swift` (a `NodeSchema` with type, label, SF Symbol icon, one-line doc and
   fields), scene settings in `SchemaScene.swift`, and nested objects in `SchemaObjects.swift`. The inspector, the
   validator, the MCP guide and `docs/scene-format.md` all pick it up from there.
2. For a new layer type, also add:
   - its one-line summary for outlines and the layer list in `Schema/Schema+Summary.swift`;
   - required-property checks in `Model/Validation.swift`, if any;
   - drawing in the renderer: dispatch in `Render/Renderer+Frame.swift`, bounds in `Render/Renderer+Bounds.swift`,
     and the drawing itself in a `Render/Renderer+<Type>.swift` file;
   - an entry in the editor's add-layer menu, `Sources/ArclightEditor/Layers/AddLayerMenu.swift`.
3. Properties reach the renderer already evaluated (keyframes, expressions and theme tokens resolved by
   `Animation/Evaluator.swift`); read them from the evaluated node's props.
4. Add tests in `Tests/ArclightCoreTests/` (`SymbolLayerTests.swift` is a complete example for a layer type; use
   `TempProject` from `Support/TestSupport.swift`).
5. Regenerate the reference: `arc docs --out docs/scene-format.md` (`arc` as in [Checks](#checks)).

### An MCP tool

1. Add a `Tool(name:description:schema:readOnly:run:)` to the group it belongs to in `Sources/ArclightMCP/`:
   `Tools+Project.swift`, `Tools+Scene.swift`, `Tools+Output.swift`, `Tools+Library.swift`, `Tools+Themes.swift` or
   `Tools+Editor.swift`. Build the argument schema with the helpers in `ToolSupport.swift`, and set
   `readOnly: true` for tools that never change the project (the activity feed and presence show them as reads).
2. Save scenes through `saveValidated` (`Tools+Shared.swift`): it validates, saves as an AI change, and so the edit
   shows up in the editor's activity feed with revert. Report failures by throwing `ToolError` with a message the
   agent can act on.
3. Validate every id, name and number that comes from the agent before it reaches the file system or an `Int`
   conversion.
4. If agents need to know when to use it, mention it in the hand-written parts of `Guide.swift` (workflow, ops,
   export, recipes).
5. Test it by calling the server directly (see `call(_:_:_:)` in `Tests/ArclightCoreTests/NotesTests.swift`), then
   re-record the `mcp` section of `Scripts/verify.sh`, since the tool list changes.

### A panel

- A tab in the left sidebar: add it to `LeftSidebar.tabs` and `page(_:)` in
  `Sources/ArclightEditor/App/LeftSidebar.swift`.
- A settings tab: `Sources/ArclightEditor/App/Settings/` (`SettingsView.swift` lists the tabs).
- A section in the inspector: `Sources/ArclightEditor/Inspector/` (`LayerInspector.swift` for layers,
  `SceneInspector.swift` for the scene).
- A sheet or window: follow `ExportSheet.swift` or `InstallHelp.swift` in `App/`, and register menu items in
  `App/MainMenu.swift`.

Put the panel's document logic in a `Document+<Area>.swift` extension, its settings keys in `Pref`, and add a
`--panel` case to `rootView` in `App/Snapshot.swift`, so it can be snapshotted off-screen (and by `Scripts/verify.sh`
if it matters).

### An example

1. Make a project folder `Examples/<name>.arclight`: `project.json` and `scenes/*.json`, plus `symbols/` or
   `assets/` if it needs them. Build it in the editor or with an agent; keep it small.
2. Use English text, fonts that ship with macOS, and theme tokens (`$fg`, `$display`, …) rather than literal colours
   and fonts.
3. It must pass `arclight validate` and `arclight check` with no problems. CI runs both on every example, and the
   test suite validates every project in `Examples/`.
4. Add a row to the table in [Examples/README.md](Examples/README.md).
5. Re-record the `render` and `validate` sections of `Scripts/verify.sh`.

### A template, theme preset or symbol pack

Built-in templates are in `Sources/ArclightCore/Library/BuiltInTemplates.swift` (scenes with `{{param}}`
placeholders, plus `{{W}} {{H}} {{CX}} {{CY}}` for the canvas; every one is instantiated and validated at 16:9 and
9:16 by the tests). Theme presets are in `Library/ThemePresets.swift`, built-in symbols in `Library/Symbols.swift`.
Users can add their own without code: in a project's `templates/` and `symbols/` folders, or in
`~/Library/Application Support/Arclight/library/`. A symbol pack is JSON with SVG path data (y points down; the
bottom of the shape stands on the floor):

```json
{"pack": "brand", "symbols": [
  {"id": "logo", "name": "Logo", "path": "M-20 0 L20 0 L0 -40 Z", "rim": "M-10 -20 L10 -20"}
]}
```

`rim` is an optional highlight stroked along the top edges when a copy is lit.

## README images

Every image in `docs/assets/` (except the logo) is generated from the examples by `Scripts/screenshots.sh`, so they
never go stale. The lists of what to capture are at the top of the script. It runs only the off-screen
`snapshot`, `render` and `export` commands, with an empty home folder. Use `--out DIR` to compare before you commit,
and look at every image: they are the first thing people see.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep the change focused. Add tests for model and logic changes, and a snapshot for UI changes.
3. Run the checks above and `Scripts/verify.sh` against a baseline you recorded before the change.
4. Add a line to [CHANGELOG.md](CHANGELOG.md) under *Unreleased* for anything users will notice.
5. Open the pull request and fill in the template. CI must pass before it is merged.

## License

Arclight is licensed under the [GNU General Public License v3.0](LICENSE). By opening a pull request, you agree
that your contribution is licensed under the same license (inbound = outbound). There is no CLA to sign and no DCO
sign-off.
