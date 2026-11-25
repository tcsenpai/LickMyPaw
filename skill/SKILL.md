---
name: lickmypaw
description: Analyze disk usage on macOS with LickMyPaw (open-source CleanMyMac alternative). Use when asked what is eating disk space, to find the largest files/folders, free up space, or trash big items. JSON output, fast (~660k files in 5s).
---

Binary: `<repo>/LickMyPaw.app/Contents/MacOS/LickMyPaw` (alias it as `lickmypaw`; repo default: `~/coding/SpaceLens`).

- `lickmypaw scan <path> --depth 2 --top 15 [--min 100M]` → size tree (children sorted desc, `other_size` = remainder)
- `lickmypaw big <path> [--files|--dirs] --limit 30 --min 100M` → flat ranking of largest items
- `lickmypaw trash <path>... [--yes]` → Trash (dry-run unless `--yes`)

Workflow: `scan ~ --depth 1` → drill into the biggest dir with `scan` / `big --files` → show the user the candidates → trash ONLY after explicit user approval, with `--yes`.
Notes: sizes are allocated bytes (same as `du`); files <512K are folded into `aggregate` entries; mount points are not crossed; scan `/System/Volumes/Data` for the whole disk (needs Full Disk Access for the terminal/app). Never trash system or app-support paths without confirming.
