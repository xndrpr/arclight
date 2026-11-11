# Installing Arclight

Arclight 0.1.0 is alpha software for macOS 14 or later on a Mac with Metal. There are two ways to install it:
download the release, or build it yourself.

**The release is ad-hoc signed and not notarized.** Arclight isn't signed with a paid Apple Developer ID yet, so
macOS's protection (Gatekeeper) can't check who made it and warns the first time you open a downloaded copy. The app
isn't damaged; the steps below tell macOS you trust it. Building it yourself avoids the warning entirely.

## Download the release

1. Download `Arclight-0.1.0.zip` from the [Releases page](https://github.com/xndrpr/arclight/releases). The release
   notes list its SHA-256 checksum; you can compare it with `shasum -a 256 Arclight-0.1.0.zip`.
2. Unzip it and move `Arclight.app` to `/Applications`.
3. Open Arclight once. macOS says it "cannot verify" the developer, or that it can't check the app for malicious
   software. Click **Done** (or **OK**), not *Move to Trash*.
4. Open **System Settings ▸ Privacy & Security**, scroll down to *Security*, and click **Open Anyway** next to
   "Arclight was blocked…". Confirm with your password or Touch ID.
5. If macOS asks once more, click **Open** (or **Open Anyway**). From now on Arclight opens normally.

On macOS 15 and later, right-click ▸ Open no longer skips this; use **Open Anyway** as above.

### If macOS says the app "is damaged" or offers "Move to Trash"

macOS shows this for ad-hoc signed apps that come with the "downloaded from the internet" flag, for example from a
browser, AirDrop, a zip or a chat message.

1. Click **Cancel**, not *Move to Trash*.
2. In Terminal, clear the flag and re-sign the app for your Mac:

   ```bash
   xattr -cr /Applications/Arclight.app
   codesign --force --sign - /Applications/Arclight.app
   ```

3. Open Arclight again.

## Build and install it yourself

You need the Command Line Tools (`xcode-select --install`); Xcode isn't required.

```bash
git clone https://github.com/xndrpr/arclight.git && cd arclight
Scripts/install.sh
```

The script builds the app (`Scripts/bundle.sh`), copies it to `/Applications`, clears the quarantine flag, signs it
ad-hoc for your Mac and registers it with Launch Services, so it shows up in Launchpad and Spotlight. Apps you build
yourself aren't quarantined, so macOS doesn't warn. To install somewhere else: `DEST=~/Applications Scripts/install.sh`.

Run `Scripts/install.sh` again to update. Quit Arclight first; the script stops if it's running.

## If the app disappears or "quits unexpectedly" after an update

- **Don't copy a new build on top of a running app.** macOS caches the old signature and kills the new one. Quit
  Arclight, then run `Scripts/install.sh`, which replaces the app cleanly.
- **Don't run Arclight from the `dist/` folder.** `Scripts/bundle.sh` deletes and rebuilds `dist/Arclight.app` every
  time. Install it to `/Applications` and run it from there.
- **Third-party antivirus** (not Apple's) may quarantine unsigned apps. Add `/Applications/Arclight.app` to its
  exclusions, then reinstall.

The same troubleshooting steps are in the app under **Help ▸ Install & Security Guide…**.

## Connect an AI agent

The `arclight` executable inside the app bundle is also the MCP server. Register it once, under the name `arclight`,
pointing at the installed copy (not a build folder, which may be deleted):

```bash
claude mcp add -s user arclight -- /Applications/Arclight.app/Contents/MacOS/arclight mcp
```

That's for Claude Code. Other MCP clients (Cursor, Codex and others) run the same command over stdio: command
`/Applications/Arclight.app/Contents/MacOS/arclight`, arguments `["mcp"]`. The [README](../README.md#connect-an-ai-agent)
has the configuration for each, and the editor's AI panel copies the command and an `mcpServers` entry with the
right path. If you move the app, register it again with the new path.

## Where Arclight keeps its files

Projects are folders wherever you save them (new ones default to `~/Movies/Arclight`). Outside projects, Arclight uses:

| Path | What |
|---|---|
| `~/Library/Application Support/Arclight/library/` | Your templates, theme presets and symbol packs (`templates/`, `themes/`, `symbols/`) |
| `~/Library/Application Support/Arclight/agents/`, `editors/` | Small presence files: which agent sessions and editor windows are running, and on which projects |
| `~/Library/Logs/Arclight/` | `clicks.log`, written only while **Help ▸ Record Click Diagnostics** is on |
| `~/Library/Caches/Arclight/thumbs/` | Thumbnails for the project list; safe to delete |
| Settings domain `com.xndrpr.arclight` | App preferences (`defaults read com.xndrpr.arclight`) |

To remove Arclight completely, delete the app and these folders, and run `defaults delete com.xndrpr.arclight`.

## Upgrading from Apogee

Arclight was called Apogee before 0.1.0. Nothing is lost when you switch:

- **Your library and logs are copied once.** The first time Arclight runs the app, or an `arclight` command that
  uses your library (`mcp`, `render`, `export` or `check`), it copies everything from `~/Library/Application Support/Apogee`
  and `~/Library/Logs/Apogee` into the Arclight folders. It never overwrites a file that already exists, leaves the
  Apogee folders where they are, and writes a `.migrated-from-apogee` marker so it doesn't copy again. You can delete
  the Apogee folders once you're happy.
- **Your settings are read once.** When the app starts and has no settings of its own yet, it copies them from the
  old `com.xndrpr.apogee` domain.
- **`.apogee` projects still open** in the app, the command line and the MCP server. The first time a project is
  opened, its hidden `.apogee/` folder (activity log and notes) is copied to `.arclight/`. You can rename the
  project folder to `.arclight` whenever you like.
- **Replace the MCP registration**, since the server's name and path changed:

  ```bash
  claude mcp remove -s user apogee
  claude mcp add -s user arclight -- /Applications/Arclight.app/Contents/MacOS/arclight mcp
  ```

  In other clients, rename the `apogee` server entry to `arclight` and point it at the new path.

## For maintainers: signed and notarized releases (planned)

Releases are currently ad-hoc signed. The plan is to sign them with an Apple **Developer ID** (Apple Developer
Program membership) and **notarize** them, which removes every warning for everyone who downloads the app.
`Scripts/bundle.sh` already supports this:

```bash
# once: store notary credentials in the keychain
xcrun notarytool store-credentials arclight-notary --apple-id <apple-id> --team-id <TEAMID>

# each release
DEVELOPER_ID="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=arclight-notary Scripts/bundle.sh
ditto -c -k --keepParent dist/Arclight.app dist/Arclight.zip
```

With `DEVELOPER_ID` set, `bundle.sh` signs with the hardened runtime and a secure timestamp; with `NOTARY_PROFILE`
as well, it submits the app to Apple's notary service, waits for the result and staples the ticket to the app.
Without either, it signs ad-hoc, which is what the release workflow (`.github/workflows/release.yml`) does today.
