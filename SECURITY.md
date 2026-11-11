# Security policy

## Supported versions

Arclight is alpha software. Only the latest release receives fixes.

| Version | Supported |
|---|---|
| 0.1.x (alpha) | Yes, latest release only |
| Older builds and pre-release snapshots | No |

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub instead: go to the repository's
[Security tab](https://github.com/xndrpr/arclight/security) and choose
**[Report a vulnerability](https://github.com/xndrpr/arclight/security/advisories/new)**. Only the maintainers can
see the report, and we can discuss it, fix it and credit you in a private advisory before anything is published.

Please include:

- the Arclight version (`arclight --version`, or **Arclight ▸ About Arclight**) and your macOS version;
- what an attacker can do, and what they need first (for example "the victim opens a project I sent them");
- the smallest project folder, file or MCP request that reproduces it, and the steps.

What to expect: an acknowledgement within a week, and a fix or a decision within 90 days. Arclight is maintained by
volunteers, so these are aims, not guarantees. If a report turns out not to be a vulnerability we'll say why, and
you're welcome to open a public issue then.

## Scope

Arclight runs locally on your Mac. It has no accounts, no telemetry and no network service of its own. The parts
that handle input you may not fully trust are in scope:

- **The MCP server** (`arclight mcp`). It runs with your user's permissions and lets a connected AI agent create,
  read and write project folders: scenes, assets, fonts, symbols, templates and exports. `asset_import` copies a file
  from a path the agent names, and `export` and `render_frames` write files. Reports we want: a tool call that reads
  or writes outside the paths the agent asked for (for example, path traversal through a scene id, asset name,
  symbol pack or template name), that overwrites files it shouldn't, or that crashes or hangs the server in a way an
  agent could trigger by accident.
- **File-format parsing.** Opening a project, or a project an agent wrote, parses `project.json`, `scenes/*.json`,
  symbol packs and templates (JSON), SVG path data, images (PNG, JPEG, SVG through `asset_write`), audio files and
  fonts in `fonts/` (registered automatically). Crashes, memory-safety problems or runaway memory use on a crafted
  file are in scope.
- **Expressions.** Scenes can contain JavaScript expressions, evaluated by JavaScriptCore. An expression that can
  reach the file system, the network or anything beyond the values Arclight passes to it is a vulnerability.
- **The release build** (`Arclight.app` and the zip on the Releases page): for example, a problem in how it is
  built or packaged.

Out of scope:

- The fact that the release is ad-hoc signed and not notarized, and the macOS warning on first launch. This is
  known and documented in [docs/install.md](docs/install.md).
- What an AI agent decides to do with the access you gave it. If you connect an agent to Arclight, it can change
  your projects; every call is shown in the editor's AI panel and can be reverted from the project history.
- Problems in macOS, JavaScriptCore, Metal or AVFoundation themselves. Please report those to Apple; tell us too if
  Arclight should work around them.
- Denial of service that needs a deliberately enormous project (for example millions of layers), unless a small
  file triggers it.
