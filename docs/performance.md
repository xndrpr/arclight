# Performance, size and code health

Arclight is improved in measured loops. Each change starts from a number, says which number it should move, and is
kept only when the measurement agrees (build → measure → learn). This page holds the goals, how each number is
taken, and the log of what moved them.

## Goals

Set on 2026-11-21 from the baseline below. A goal is met when the median holds over a full run.

| Area | Metric | Baseline | Goal |
|---|---|---|---|
| Size | app bundle | 22.0 MB | ≤ 7.3 MB (3× smaller) |
| Size | download (zip) | 6.2 MB | ≤ 4.0 MB |
| Workspace | Motion → Thumbnails | 429 ms | ≤ 100 ms |
| Workspace | Thumbnails → Motion | 664 ms | ≤ 100 ms |
| Chat | type a character | 196 ms | ≤ 16 ms (one frame) |
| Chat | stream one frame of text | 215 ms | ≤ 16 ms |
| Chat | open another chat | 257 ms | ≤ 100 ms |
| Editor | every other `uibench` action | 73–361 ms | ≥ 2× faster each |
| Editor | idle main-thread work | 33 ms per 0.6 s | ≤ 6 ms per 0.6 s (1 %) |
| Editor | open project, first draw | 1121 ms | ≤ 560 ms |
| Code | source lines | 46,690 | ≤ 43,400 (−7 %), no feature lost |
| Code | comment lines | 3,290 | ≤ 2,470 (−25 %) |
| Code | views observing the whole document | 133 | 0 |
| Code | functions of 80+ lines | 28 | ≤ 14 |

## How the numbers are taken

- **UI timings**: `arclight uibench <project>` (release build, off screen, the whole editor laid out and drawn at
  1600×1000). For each action it reports *first draw* (until the change is laid out and drawn) and *busy*: first
  draw plus all main-thread work in the next 0.6 s (deferred updates, async results), minus the idle level. Busy is
  the number in the goals: it is what the user waits through before the app is responsive again. Medians of 5–20
  runs. Run it with `ARCLIGHT_FAL_KEY` and `ARCLIGHT_ANTHROPIC_KEY` set to any value so it never asks the Keychain.
- **The project**: a real working project (78 scenes, 4 thumbnails, 19 chats up to 450 KB each, 370 MB of assets),
  cloned with APFS clones so the original is never touched. The small `Tests/Fixtures/UI.arclight` hides most of
  the cost (its Motion → Thumbnails switch measures 92 ms against 429 ms here).
- **Size and code**: `Scripts/metrics.sh` (source and comment lines, whole-document observers, long functions, and
  the size of `dist/Arclight.app` and its zip after `Scripts/bundle.sh`).
- **Behaviour**: `swift test` and `Scripts/verify.sh` (renders, snapshots, the MCP transcript and CLI output compared
  with a recorded baseline) must pass after every step.

## Baseline (2026-11-21, 0.1.4 + `uibench` upgrade)

```
open project: load 154 ms, first window draw 1121 ms
idle main-thread work: 33.4 ms per 0.6 s
action                         first draw (median / max)    busy (median / max)
toggle Performance               69.4 /   78.7 ms          72.6 /   82.3 ms
select a layer                  172.8 /  366.9 ms         173.5 /  384.5 ms
move playhead (paused)          102.6 /  267.8 ms         103.1 /  272.3 ms
open another scene              209.6 /  277.5 ms         360.8 /  473.1 ms
AI tab Chat ⇄ Activity           97.8 /  121.4 ms          97.8 /  123.1 ms
left tab Scenes ⇄ History       155.4 /  182.7 ms         156.6 /  201.2 ms
Motion → Thumbnails             280.6 /  298.7 ms         428.9 /  463.0 ms
Thumbnails → Motion             424.0 /  598.4 ms         664.3 /  726.9 ms
chat: open another chat         183.5 /  195.6 ms         256.9 /  265.9 ms
chat: stream one frame           14.0 /  184.8 ms         214.6 /  337.6 ms
chat: type a character            7.0 /   38.3 ms         196.2 /  277.1 ms
```

What the profiles and audits found behind these numbers:

- `EditorDocument` is one `ObservableObject` with 29 published properties and 13 manual `objectWillChange` sends,
  watched by 133 views. Any change, a selection or a toast, re-runs nearly every view in the window.
- Each `ChatController` is one `ObservableObject` too: a keystroke (`draft`) or a streamed frame re-renders the whole
  chat, and the live reply's Markdown is parsed again from the start on every frame.
- The workspace switch writes `project.json` without updating the file stamps, so half a second later the poll
  reloads the whole project and re-renders the editor a second time. It also swaps sidebars with `if`/`else`
  and resizes the viewport, which reallocates every preview render target.
- The binary carries 13 MB of symbols.

## Log

Each entry: the change, the hypothesis, and what the measurement said.

### 1. Strip the shipped binary

Hypothesis: most of the 21.4 MB binary is symbols (`__LINKEDIT` was 13 MB). Result: `strip` in `bundle.sh` (a
dSYM is kept in `dist/` for crash reports) took the app from 22.0 to 9.4 MB and the zip from 6.2 to 4.6 MB.
`-Osize` would take the stripped binary from 8.8 to 7.6 MB; not adopted until its effect on render times is measured.

### 2. Observe only what is read

Hypothesis: whole-document invalidation is the main cost of every editor action. `EditorDocument`, its view-state
objects, the chats and `ProjectStore` moved to Observation (`@Observable`); 133 `@ObservedObject` documents became
plain references, and the 13 manual `objectWillChange` sends were removed or replaced by tracked values.

Result (busy, median; measured while three builds ran, so only large changes count): select a layer 174 → 92 ms,
move the playhead 103 → 33, open another scene 361 → 233, open another chat 257 → 143. The workspace switch barely
moved (429 → 383, 664 → 550): its cost is elsewhere (next entries).

Learned: the `busy` window also catches unrelated periodic work under load (typing showed 156 ms in the bench, but a
profile of continuous typing shows ~4 ms per character). Busy is now measured against an idle window right before
each action.

### 3. Chat streaming and typing

A profile of a reply streaming at 30 frames a second showed the main thread 43 % busy: SwiftUI layout of the
message list, Markdown parsing of the paragraph being written (`AttributedString(markdown:)`, again for the whole
reply every frame), and the composer reading the key and backend settings seven times per redraw. Live replies
are now parsed incrementally (finished blocks and lines are cached), and the settings are read once per change.

### 4. Find what a workspace switch really costs

Hypothesis: the switch is slow because of the panels that only one workspace shows. Experiments that dropped one
candidate at a time (a temporary environment switch in the build, since removed) said otherwise: without the
timeline, the Thumbnails tool bar and layers panel, Motion → Thumbnails saved 45 ms and Thumbnails → Motion
nothing; without the inspector, both directions halved. Profiles then named the rest:

- The scene list swapped sidebars with `if`/`else`, rebuilding 78 rows (each with a geometry reader for drag
  reordering) on every switch. Both lists now stay built; the scene list is lazy and measures rows only while one
  is dragged.
- The scene inspector built every sound clip's row (49 in this project's first scene, 140 in another), and read the
  clip list as JSON once per field. Long lists start folded, rows are named ("3  whoosh-1  at 2.4 s"), and the JSON
  is converted once per change.
- After the first draw, both lists animated their selection to the new target (one of them hidden), redrawing the
  whole window for a quarter of a second. The switch is now one non-animated change.
- The timeline hidden behind Thumbnails followed every artboard edit and had to diff back on return. It is parked:
  its hosting view leaves the window while hidden (`Parked`), so it neither updates nor rebuilds.

Learned: lazy stacks inside scroll views cost more than they save here (the inspector got slower: 7 → 686 profile
samples in lazy layout); re-attaching a parked inspector cost more than updating it. Both were reverted.

Result (median of 3 interleaved runs): Motion → Thumbnails 429 → 197 ms, Thumbnails → Motion 664 → 279 ms. Switching
back to Motion now also returns to the scene that was open instead of the first one (it was a bug).

### 5. Any setting written redrew the whole window

`_printChanges()` on the views redrawn by "toggle Performance" showed the root, `EditorView`, re-running because of
its `@AppStorage` panel sizes, which SwiftUI reports as changed on every write to the defaults: any key, including
AppKit's own window-frame saves. 54 `@AppStorage` properties in the editor meant a whole-window redraw for a
Performance toggle, an AI tab switch, a layer group fold, a panel resize step, or the activity feed marking an entry
seen while an agent works. The editor window's settings now go through `@Preference` (`PrefChanges`), which tracks
each key on its own; the timeline's row and lane heights are read through it too, which replaces eleven
`@AppStorage` properties that existed only to force redraws.

### 6. Trackpad taps that never clicked

Reported: taps on the trackpad (tap to click) often did nothing unless the pointer stopped first; a physical press
always worked. The click log (`ClickTrace`) showed why: a finger on the trackpad also sends zero-movement scroll
events ("may begin", then "cancelled"), and when one lands between mouse-down and mouse-up, SwiftUI cancels the
press. `ScrollClickGuard` now holds a "may begin" for up to 0.2 s and drops the zero-movement ones that arrive while
a button is down; real scrolls pass through untouched. It tracks the button from mouse-down/up events, because
`NSEvent.pressedMouseButtons` reports only physical presses. `arclight clickprobe taps` replays these sequences
through the app's event queue: without the guard most taps are lost, with it every one registers.

### 7. Scrubbing, and the end of Performance mode

Performance mode (lower preview resolution) changed nothing a user could feel: the cost of a scrub step was not the
render but the whole window following the playhead. A drag on the ruler now moves the time without publishing it to
every view; the viewer redraws directly, and the rest of the window catches up at most every 0.15 s. Two hot spots
in the renderer went too: each frame asked `FileManager` for every asset's attributes (now one `stat`), and the
expression engine parsed the same expressions every frame (now cached). Result: a scrub step on a big scene
25–51 → 12 ms (a 60 fps drag), so the mode and its toggle were removed.

### 8. The workspace switch behind a curtain

Even at 160–200 ms the switch showed half-done frames (panels appearing before the viewer resized). It now fades a
curtain in (90 ms), switches under it, and fades it out (200 ms): the user sees one clean change instead of the
intermediate layouts.

### 9. Chat: what a turn cost, and a calmer look

Each turn now records its tokens (input, output, cache), cost, duration, model, tool calls and context size, from
the command-line agent's stream (`result`, `rate_limit_event`) and from the API's usage and rate-limit headers.
The chat shows it where it is needed: the time on every message, a line under each reply (`16s · 46k tokens ·
$0.09`, details on hover), and a usage ring in the header that opens into the plan's 5-hour and weekly limits with
their reset times, the context window, and this chat's totals. Tool calls and thinking fold into one line per turn
("Worked for 21m · 18 steps: …"), replies carry an author line, days are divided, and the composer is a card.
Every clickable shows the pointer.
