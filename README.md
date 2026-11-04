# Reclaim

Reclaim is a native macOS app that shows where your disk space went and cleans it up precisely. Think of it as a more detailed replacement for the Storage page in System Settings.

System Settings lumps a lot of space into "System Data" and offers few ways to act on it. Reclaim scans your disk, assigns each folder to the app or tool that owns it, and explains the rest: the macOS system volume, purgeable space and local Time Machine snapshots, and folders it could not read. Cleanup is targeted. You can remove one Chrome profile, prune only Docker's build cache, or delete one stale simulator runtime, without wiping everything an app owns.

Swift 6, SwiftUI, SwiftPM, macOS 15 or later. No third-party packages. Version 0.1, early: review every cleanup.

> [!WARNING]
> **Reclaim deletes files.** It is provided as-is, without warranty of any kind (see [LICENSE](LICENSE)). It deletes caches permanently, moves your data to the Trash, and can run tools such as `docker image prune`. Every item carries a risk level (🟢 rebuildable cache, 🟡 costly to rebuild, 🔴 your data or config), and nothing is removed until you have reviewed and confirmed it. 🔴 files and folders always go to the Trash, so you can put them back. 🔴 tool steps (for example Docker volume prune or deleting a simulator) cannot be undone, and need the same explicit acknowledgement. Still, read the review screen carefully, keep backups (for example Time Machine) and use it at your own risk. Builds are ad-hoc signed or signed with your own development certificate, are not notarized, and the code has not been audited by a third party.

## Features

- **By App.** Disk usage per app: caches, logs, containers, app support data and leftovers of apps that are no longer installed.
- **By Category.** The same data grouped by kind: caches, app data, developer tools, logs, app bundles, user files, system and other.
- **Disk totals.** A footer under every view splits the used space into what the scan found and what it could not: the macOS system volume, purgeable space and local Time Machine snapshots, unreadable folders, and space it cannot explain.
- **Dev Tools.** Purpose-built inspectors for Xcode and simulators, Docker, Android SDK and emulators, JetBrains IDEs, JavaScript package managers and Homebrew, Gradle, Maven, Python, Rust and Go caches, build folders in your project folders (`~/git`, `~/code`, `~/Developer`, `~/Projects`), and leftover updater downloads.
- **Per-app knowledge.** Definitions for Slack, Microsoft Teams, Spotify, Steam, Telegram, WhatsApp, Notion, Linear, Postman, Cursor, VS Code and Claude, each with notes on what you lose if you remove a folder, and an inspector for Chrome profiles and caches.
- **Explorer.** A folder tree of the whole Data volume with allocated sizes.
- **Large & Old Files.** Files of 100 MB or more and when they were last modified.
- **Cleanup list and review.** Add items from any view, then review every path, size, risk level and exactly how it will be removed before anything happens.
- **History.** Every cleanup step, including skipped and failed ones, is logged and shown in the app.

## Requirements

- macOS 15 (Sequoia) or later.
- Xcode 16 or later (Swift 6) to build. There are no downloadable releases yet; you build the app from source.

## Build from source

```sh
git clone https://github.com/csaaler/reclaim.git
cd reclaim
scripts/build-app.sh            # debug build
scripts/build-app.sh release    # release build
open build/Reclaim.app
```

The script builds the `ReclaimApp` product, assembles `build/Reclaim.app` and code-signs it. Run the tests with `swift test`.

### Signing

The script signs with the first "Apple Development" identity in your keychain, or with `SIGN_IDENTITY` if you set it. If neither exists, it falls back to ad-hoc signing and prints a warning. macOS ties the Full Disk Access grant to the code signature, so an ad-hoc signed build loses Full Disk Access after every rebuild. A stable signing identity (a free Apple Development certificate is enough) avoids that.

## Full Disk Access

Reclaim is not sandboxed and needs Full Disk Access to scan. Without it, macOS would ask for each protected folder the scan reaches (your media library, network volumes, other apps' data) one prompt at a time. macOS has no permission prompt for Full Disk Access itself; you turn it on yourself:

1. Open System Settings > Privacy & Security > Full Disk Access.
2. Click +, add `build/Reclaim.app`, and switch it on.
3. Quit and reopen Reclaim, for example with the start screen's "Quit & Reopen" button.

Reclaim does not scan on launch. Its start screen walks you through Full Disk Access, and the Start Scan button stays disabled until access is on. Nothing on disk is read before you press it. If access is turned off later, Rescan is refused and the start screen comes back. History stays available either way.

If you rebuild an ad-hoc signed app, macOS treats it as a new app. Remove the old Reclaim entry from the Full Disk Access list with the minus button, add the new build, and reopen it. See [docs/faq.md](docs/faq.md) for this and other common problems.

## Privacy

Reclaim makes no network connections. It has no telemetry, analytics, crash reporting or auto-update. It reads file names, sizes and dates to build its view and does not upload or store scan results.

The only data it writes, besides your preferences, is the cleanup log at `~/Library/Application Support/Reclaim/cleanup-log.jsonl`. The log contains the full paths of the items you cleaned, which can include your user name and project or profile names. Redact it before you attach it to an issue.

## Safety model

Cleanup is designed so that a mistake costs as little as possible.

- **Risk levels, shown everywhere.**
  🟢 Rebuildable cache: worst case is a slower first launch or a re-download.
  🟡 Costly to rebuild: usually re-downloadable or rebuildable; the review states anything that is lost.
  🔴 Your data or config: profiles, chat history, settings, user files.
- **🟢 and 🟡 are deleted permanently. 🔴 files and folders are always moved to the Trash** and need their own acknowledgement. The cleanup engine enforces this whatever a plugin asks for. Some 🟡 items also go to the Trash, such as project `build` and `dist` folders. Trashed bytes are counted separately, as "frees space after emptying Trash".
- **Tool steps are irreversible, even when they are 🔴.** Steps that run a tool (for example a Docker volume prune or deleting a simulator) cannot use the Trash. On a 🔴 item they need the same explicit acknowledgement in the review. The review shows the exact command, and only commands on a fixed allow-list in the engine (`ToolPolicy`) can run, without a shell, and the allow-list pins the exact tool, subcommand and arguments.
- **Nothing is deleted from browsing views.** You add items to a cleanup list and confirm them on a review screen.
- **Re-checked right before acting.** Each path is validated again at execution time: it must still exist, still be the same item, resolve inside your home folder and not be protected. A step that fails a check is skipped and reported.
- **Protected paths** (system folders, SSH and GnuPG keys, Keychains, Accounts, Cookies, iCloud Drive and other cloud storage, Photos libraries, Mail, Messages, Calendars, Contacts, Safari, Notes, iPhone and iPad backups, Preferences, the Trash, Time Machine backups) have no cleanup action at all.
- **Apps are never force-quit.** If an app must be quit first, Reclaim can ask it to quit normally; otherwise the item stays blocked.
- **No privileged helper.** Root-owned areas are view-only or cleaned only through the tool that manages them.

The full list of invariants and how the code enforces them is in [docs/architecture.md](docs/architecture.md).

## Adding support for an app

Most apps need one small Swift file that lists their cache folders and what you lose by removing each. See [docs/adding-an-app.md](docs/adding-an-app.md) for a walkthrough and [CONTRIBUTING.md](CONTRIBUTING.md) for the rules every contribution has to meet. Security problems go through [private vulnerability reporting](SECURITY.md), not public issues.

## Documentation

- [docs/faq.md](docs/faq.md): troubleshooting and common questions.
- [docs/architecture.md](docs/architecture.md): targets, data flow and safety invariants.
- [docs/adding-an-app.md](docs/adding-an-app.md): writing a definition or an inspector.
- [CHANGELOG.md](CHANGELOG.md): release notes.

## Trademarks

App and product names used in this project (such as Chrome, Docker, Slack, Xcode or VS Code) belong to their respective owners and are used only to identify the software whose files Reclaim manages. Their use does not imply affiliation or endorsement. macOS, Xcode, Time Machine, Photos and iCloud are trademarks of Apple Inc. Reclaim is not affiliated with or endorsed by Apple.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Christian Saaler.
