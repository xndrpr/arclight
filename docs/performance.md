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
