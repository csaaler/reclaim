# Contributing to Reclaim

Thanks for helping. The most useful contribution is support for another app, and for most apps that is one small file of paths.

Reclaim deletes files on other people's Macs, so contributions are held to a strict, written set of rules. They are listed below, each with how it is enforced:

- **[CI]** checked automatically; the pull request cannot merge while it fails.
- **[review]** checked by a code owner during review; changes to safety-critical paths need the maintainer's approval.
- **[maintainer]** a judgment call by the maintainer (csaaler).

Security problems (anything that could make Reclaim delete or change data it should not) are **not** reported in public issues or pull requests. Use [private vulnerability reporting](SECURITY.md).

By submitting a contribution, you agree that it is licensed under the project's [MIT License](LICENSE).

## Development setup

You need macOS 15 or later and Xcode 16 or later (Swift 6). There are no third-party dependencies.

```sh
git clone https://github.com/csaaler/reclaim.git
cd reclaim
swift build
swift test
```

Useful commands:

```sh
swift test --filter StorageInspectorsTests          # one test target
swift test --filter DockerInspectorTests            # one suite
scripts/build-app.sh && open build/Reclaim.app      # build and run the app
```

Running the app scans your real disk, which is fine, but do not confirm cleanups on your own machine to "test" a change. Prove behaviour with tests (see rule A7).

### What CI runs

CI runs on GitHub-hosted macOS runners for every pull request:

- `swift build` and `swift test`. The tests include `DefinitionValidationTests`, which run the definition validator over every app definition.
- `scripts/check-templates.sh`: the contributor templates in `templates/` are filled in with valid values and registered in a temporary copy of the repo, then compiled, run through their own test, `DefinitionValidationTests` and `InspectorConformanceTests`.
- `scripts/check-plugin-rules.sh`: a text search that fails if code under `Sources/StorageDefinitions` or `Sources/StorageInspectors` mentions a `FileManager` mutation, a file-writing call (`write(to:)`, `FileHandle(forWritingTo:)`, `open`, `fopen`, `creat`, `unlink`, `removefile`, `rename` and similar), `Process`, `NSTask`, `NSAppleScript`, `NSWorkspace`, `URLSession`, `URLRequest`, `NWConnection` or a socket call. It is a lint that catches honest mistakes, not a sandbox; review is the real check. The same script fails if a definition under `Apps/` is not listed in `AllDefinitions.swift`; for inspectors, a test in `swift test` fails if a type in `Sources/StorageInspectors` conforms to `Inspector` but is not in `allInspectors`.
- `scripts/check-privacy.sh`: no personal data (real home paths, email addresses and similar) in the tree.

Run the same scripts locally before you push.

## Where to start

- **Only paths to describe?** Write an app definition: one Swift value in `Sources/StorageDefinitions/Apps/`. Start from `templates/AppDefinitionTemplate.swift.txt`.
- **Need to read app files or run a tool?** Write an inspector in `Sources/StorageInspectors/`. Start from `templates/InspectorTemplate.swift.txt` and `templates/InspectorTestTemplate.swift.txt`. Open an issue first (rule C1).

[docs/adding-an-app.md](docs/adding-an-app.md) walks through both, including risk levels and app-state requirements. [docs/architecture.md](docs/architecture.md) explains the safety invariants your change must not weaken.

## Definitions of terms

- **Definition:** data only. An app's id, bundle ids, process names and path patterns, each tagged with a kind (🟢 cache or logs, 🟡 rebuildable, 🔴 user data or config) and a note saying what the user loses.
- **Inspector:** Swift code that discovers items (for example Docker images or Chrome profiles) and turns a selected item into a cleanup plan. It never deletes anything itself.
- **Step:** one action in a cleanup plan: delete a path, move a path to the Trash, run a tool, or remove keys from a JSON file. Only the `CleanupEngine` executes steps.
- **Protected path:** a location no cleanup can touch (system folders, SSH and GnuPG keys, Keychains, Accounts, Cookies, iCloud Drive and other cloud storage, Photos libraries, Mail, Messages, Calendars, Contacts, Safari, Notes, iPhone and iPad backups, Preferences, the Trash, Time Machine backups). The list lives in `Sources/StorageCore/Safety/ProtectedPathList.swift`.
- **Tool policy:** the allow-list in `Sources/StorageCore/Cleanup/ToolPolicy.swift` (`ToolPolicy`) of the tools, subcommands and JSON edits a plan may contain. The engine runs a `runTool` step only if its executable is the path `ToolLocator` finds for a listed tool and its arguments match a listed argument list, and applies a `removeJSONKeys` step (typed `JSONEdit`s) only to a listed file and edit shape. Anything else is refused and logged as skipped, in preflight and again before acting.
- **Safety-critical paths:** `Sources/StorageCore/Cleanup/`, `Sources/StorageCore/Safety/`, `Sources/StorageCore/System/`, `Sources/StorageInspectors/`, `Sources/StorageCore/Paths/`, `Sources/StorageCore/Attribution/LocationRules.swift`, `Sources/StorageCore/Snapshot/`, `Sources/StorageDefinitions/DefinitionValidator.swift`, `Package.swift`, `.github/` and `scripts/`. See [.github/CODEOWNERS](.github/CODEOWNERS).

## Contribution rules

### A. Every pull request

1. One app or one logical change per pull request. Do not mix an app addition with unrelated refactoring. [review]
2. `swift build` and `swift test` pass on CI, with no new compiler warnings. [CI for build and tests; warnings are reported but do not yet fail the job]
3. No new package dependencies, no SwiftPM plugins, no build tool plugins. `Package.swift` changes need a stated reason. [review]
4. No network access, telemetry, analytics, crash reporting, auto-update or remote configuration anywhere. [CI for network APIs in plugin code via `check-plugin-rules.sh`; review for everything else]
5. No real personal data in code, fixtures, tests, docs or screenshots: no real names, user names, email addresses, home paths, host names, profile names or tokens. Use `/Users/sample`, `com.example.*`, `example.test`, `Profile 3`. [CI via `check-privacy.sh`; review]
6. No binaries, app icons, logos or screenshots containing third-party trademarks. Refer to apps by name in text only. [review]
7. Tests never touch your real home folder and never run destructive commands. They use only `StorageTestKit`: `FixtureHome` (a throwaway home folder), `FakeToolRunner`, `FakeAppChecker` and `LogicalSizer`. Do not run `docker prune`, `xcrun simctl delete`, `brew cleanup` or similar on your machine to check your work. [review]
8. Changes to safety-critical paths need the maintainer's review, an explained design, and a test for each new branch of behaviour. [review, enforced by CODEOWNERS]
9. AI-assisted contributions are welcome, but you are responsible for every path and command in them. You must have checked each one against a real installation. Unverified generated definitions are closed. [maintainer]

### B. App definitions (data only)

1. One file in `Sources/StorageDefinitions/Apps/<AppName>.swift`, registered in `AllDefinitions.swift`. [CI]
2. A unique, lowercase kebab-case `id` (short product name, e.g. `vscode`), and the app's real bundle ids and process names so the running-app check works. [CI for the id; review for the rest]
3. Every location starts with `~/Library/` or with `~/` and a dot-folder (`~/.example`), so user folders such as `~/Documents`, `~/Desktop` and `~/Downloads` are rejected. It has a non-empty note that says what the user loses, and does not overlap a protected path. [CI: `DefinitionValidator`]
4. Patterns are specific: at least down to the app's own folder (`~/Library/Caches/<App>/...`, `~/Library/Application Support/<App>/<Subfolder>`, `~/.<tool>/<Subfolder>`). No wildcard in the first three segments and no structural folder such as `~/Library/Caches`. A 🟢 or 🟡 pattern has at least three segments under `~/Library` and two under a dot-folder, and does not cover a whole app folder under `Application Support`, `Containers` or `Group Containers` (`<App>` or `<App>/*`); such broad patterns can only be 🔴. [CI: `DefinitionValidator`] A 🔴 pattern that covers a whole app folder needs a justification. [review]
5. Risk levels are the most conservative honest choice. 🟢 only for data the app fully regenerates without anything the user would notice beyond speed (HTTP, GPU and shader caches, logs, crash dumps). 🟡 for things that are re-downloadable or rebuildable but costly (offline media, build output, extensions, language servers). 🔴 for anything that could hold user content or configuration (profiles, databases, chat history, settings, tokens, drafts, local-only saves). If a folder mixes caches and user data, list only the cache subfolder or mark the whole folder 🔴. When unsure, pick the higher level. Reviewers may raise a level. [review]
6. Never include credentials or keychains, `~/.ssh`, `~/.gnupg`, browser cookies or passwords, cloud-synced folders, `~/Documents`, `~/Desktop`, `~/Downloads`, iCloud, Mail, Messages, Photos, Preferences or Time Machine data. [CI for protected paths and user folders; review for the rest]
7. Apps that can lose user data (note-taking, chat, password managers, database clients, audio workstations, games with local saves) default to 🔴 and are reviewed individually by the maintainer. [maintainer]
8. The location must be big enough to matter (typically 50 MB or more) and must not duplicate what a generic inspector already covers (JavaScript caches, native toolchain caches, updater leftovers). [maintainer]

### C. Inspectors (code)

1. Open an issue first and explain why a definition cannot do the job. Inspectors run as trusted code with the user's permissions and are accepted sparingly. [maintainer]
2. One folder in `Sources/StorageInspectors/<Name>/`, registered in `AllInspectors.swift`, with tests that use only `StorageTestKit`. Cover discovery, planning, partial failure, a missing tool, malformed input, and hostile file names (symlinks, `..`, newlines, very many entries). [CI for the build and tests; review for coverage]
3. `discover` and `plan` never delete, write, move or spawn anything. No `FileManager` mutation, no `Process`, no network, no `NSAppleScript`, no file-writing calls. Cleanup commands appear only as `runTool` steps in the returned plan. To read a tool's output while discovering (for example `docker system df`), use `context.tools`, the injected `ToolRunning`. [CI for the APIs listed under "What CI runs"; review for the rest]
4. Fail safe. If anything safety-relevant cannot be determined (the app is running, a tool is missing, output is in an unexpected format, a read was partial), do not offer the action: return an item with `isActionable: false` and say why. [tests; review]
5. **`runTool` steps** use an executable path from `context.tools.locate` and an argument array, never a shell string. The engine runs only commands on the `ToolPolicy` allow-list in StorageCore and refuses everything else. Extending the allow-list (a new tool or a new subcommand) is a separate pull request that only the maintainer can approve, labelled `needs-security-review`, and explains why the command is safe. No `sudo`, `rm`, `mv`, `sh`, `bash`, `curl`, `osascript`, `defaults write`, `killall` or `launchctl`. [CI: engine tests; maintainer]
6. **JSON-edit steps** (`removeJSONKeys`) are also restricted by `ToolPolicy` to known files and key paths. The engine backs the file up to the Trash first and edits only the named keys. A new file or key path needs the maintainer's approval, like a new tool. The step must require the owning app to be quit. [CI: engine tests; maintainer]
7. Irreversible steps carry an accurate risk level (🔴 if data can be lost) and a "what you lose" text that matches what the command does. [review]
8. Parsing of tool output and app files is bounded and defensive: no crash on garbage. Include a test with malformed input. [CI; review]
9. No persistent state, no timers or background work, and no reads beyond what the stated purpose needs. Say in the pull request why each path is read. [review]

### D. Evidence

For every new or changed location or tool command, the pull request description lists:

- the app or tool version and the macOS version you tested on;
- the real path as you observed it, anonymized (`/Users/sample/...`);
- whether the app recreates the folder, and what happens on next launch when it is missing;
- what the user loses if it is removed;
- a source: official documentation, the app's own "clear cache" feature, a vendor support page, or a reproducible check on a throwaway profile or fixture. "Found it on a forum" is not enough on its own.

[maintainer]

### E. Tests

Write the test first, watch it fail, then make it pass. Behaviour changes without a test are not merged. New definitions need no test file of their own: the validator and registry tests cover them. [CI; review]

### F. Review

- At least one approving review from a code owner, all CI checks green and all conversations resolved before merge. Changes to safety-critical paths, `ToolPolicy` or the protected list: the maintainer only. [branch protection]
- Reviewers may ask for a higher risk level, narrower patterns, or a split into smaller pull requests.
- This is a one-maintainer project. Expect a first reply within about a week; safety-critical changes may take longer.

### G. What gets rejected

- Patterns that delete or modify user documents, credentials, keychains, browser profiles, bookmarks or passwords, mail, messages, photos, cloud-synced data or system files.
- Wildcard-heavy or app-folder-wide patterns without a clear reason, and anything like "everything under `Application Support/<App>`" marked 🟢.
- New tool commands or JSON edits without the maintainer's prior agreement; shell strings; `sudo`, privilege escalation or privileged helpers.
- Network access, telemetry, auto-update, or downloading definitions at run time.
- Paths you have not verified on a real installation.
- Third-party dependencies, binaries, vendored code with an unclear license, logos.
- Real personal data in fixtures; tests that touch the real home folder.
- Large unrelated refactors bundled with an app addition.
- Lowering a risk level without evidence.

## Commits and pull requests

- Short, imperative commit messages with a Conventional Commits prefix: `feat: add Zed definition`, `fix: skip Docker prune when the daemon is down`, `docs: ...`, `test: ...`.
- Fill in the pull request template, including the evidence table and the safety checklist.
- Pull requests are squash-merged.

## Reporting problems

- Bugs and wrong risk levels that cannot be exploited: open an issue with the bug report form.
- A missing app: use the app support request form.
- Anything that could make Reclaim delete, move or edit data outside what the user confirmed (a protected-path bypass, a symlink or race condition, a tool command that does more than it says): report it privately. See [SECURITY.md](SECURITY.md).

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
