# LickMyPaw

[![Build](https://github.com/tcsenpai/LickMyPaw/actions/workflows/build.yml/badge.svg)](https://github.com/tcsenpai/LickMyPaw/actions/workflows/build.yml)

**An open-source, native macOS alternative to CleanMyMac.**
Fast, private, no telemetry, no subscription. Built with Swift and SwiftUI.

> Early MVP. LickMyPaw is an independent project and is not affiliated with or endorsed by MacPaw.

## Download

Grab the latest build from the [Releases](https://github.com/tcsenpai/LickMyPaw/releases) page (or from the *Actions* artifacts of any commit):

- `LickMyPaw-<version>-macos-arm64.dmg` — drag the app to Applications
- `LickMyPaw-<version>-macos-arm64.zip` — the zipped `LickMyPaw.app`
- `SHA256SUMS.txt`

> [!WARNING]
> **These builds are NOT signed with an Apple Developer ID and NOT notarized.** They are only ad-hoc signed (needed to run on Apple Silicon), so macOS Gatekeeper will warn you the first time. You are trusting this open-source repo and the CI that built it. Builds are Apple Silicon only (arm64), macOS 13+.

To open an unsigned app: right-click `LickMyPaw.app` → **Open** → **Open**, or remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/LickMyPaw.app
```

You can also build it yourself (below) and check that the binary matches the sources.

## Features

| Section | What it does |
|---|---|
| **Home** | Disk gauge and launcher for every tool. |
| **Prowl** | Disk map: scans a folder or the whole disk and shows what takes space as an interactive bubble map plus a list. Drill down, select, move to Trash. Counts hard links once. |
| **Cleanup** | User caches, logs, crash reports, saved state and developer caches (Xcode DerivedData, npm, bun, cargo, gradle, pip/uv, Homebrew). Skips caches of running apps. |
| **Applications** | App list with leftover finder and **multi-select uninstall**; reversible, quits running apps first. |
| **Clutter** | Large & old files, and duplicate files (size → partial hash → SHA-256; one copy per group is always kept). |
| **Performance** | Startup items (launch agents: reversible enable/disable) and processes/memory (grouped by app, polite quit only). |
| **Purr** | One-click checkup that reuses the other tools and tells you what needs attention. |
| **Protection** | Malware scan using the open-source **ClamAV** engine (external process, optional, can be installed from the app on request) plus native checks (SIP, Gatekeeper, FileVault, firewall, XProtect) and a launch-item audit. Not a full antivirus replacement. |
| **Trash button** | Always visible: shows the Trash size, opens it, and empties it (asks first). |
| **Settings** | Language, excluded folders, history with Undo. |

Principles: **everything LickMyPaw removes goes to the Trash** (so you can undo), every delete passes one safety gate (system locations and your exclusions are refused), results are cached per session with a visible "saved results" note, and there is **no network access and no telemetry** (the only network use is ClamAV's `freshclam` signature download if you choose to install/update it).

Localized in English, Italian, French and Spanish (follows macOS language).

## Build & run

Requires macOS 13+ and a Swift 5.9+ toolchain (Xcode or Command Line Tools). No Xcode project needed.

```bash
./bundle.sh                      # builds LickMyPaw.app (ad-hoc signed)
open LickMyPaw.app               # or: open LickMyPaw.app --args --page cleanup
VERSION=0.1.0 ./package.sh       # also produces dist/*.dmg, dist/*.zip and SHA256SUMS.txt
```

To scan the whole disk, grant the app **Full Disk Access** in System Settings → Privacy & Security (the app guides you). Emptying the Trash from the app asks Finder, so macOS will ask for the Automation permission once.

## CLI (for scripts and AI agents)

The app binary doubles as a CLI. Output is JSON on stdout.

```bash
BIN=LickMyPaw.app/Contents/MacOS/LickMyPaw
$BIN scan ~ --depth 2 --top 15 --min 100M     # size tree, children sorted by size
$BIN big ~/Library --files --limit 30         # flat ranking of the largest files
$BIN trash ~/Downloads/old.dmg                # dry run; add --yes to really move to Trash
```

An agent skill lives in [`skill/SKILL.md`](skill/SKILL.md). Link it into `~/.claude/skills/lickmypaw` to use it with Claude Code.

## Self-tests

```bash
.build/release/LickMyPaw --selftest              # all headless suites (also run by CI)
.build/release/LickMyPaw --selftest cleanup      # one suite
```

Suites run on throwaway fixtures and a fake home; they never touch real user data or run real `launchctl`/`brew`.

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds on an Apple Silicon runner, runs the self-tests, and packages the DMG and the zipped app. Pushing a tag like `v0.1.0` publishes a GitHub Release with the artifacts.

## Roadmap

Planned: AI assistant (on-device Apple Foundation Models with a fixed, read-only toolbox that can only *propose* actions), privacy cleaner, maintenance scripts, shredder, menu-bar mode, Developer ID signing + notarization, automatic updates.

Known limits: Apple Silicon only builds, unsigned (see above), hard-link/APFS-clone accounting is approximate, undoing a removal does not re-add files to already cached lists until you rescan.

## Translations

UI strings use the English text as the key. Add or fix translations in
`Sources/LickMyPaw/Resources/<lang>.lproj/*.strings` (one table per module). To try a language without changing macOS: `LICKMYPAW_LANG=fr LickMyPaw.app/Contents/MacOS/LickMyPaw`.

## Contributing

Issues and pull requests are welcome. Keep changes small and include a `--selftest` check for new logic. Anything that deletes must go through `Engine.trash` (and therefore `Safety.check`).

## Credits

App icon based on "Black Cat Paw" by lesnivila (CC0, via [Openclipart](https://openclipart.org/detail/28992/black-cat-paw)). Details in [`assets/icon-source/ATTRIBUTION.md`](assets/icon-source/ATTRIBUTION.md).
Malware scanning uses [ClamAV](https://www.clamav.net/) (GPLv2) as an external program; it is not bundled or linked.

## License

MIT — see [LICENSE](LICENSE).
