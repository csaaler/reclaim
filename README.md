# Reclaim

**Disk full again? It's not you. It's `node_modules`.**

System Settings shows 180 GB of *System Data* and shrugs. You've priced an external SSD.
You've opened the MacBook configurator. You've typed `rm -rf ~/Library/Developer` and
chickened out at the last second.

Don't. Reclaim scans your drive and shows you who's actually squatting there:

- 🦕 iOS simulators for versions you stopped supporting two jobs ago
- 📦 `node_modules` from 47 side projects that were "almost done"
- 🐳 Docker images from that one client in 2023
- 🤖 Android system images you downloaded for a single bug
- 👻 Caches of apps you already uninstalled

Pick what goes, review it, and get your gigabytes back. One stale simulator, just
Docker's build cache, one Chrome profile. Surgical, not scorched-earth.

**Why "Reclaim"?** `docker system df` has a column called *RECLAIMABLE*. We just made it actually happen.

> [!WARNING]
> Reclaim deletes files. You review every item first, your own data goes to the Trash,
> and nothing runs without your OK. Still: have a backup. [How it stays safe](#safety-model)

Native macOS app: Swift 6, SwiftUI, macOS 15 or later, no third-party packages, no telemetry. Version 0.1, so it's early: read the review screen.

## Features

- **By App and By Category.** Every folder, assigned to the app or tool that owns it, including leftovers of apps you already deleted.
- **Explains "System Data".** A footer splits used space into what was found, the macOS system volume, purgeable space and local snapshots, unreadable folders and the rest.
- **Dev Tools.** Xcode and simulators, Docker, Android, JetBrains, npm/pnpm/Yarn/Bun/Homebrew, Gradle, Maven, Python, Rust, Go, and build folders in your projects.
- **Explorer and Large & Old Files.** The whole Data volume as a folder tree, plus every file of 100 MB or more.
- **Review, then clean.** Collect items from any view, check every path, size and risk level, then confirm. Every step lands in History.

Everything Reclaim knows how to clean, with risk levels, is in [docs/supported-apps.md](docs/supported-apps.md).

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

> [!WARNING]
> **Reclaim deletes files.** It is provided as-is, without warranty of any kind (see [LICENSE](LICENSE)). It deletes caches permanently, moves your data to the Trash, and can run tools such as `docker image prune`. Every item carries a risk level (🟢 rebuildable cache, 🟡 costly to rebuild, 🔴 your data or config), and nothing is removed until you have reviewed and confirmed it. 🔴 files and folders always go to the Trash, so you can put them back. 🔴 tool steps (for example Docker volume prune or deleting a simulator) cannot be undone, and need the same explicit acknowledgement. Still, read the review screen carefully, keep backups (for example Time Machine) and use it at your own risk. Builds are ad-hoc signed or signed with your own development certificate, are not notarized, and the code has not been audited by a third party.

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

- [docs/supported-apps.md](docs/supported-apps.md): every app and tool Reclaim can clean, with risk levels.
- [docs/faq.md](docs/faq.md): troubleshooting and common questions.
- [docs/architecture.md](docs/architecture.md): targets, data flow and safety invariants.
- [docs/adding-an-app.md](docs/adding-an-app.md): writing a definition or an inspector.
- [Releases](https://github.com/csaaler/reclaim/releases): release notes. [CHANGELOG.md](CHANGELOG.md) covers 0.1.0.

## Trademarks

App and product names used in this project (such as Chrome, Docker, Slack, Xcode or VS Code) belong to their respective owners and are used only to identify the software whose files Reclaim manages. Their use does not imply affiliation or endorsement. macOS, Xcode, Time Machine, Photos and iCloud are trademarks of Apple Inc. Reclaim is not affiliated with or endorsed by Apple.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Christian Saaler.
