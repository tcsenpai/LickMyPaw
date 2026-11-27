# Changelog

All notable changes to LickMyPaw. Versions follow [semver](https://semver.org/). Builds are unsigned and not notarized until 1.0.0.

## [Unreleased]

### Added
- **Assistant (macOS 26 and later, with Apple Intelligence).** A chat bubble at the bottom of the sidebar opens an assistant over any page. Ask what takes up space, what can be cleaned, which apps you no longer use, what starts at login or which apps use the most memory. It runs on Apple's on-device model, reads only sizes, names and dates through eight fixed read-only tools, never what is inside your files, and cannot delete anything: it points you to the page that does. Answers come in the language of your question. On Macs without it, the bubble explains why and, when you can fix it, opens the right System Settings pane.
- **Private Cloud Compute (macOS 27, experimental builds only).** An opt-in switch, off by default, lets longer conversations use Apple's Private Cloud Compute model. If it does not answer, this Mac answers and the chat says why.

### Changed
- The sidebar no longer scrolls: icons shrink to fit the window height.
- Processes named only by a version number (for example `…/claude/versions/2.1.331`) are shown with their folder name.
- CI builds on macOS 26 so release builds include the assistant.

### Fixed
- **Updates tab:** Homebrew casks are matched to apps by the app each cask actually installed (from Homebrew's install receipt), not by guessing from the app name. Casks whose app has a different name now show their updates, and a cask can no longer claim an unrelated app that happens to share its name. Casks installed by old Homebrew versions without a receipt still fall back to the name.

### Changed
- `--i18n-check` now checks every translation table against English: missing or extra keys and mismatched format placeholders. It exits with an error when anything is off.

## [0.2.1] - 2026-11-27

### Fixed
- In Prowl, double-clicking a bubble could open a different folder, often a small one, and the tooltip named the wrong item. On macOS 15 each bubble took clicks across the whole view, so the bubble drawn last won every click. Clicks and hover now land only on the circle you point at. Thanks to @samsonvd for the report and the recording ([#1](https://github.com/tcsenpai/LickMyPaw/issues/1)).

## [0.2.0] - 2026-11-26

The "feels like a real app" release: a menu bar item, five new tools, an updater, and fixes for two launch problems.

### Added
- **Menu bar item.** A paw icon with a popover showing free disk space, memory pressure, CPU load and the Trash, with shortcuts to empty the Trash, run Smart Care and open the app. It can be turned off in Settings. Closing the window keeps the app in the menu bar.
- **Launch at login**, off by default, with the real system approval state shown in Settings.
- **Notifications** when the disk is almost full or the Trash gets big. Off by default, at most one per day, thresholds in Settings. No scans run in the background.
- **Self-update.** The app checks GitHub Releases once a day (you can turn it off or check by hand). It downloads the zip, verifies its SHA-256 against the release checksums and the bundle identity, swaps the app and relaunches. `lickmypaw update --check` does the check from the command line.
- **Maintenance.** Flush the DNS cache, reindex Spotlight, rebuild the Launch Services database, clear font caches, verify the startup disk, and list or thin local Time Machine snapshots. Commands that need admin rights show the exact command first and use the standard macOS password prompt.
- **Privacy cleaner.** Caches, history, cookies and download lists for Safari, Chrome, Edge, Brave, Arc and Firefox, plus recent items, Quick Look cache, quarantine events and shell history. Browsers must be quit first. Everything goes to the Trash, so it can be undone.
- **Shredder.** Overwrites a file with a random pass and a zero pass, then deletes it. It cannot be undone, and on SSD and APFS an overwrite is not guaranteed to reach the old blocks. The app says so.
- **Updates tab in Applications.** Finds updates for apps that use Sparkle, the Mac App Store or Homebrew casks. It touches the network only when you press the button.
- **More Cleanup categories**: Mail downloads, iOS device backups, Simulator devices, Xcode DeviceSupport and Archives. iOS backups and Archives start unchecked.

### Fixed
- The app hung at launch with 100% CPU and no menu bar icon. SwiftUI writes the menu bar `isInserted` value back on every update, and binding it straight to a stored setting created an endless update loop.
- The window could end up behind other windows because the Dock and menu bar mode flipped back and forth at launch.
- The update banner could not be closed. The close button is bigger and a closed banner stays closed for that version.
- Local builds reported an old version number and offered an update to a release that was already newer than the build.

### Security
- `/etc` and `/var/db` are now denied by the safety check. `/etc/hosts` passed it once symlinks were resolved.

### Performance
- Menu bar sampling runs only while the popover is open, at 2 second intervals. One sample costs about 5 microseconds. In the background there is a single cheap free-space check every 5 minutes, and nothing else.

### Network
The app now makes these calls and no others: the GitHub release check (toggle in Settings), the ClamAV signature download if you install ClamAV from the app, and update checks you start yourself in Applications.

## [0.1.1] - 2026-11-25

### Fixed
- The app from the DMG or zip crashed on launch. SwiftPM's generated resource accessor looked for the resource bundle in the build machine's path. Resources are now found inside the app bundle.
- CI now unpacks the packaged app, hides the build folder and checks that it can load its resources, so this cannot ship again.

## [0.1.0] - 2026-11-25

Do not use this build: it crashes on launch outside the machine that built it. Use 0.1.1 or later.

First public build: Home, Prowl (disk map), Cleanup, Applications (multi-select uninstall with leftovers), Clutter (large, old and duplicate files), Performance (startup items and processes), Purr (Smart Care), Protection (ClamAV scan and system checks), Settings, an always-visible Trash button, a JSON command line for scripts and agents, and English, Italian, French and Spanish.
