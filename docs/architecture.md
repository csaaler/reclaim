# Architecture

Reclaim is a SwiftPM package with four library targets and one app target. It has no third-party dependencies.

```
                  +----------------------+
                  |      ReclaimApp      |   SwiftUI app: views, onboarding,
                  |     (executable)     |   scan + cleanup orchestration
                  +----------+-----------+
                             |
          +------------------+-------------------+
          |                  |                   |
+---------v---------+ +------v-----------+ +-----v-----------+
| StorageDefinitions| | StorageInspectors| |  StorageCore    |
| AppDefinition     | | Inspector        | |  scan, model,   |
| values (paths)    | | implementations  | |  attribution,   |
+---------+---------+ +------+-----------+ |  cleanup engine,|
          |                  |             |  safety, system |
          +------------------+------------>|  adapters       |
                             depends on    +-------^---------+
                                                   |
                                         +---------+--------+
                                         |  StorageTestKit  |  test-only helpers
                                         +------------------+
```

## Targets

| Target | Folder | Contents |
|---|---|---|
| `StorageCore` | `Model/` | Value types: `ScanResult`, `StorageSnapshot`, `RiskLevel`, `LocationKind`, `Category`, `VolumeStats`, `FileID` (device + inode). |
| | `Scan/` | `DiskScanner`: the read-only disk walk, built on `getattrlistbulk` (`BulkAttributes`). |
| | `Snapshot/` | `SnapshotBuilder`, which turns a scan plus definitions, inspectors and attribution into the `StorageSnapshot` the views show; `ScanTreeSizer`, which answers size questions from a finished scan. |
| | `Attribution/` | `AppIndex` (installed apps), `Attributor` (which app owns a folder), `LocationRules` (the generic cache and log locations). |
| | `Paths/` | `PathKey` (case-insensitive path comparison) and `PathPattern` (`~/` and `*` patterns). |
| | `Plugins/` | The plugin API: `AppDefinition`, `Inspector`, `CleanupPlan` and `CleanupStep`, `AppStateRequirement`. |
| | `Cleanup/` | `CleanupPlanner` (cleanup list to plan), `CleanupEngine` (the only code that deletes), the tool policy (allow-list for tool and JSON-edit steps), `RealFileOperations`, `VolumeBoundary`, `CleanupLog`, `CleanupReport`. |
| | `Safety/` | `ProtectedPathList`, `ProtectedPaths` (matching), `PathValidator` (the execution-time check). |
| | `System/` | The system boundary protocols (`ToolRunning`, `RunningAppChecking`, `SizeMeasuring`, `PathValidating`, `FileOperating`) and their real implementations: `ProcessToolRunner`, `ToolLocator`, `WorkspaceAppChecker`, `VolumeInfo`. |
| `StorageDefinitions` | `Apps/` and root | One file per app under `Apps/`, the Electron cache helper, `allDefinitions`, and the `DefinitionValidator`. |
| `StorageInspectors` | one folder per inspector | Chrome, Docker, Xcode, Android, JetBrains, JavaScript caches, native toolchain caches, project builds, updater leftovers, and `allInspectors`. |
| `StorageTestKit` | | `FixtureHome`, `FakeToolRunner`, `FakeAppChecker`, `LogicalSizer`. Used by tests only. |
| `ReclaimApp` | | The SwiftUI app: views, the start screen (Full Disk Access, then Start Scan), the cleanup list and review screen, and `ScanCoordinator`. |

`StorageDefinitions` and `StorageInspectors` depend only on `StorageCore`, never on each other or on the app. That keeps plugins small and testable on their own.

The system boundaries are protocols. Production code uses the real implementations; tests use the fakes from `StorageTestKit` and a temporary fixture home, so no test touches the real home folder or runs a real tool.

## Flow: scan, attribute, snapshot, cleanup

1. **Scan.** `DiskScanner` walks the Data volume (`/System/Volumes/Data`, shown as `/Users/...` and so on). It sums allocated size (what the disk actually uses, not the logical size), counts hard-linked files once, never follows symlinks and never crosses into another volume. It keeps directory totals and files of 100 MB or more. It is read-only. The app only starts a scan when the user presses Start Scan and Full Disk Access is on, so the scan never triggers macOS's per-folder privacy prompts.
2. **Attribute.** Each location gets an owner and a cleanability. For cleanup routing the most specific source wins: inspector claims, then definitions, then location rules, then generic attribution (matching a folder to an installed app), then "Other". Protected paths are marked protected. Paths claimed by an inspector can only be cleaned through that inspector's plan.

   Naming the owner in By App is a separate decision. When a definition and an inspector both describe an app, the definition's name is shown (`Owner.Priority` in `SnapshotBuilder`). This changes only the label, not how the path is cleaned.
3. **Snapshot.** The result is an in-memory `StorageSnapshot` that the views browse: By App, By Category, Dev Tools, Explorer, Large & Old Files. It also holds the unaccounted buckets: the macOS system volume, purgeable space and local snapshots, the unreadable folder count, and "Not explained" (used space minus everything else). Nothing from a scan is persisted.
4. **Plan.** The user adds items to the cleanup list. `CleanupPlanner` turns locations into one step each, capturing the item's `FileID` so a replaced path is refused later; 🔴 locations become Trash steps. Inspector items are grouped and passed to their inspector's `plan`. Items that are not cleanable or not actionable are dropped again here, even if the UI let them through.
5. **Review.** The review screen shows every step: path or exact command, size, risk, how it will be removed, what the user loses, and the app-state requirement. The engine's `preflight` lists blockers (app running, path invalid, acknowledgement missing, command not allowed). Each 🔴 step needs its own acknowledgement.
6. **Execute.** `CleanupEngine.execute` runs the confirmed plan step by step (see below), appends one log entry per step, and returns a `CleanupReport` with freed bytes and Trash bytes counted separately.

The only persisted state is the cleanup log (`~/Library/Application Support/Reclaim/cleanup-log.jsonl`, JSON Lines) and preferences in `UserDefaults` (for example the project folders the build-folder inspector searches).

## How the engine runs one step

For each step, in plan order:

1. If the user pressed Stop, the step is skipped. If it depends on an earlier step (`dependsOn`) that did not complete, it is skipped.
2. A 🔴 `.delete` is converted to `.trash`.
3. Path steps: the engine **measures** the size first (this can take a while and suspends; a path that already fails validation is not measured).
4. All blockers are checked again, after the measurement: app state, acknowledgement for 🔴, path validity, and for tool and JSON-edit steps the tool policy. Any blocker skips the step, so an app launched while a large folder was being measured still blocks it.
5. Path steps: the engine then **validates** the path with `PathValidator` against the `FileID` captured at planning time and **acts** through `FileOperating`. There is no `await` between validating and acting, so nothing else can run in between.
6. Tool steps: the engine records free space, runs the allowed command through `ToolRunning` with a timeout (on timeout `ProcessToolRunner` stops the tool's whole process group, so helper processes it started do not keep running), and reports the change in free space.
7. JSON-edit steps: read, edit the named keys in memory, write a backup copy and move it to the Trash, re-validate the original (including its identity), then write it atomically. Any failure leaves the original unchanged.
8. The outcome (freed, trashed, edited, skipped or failed, with a reason) is appended to the cleanup log.

A step that has started is shielded from Stop and finishes; later steps are skipped. Only one `execute` runs at a time.

## Safety invariants

These hold whatever a plugin does. Each names the code that enforces it.

1. **Only the `CleanupEngine` deletes.** Definitions are data. Inspectors return plans; their `discover` and `plan` never delete, write, move or spawn processes (CI checks plugin sources for file-mutation, process and network APIs with `scripts/check-plugin-rules.sh`). Views cannot delete; they only add to the cleanup list. Inspectors are trusted Swift code running with the user's permissions, so this invariant is also a review rule: every inspector change is reviewed by the maintainer.
2. **Measure, validate, act.** Immediately before each path step the engine re-validates the path and then acts with no suspension point in between. A step that fails validation is skipped and reported, never deleted on a best-effort basis.
3. **What `PathValidator` checks.** The path must be absolute and standardized (no `.` or `..` component, no NUL byte), not `/`, and must still exist. Symlinks are resolved in the parent folders only; the final component is validated (and removed) as the link itself, never its destination. The resolved path must not be protected, must not be an ancestor of a protected path, must not be the home folder or one of its structural folders (`~/Library`, `~/Library/Caches`, `~/Library/Logs`, `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Developer`; their contents may be cleaned), must lie inside the allowed root (the home folder), and must still have the `FileID` captured at planning time.
4. **The protected list is a hard block.** `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, `~/.ssh`, `~/.gnupg`, `~/Library/Keychains`, `~/Library/Accounts`, `~/Library/Cookies`, `~/Library/Mobile Documents` (iCloud Drive), `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Calendars`, `~/Library/Application Support/AddressBook`, `~/Library/Safari`, Apple Notes (`~/Library/Group Containers/group.com.apple.notes`, `~/Library/Containers/com.apple.Notes`), `~/Library/Preferences`, iPhone and iPad backups (`~/Library/Application Support/MobileSync`), any `*.photoslibrary`, the Trash (`~/.Trash`), and Time Machine data on other volumes (`Backups.backupdb`, `*.backupbundle`, `*.sparsebundle`). They are shown with sizes but have no cleanup action. The list lives in `ProtectedPathList`; `DefinitionValidator` and the inspector conformance tests reject patterns that overlap it (both call `ProtectedPaths.overlaps(pattern:)`, which also catches a broad wildcard such as `~/Library/*`), and `PathValidator` enforces it at execution time.
5. **Deletes stay on one volume.** Before removing a folder, `RealFileOperations` walks it once with `lstat` (no symlinks followed) and refuses it if anything inside is on another device, such as a mounted disk image or share, or if it holds too many entries to check.
6. **🔴 files and folders always go to the Trash.** The engine converts a 🔴 delete into a Trash move whatever the plugin asked for. 🔴 tool steps (Docker volumes, simulators) cannot be undone and are labelled irreversible in review. The engine runs a 🔴 step of either kind only with the user's acknowledgement (checked in preflight and again before acting). Trashed bytes are counted separately from freed bytes.
7. **Tool and JSON-edit steps are allow-listed.** A `runTool` step is an absolute executable plus an argument array; no shell is ever involved. `CleanupEngine` runs a `runTool` step only if its executable is exactly the path that `ToolLocator` finds for a tool named in `Sources/StorageCore/Cleanup/ToolPolicy.swift`, and its arguments match one of that tool's listed argument lists (fixed subcommands and flags, plus narrow value classes such as a simulator UUID, a toolchain name, an Ollama model name or a Hugging Face repo id). It applies a `removeJSONKeys` step (a list of typed `JSONEdit`s) only to a file and edit shapes listed there (today only Chrome's `Local State` profile list); those steps are also path-validated like any other and back the original up to the Trash before writing. Anything else is refused and logged as skipped, both in preflight and again immediately before acting. Plugins cannot extend the allow-list; supporting a new tool, flag or editable file means changing `ToolPolicy.swift`, which needs code-owner review. Tool steps are irreversible, the review screen shows the exact command, and on a 🔴 item they need acknowledgement.
8. **App state is enforced.** A step's `AppStateRequirement` is shown in review and re-checked immediately before execution (for path steps, after the size measurement). Apps are never force-quit; the user can ask an app to quit normally.
9. **Everything is logged.** Every step, including skipped and failed ones, gets one entry in the cleanup log, which History shows. A failed log write is reported but does not undo what already happened on disk.
10. **No privileged helper.** Root-owned paths are view-only ("requires admin") or cleaned only through the tool that manages them.
11. **Started steps finish; dependent steps wait.** Stop skips the steps that have not started; the running one, a tool included, completes. A step with `dependsOn` (such as editing Chrome's profile list after the profile was moved to the Trash) runs only if that earlier step completed.

### What plugins can and cannot do

| | Definition | Inspector |
|---|---|---|
| Runs code | No, it is data | Yes, with the user's permissions and Full Disk Access if granted |
| Reads files | No | Yes, for discovery |
| Deletes, moves, writes | No | No (CI check plus review); it returns a plan |
| Runs tools | No | Only read-only queries through `ToolRunning` during discovery; cleanup commands only as plan steps that pass the tool policy |
| Touches protected paths | Rejected by `DefinitionValidator` | Refused by `PathValidator` at execution time |

## The extension framework

Two kinds of plugin, both compiled in; see [adding-an-app.md](adding-an-app.md).

- A **definition** is data: id, bundle ids, process names, and path patterns, each tagged with a kind and a note.
- An **inspector** discovers items, describes them and plans a cleanup. It is read-only and fail-safe. When it cannot determine something safety-relevant, it does not offer the action, and partial failures are reported as informational items (`isActionable: false`) that are never planned.

The framework owns the rest: scanning, attribution, UI, the cleanup list, review, confirmation, running-app checks, safety validation, execution and logging. A contributor only describes or inspects. The rules for contributions are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## CI

`.github/workflows/ci.yml` has one job, `build-and-test`, on a GitHub-hosted macOS runner: `swift build`, `swift test` (which includes `DefinitionValidationTests`, so an invalid definition fails the build), and the checks in `scripts/` (`check-templates.sh`, `check-plugin-rules.sh`, `check-privacy.sh`). The plugin check rejects file-mutation, file-writing, process-spawning, AppleScript and network APIs in `Sources/StorageDefinitions` and `Sources/StorageInspectors`, and fails if a definition is not registered; a test fails if an inspector is not registered. The template check fills the templates in, registers them in a temporary copy and runs the validator and the inspector conformance tests on them. It then assembles an ad-hoc signed app bundle.

## Known limitations

These are accepted risks, not bugs. They bound what the safety checks can promise.

- **Tool lookup includes user-writable directories.** `ToolLocator` searches Homebrew, `/usr/local/bin`, `~/.cargo/bin`, `~/go/bin`, `~/.pyenv/bin`, `~/.local/bin`, `~/.nvm/versions/node/*/bin` and similar, because developer tools legitimately live there. `ToolPolicy` pins a step to the path the locator finds, not to a trusted location, so malware that can already write to one of those directories could get its own executable run under a listed tool name. That requires code execution as the user, which is out of scope (see [SECURITY.md](../SECURITY.md)).
- **Tools run with the user's environment.** `ProcessToolRunner` replaces `PATH` with the locator's directories and passes everything else through, because tools may need `HOME` and their own variables. A tool can therefore be influenced by environment variables the user set.
- **Inspectors are trusted Swift code.** They are compiled in and run with the user's permissions (and Full Disk Access, if granted). The CI plugin check is a lint for obvious mistakes, not a sandbox: code review by the maintainer is the security boundary for every inspector and for changes to `ToolPolicy`.
