# Examples

Eight small projects, each in a different style. Every one is a plain folder of JSON (`project.json`,
`scenes/*.json`) that you can read, copy and change.

| Example | What it shows |
| --- | --- |
| `kinetic-type` | A red, black and white type manifesto: char, word and line reveals, full-frame slab wipes, spring and bezier easing (Brutalist). |
| `data-bars` | A ridership report: a counting headline, a percentage delta and six bars growing from a baseline with counting labels (Midnight). |
| `spotlight-crowd` | A 3D crowd where exactly 38% light up in a cascade, with fog, depth of field, a camera dolly and a counter that follows the lights (Ember). |
| `quote-card` | A magazine-style quote card with masked line reveals, hairline rules drawn on and a slow push-in (Editorial). |
| `lower-third` | A broadcast name and role over a bokeh backdrop; hide the backdrop group to export a transparent ProRes overlay (Gruvbox). |
| `social-vertical` | A 1080×1920 story clip: a hook, a count-up stat and a call to action, with bouncing symbols and bloom (Neon). |
| `logo-sting` | A five-second sting for a fictional brand: a custom symbol flies in in 3D, with a camera push, light flashes and a fade to black (Glacier). |
| `three-steps-light` | A light-theme explainer: three rounded cards spring in, connectors draw on and the last step gets a check (Pastel with Optima). |

The name in brackets is the theme preset the example uses. All fonts ship with macOS.

## Open

Open a folder in the editor with **File ▸ Open**, or connect an AI agent over MCP with
`arclight mcp --project Examples/<name>.arclight`.

## Render from the command line

```sh
arclight validate Examples/kinetic-type.arclight
arclight check Examples/kinetic-type.arclight
arclight render Examples/kinetic-type.arclight --time 6.8 --scale 0.5 --out kinetic.png
arclight export Examples/kinetic-type.arclight --format mp4 --out exports/
```

Copy an example before editing it if you want to keep the original.
