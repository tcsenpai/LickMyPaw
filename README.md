# LickMyPaw

**An open-source, native macOS alternative to CleanMyMac.**
Fast, private, no telemetry, no subscription. Built with Swift and SwiftUI.

> Status: early MVP. One tool is ready (Space Lens-style disk map); the rest of the suite is on the roadmap.
> LickMyPaw is an independent project and is not affiliated with or endorsed by MacPaw.

## Features

- **Home** — disk gauge and a launcher for every tool.
- **Disk map** — scans a folder or the whole disk and shows what takes space as an interactive bubble map, with a sortable list beside it. Drill down, go back/forward, select items and move them to the Trash (always recoverable, always asks first).
- **Fast scanner** — `getattrlistbulk`-based, parallel, allocated-size accurate (matches `du`), does not cross mount points. ~660k files in about 4.5 s on Apple Silicon.
- **Agent-friendly CLI** — same binary, JSON output, plus a ready-to-use skill for AI coding agents.
- **Localized** — English, Italian, French, Spanish (follows macOS language).

## Build & run

Requires macOS 13+ and the Swift 5.9+ toolchain (Xcode or Command Line Tools). No Xcode project needed.

```bash
./bundle.sh                      # builds LickMyPaw.app (ad-hoc signed)
open LickMyPaw.app               # or: open LickMyPaw.app --args --open ~/Downloads
```

To scan the whole disk, grant the app **Full Disk Access** in System Settings → Privacy & Security.

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
.build/release/LickMyPaw --selftest           # headless check of scan/navigation/selection/trash logic
.build/release/LickMyPaw --render <dir> out.png   # render the bubble view to a PNG
```

## Roadmap

| Module | Status |
|---|---|
| Disk map (bubbles) | MVP |
| Smart Care (one-click overview) | planned |
| Cleanup (caches, logs, leftovers) | planned |
| Protection (malware / privacy) | planned |
| Performance (login items, processes, maintenance) | planned |
| Applications (uninstaller, updater) | planned |

Known MVP limits: hard links are counted twice, one bubble level at a time, ad-hoc signing only (Gatekeeper may ask on first launch).

## Translations

UI strings use the English text as the key. Add or fix translations in
`Sources/LickMyPaw/Resources/<lang>.lproj/Localizable.strings`. To test a language: `LICKMYPAW_LANG=fr open ...` is not enough for a GUI launched from Finder; run the binary directly: `LICKMYPAW_LANG=fr LickMyPaw.app/Contents/MacOS/LickMyPaw`.

## Contributing

Issues and pull requests are welcome. Keep changes small and include a `--selftest` check for new logic.

## License

MIT — see [LICENSE](LICENSE).
