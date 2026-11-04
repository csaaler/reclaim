# Changelog

Release notes for versions after 0.1.0 are on [GitHub Releases](https://github.com/csaaler/reclaim/releases). This file is no longer updated; see [docs/release.md](docs/release.md).

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

Initial public release. Source only: build it with `scripts/build-app.sh`. There are no signed or notarized binaries.

### Added

- Disk scan of the Data volume that measures allocated size, counts hard links once, never follows symlinks and stays on one volume.
- Attribution of folders to installed apps and tools, with By App, By Category, Dev Tools, Explorer, Large & Old Files and History views.
- Disk totals that split used space into scanned data, the macOS system volume, purgeable space and local snapshots, unreadable folders and unexplained space.
- App definitions for Claude, Cursor, Linear, Notion, Postman, Slack, Spotify, Steam, Microsoft Teams, Telegram, VS Code and WhatsApp.
- Inspectors for Google Chrome profiles and caches, Docker, Xcode and simulators, Android SDK and emulators, JetBrains IDEs, JavaScript package managers and Homebrew, Gradle, Maven, Python, Rust and Go caches, project build folders, and updater leftovers.
- Cleanup list, review screen with risk levels (🟢 🟡 🔴) and per-item acknowledgement for 🔴, and a cleanup engine that re-validates every path immediately before acting, moves 🔴 items to the Trash, refuses protected paths and other volumes, and only runs tool commands and JSON edits that are on the `ToolPolicy` allow-list.
- Cleanup log at `~/Library/Application Support/Reclaim/cleanup-log.jsonl`.
- A start screen: no scan on launch, Full Disk Access required, and an explicit Start Scan button.

[0.1.0]: https://github.com/csaaler/reclaim/releases/tag/v0.1.0
