# Adding support for an app

Reclaim knows about apps through two kinds of plugins. Both are compiled into the app and arrive as pull requests.

| Level | What it is | Use it when |
|---|---|---|
| 1. **Definition** (`AppDefinition`) | One small Swift value listing paths, each tagged with a kind and a note. No logic. | You only need to say "these folders belong to this app". |
| 2. **Inspector** (`Inspector`) | A Swift type that discovers items, describes them and returns a cleanup plan. | You need to read app files (profile lists, version files) or run a tool (`docker`, `rustup`, `xcrun`). |

**Choosing a level:** only paths, so write a definition. Need to read app files or run a tool, so write an inspector. If you are unsure, start with a definition; it covers most apps. Inspectors are trusted code and get a much closer review, so open an issue first and explain why a definition cannot do the job.

Plugins never delete anything. A definition only describes paths. An inspector returns a *plan*. The `CleanupEngine` is the only component that deletes, and it re-validates every path right before acting. See [architecture.md](architecture.md).

Before you start, read the contribution rules in [CONTRIBUTING.md](../CONTRIBUTING.md). They say what a pull request must include (for example, how you verified each path) and what gets rejected. This page is the how-to.

---

## Finding the right paths

Do this on your own Mac, **read-only**. Look, measure and read; do not delete anything to "see what happens". Write down what you find: the pull request asks for it.

**Bundle ID.** `CFBundleIdentifier` in the app's `Info.plist`:

```sh
plutil -extract CFBundleIdentifier raw "/Applications/Example App.app/Contents/Info.plist"
mdls -name kMDItemCFBundleIdentifier "/Applications/Example App.app"
```

Some apps have more than one (a helper or a separate beta build); list the ones whose processes hold the folders open.

**Process name.** The name Activity Monitor shows for the main process, or:

```sh
ps -axo comm= | grep -i "example"
```

Use the last path component (`/Applications/Example App.app/Contents/MacOS/Example App` gives `Example App`).

**Folders.** Most apps keep data in a few standard places. Check each with the app's name and its bundle ID:

| Where | What is usually there |
|---|---|
| `~/Library/Application Support/<Name or bundle ID>/` | Databases, settings, downloads, and the caches of Electron apps |
| `~/Library/Caches/<bundle ID>/` | Caches (already handled, see below) |
| `~/Library/Containers/<bundle ID>/Data/Library/...` | Everything for sandboxed (App Store) apps |
| `~/Library/Group Containers/<team ID>.<bundle ID>/` | Data shared between an app and its extensions, often chat databases and media |
| `~/Library/Logs/<Name>/` | Logs (already handled, see below) |
| `~/.<name>/` | Command-line tools and developer tools |

Find what is big:

```sh
du -sh ~/Library/Application\ Support/Example\ App/* | sort -h
du -d 2 -h ~/Library/Containers/com.example.ExampleApp/Data/Library | sort -h | tail -20
```

**What is in a folder, and does the app rebuild it?** Use, in order of preference:

1. The vendor's documentation or support pages (for example a page on clearing the app's cache).
2. The app's own "Clear cache" or "Offline storage" setting: note which folder it empties.
3. Well-known formats. Electron and Chromium apps use the same cache folder names (`Cache`, `Code Cache`, `GPUCache`, ...); the Electron helper below covers them.
4. A reproducible check on a test install or a throwaway user account: quit the app, move the folder to the Trash, start the app, and see whether it comes back and what is missing. Never do this with your real data.

A forum post on its own is not enough. Neither is a path suggested by an AI tool that you have not seen on a real install.

**What not to list.** Plain cache and log folders that follow Apple's convention are already handled by location rules (🟢, owning app must be quit; `com.apple.*` is view-only):

- folders directly under `~/Library/Caches/` and `~/Library/Logs/`
- `~/Library/Containers/<id>/Data/Library/Caches/<folder>`
- `~/Library/Group Containers/<id>/Library/Caches/<folder>`

A definition is for everything else. Never list protected locations (system folders, SSH and GnuPG keys, Keychains, Accounts, Cookies, iCloud Drive and other cloud storage, Photos libraries, Mail, Messages, Calendars, Contacts, Safari, Notes, iPhone and iPad backups, Preferences, the Trash, Time Machine data); the validator rejects them and the engine blocks them again at execution time. Also leave out credentials, browser profiles, documents and anything the user created.

**Group Containers.** The `Library/Caches` folder inside a group container is already covered. The rest of a group container usually holds the app's databases and media, shared with its extensions. If it is worth listing, list it as `.userData` (🔴, moved to the Trash) with a note that says what is lost, as the Telegram and WhatsApp definitions do.

---

## Walkthrough A: adding an app as a definition

This is the real file `Sources/StorageDefinitions/Apps/Spotify.swift`:

```swift
import StorageCore

extension AppDefinition {
    static let spotify = AppDefinition(
        id: "spotify",
        displayName: "Spotify",
        bundleIDs: ["com.spotify.client"],
        processNames: ["Spotify"],
        locations: [
            DefinedLocation(
                pattern: "~/Library/Application Support/Spotify/PersistentCache",
                kind: .cache,
                note: "Streaming and offline cache; rebuilt automatically"
            ),
        ]
    )
}
```

Steps:

1. **Find the identifiers and folders** as described in [Finding the right paths](#finding-the-right-paths).
2. **Copy the template.** Copy `templates/AppDefinitionTemplate.swift.txt` to `Sources/StorageDefinitions/Apps/<AppName>.swift` (for example `ExampleApp.swift`).
3. **Replace the placeholders.** The template lists them at the top. Each is written as `__Name__`:

   | Placeholder | Meaning | Example |
   |---|---|---|
   | `__appName__` | Swift name of the definition, lowerCamelCase | `exampleApp` |
   | `__app-id__` | definition id: lowercase kebab-case, unique, the short product name | `example-app` (the real ones are `vscode`, `teams`) |
   | `__DisplayName__` | the app's name as users know it | `Example App` |
   | `__BundleID__` | `CFBundleIdentifier` | `com.example.ExampleApp` |
   | `__ProcessName__` | process name | `Example App` |
   | `__SupportFolder__` | the app's folder in `~/Library/Application Support` | `Example App` |

4. **Fill in the locations.** One `DefinedLocation` per folder:
   - `pattern` starts with `~/Library/` or with `~/` and a dot-folder (`~/.example`); `~/Documents` and the other user folders are rejected. `*` matches inside one path segment; there is no `**`. The first three segments after `~/` must be literal, so `~/Library/Application Support/Example App/*.log` is fine but `~/Library/Caches/*` is not. A 🟢 or 🟡 pattern names a folder of its own: at least three segments under `~/Library` (`~/Library/Caches/Example App`, not `~/Library/Fonts`) and two under a dot-folder (`~/.example/cache`, not `~/.example`).
   - `kind`: see [Risk levels](#risk-levels).
   - `note`: one line saying what is in the folder and what is lost if it is removed. It is shown in review.
5. **Leave `mustQuitBeforeCleaning` at `true`** (the default) unless the app genuinely tolerates cleaning while it runs. The running-app check uses `bundleIDs` and `processNames`, so the validator requires at least one of them.
6. **`sideEffectNote`** is optional text shown in the review step, for example "You will need to sign in again".
7. **Register it.** Add `.exampleApp,` on its own line to `Sources/StorageDefinitions/AllDefinitions.swift`. Keep the list sorted by id; a test checks the order. Then add a row for the app to [supported-apps.md](supported-apps.md).
8. **Test.** `swift test --filter StorageDefinitionsTests`. See [What the checks enforce](#what-the-checks-enforce) for what runs.

**Electron apps** keep their Chromium caches in Application Support, where the location rules do not look. Use the helper in `Sources/StorageDefinitions/Electron.swift` (the template shows it too). It adds the standard cache folders (`Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `Service Worker/CacheStorage`, ...) under `~/Library/Application Support/<supportFolder>/`:

```swift
static let exampleApp = AppDefinition.electron(
    id: "example-app", displayName: "Example App",
    bundleIDs: ["com.example.ExampleApp"], processNames: ["Example App"],
    supportFolder: "Example App",
    extraLocations: [/* app-specific folders */]
)
```

How to tell: the app bundle contains `Contents/Frameworks/Electron Framework.framework`.

---

## Walkthrough B: adding an inspector

### The protocol

```swift
public protocol Inspector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var bundleIDs: [String] { get }               // for attribution into "By App"
    var claimedPatterns: [String] { get }         // PathPattern syntax
    var category: StorageCategory? { get }        // default nil
    var toolSearchDirectories: [String] { get }   // default []
    func discover(in context: InspectorContext) async throws -> [InspectorItem]
    func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan
    func claimedPaths(in context: InspectorContext) async -> [String]   // default: expands claimedPatterns
}
```

An `InspectorContext` gives you `home`, `tools` (a `ToolRunning`), `sizer` (a `SizeMeasuring`) and `now`. Always go through these, never `NSHomeDirectory()`, `Process` or your own size walk. That is what makes your inspector testable.

- `discover` is read-only. For each thing found, return an `InspectorItem`: a stable `id`, size, `risk`, `lastUsed`, `paths`, `whatYouLose` (shown in review), the `requirement`, an `actionTitle` such as "Remove profile", and `isActionable` (default `true`; see below). Tool-based items (Docker prune, simulator runtimes) may have empty `paths` and still be actionable.
- `plan` receives the items the user selected and returns a `CleanupPlan`: a list of `CleanupStep`s. Step actions are:
  - `.delete(path:expectedFileID:)` permanent removal (🟢/🟡 only)
  - `.trash(path:expectedFileID:)` move to the Trash (reversible)
  - `.runTool(executable:arguments:)` an **absolute** executable path plus an argument array. Never a shell string. Get the path from `context.tools.locate("name")`.
  - `.removeJSONKeys(path:edits:)` edit a JSON file with typed `JSONEdit`s: `.removeKey(keyPath)` removes a key, `.removeArrayValue(keyPath:value:)` removes one value from an array. The engine backs up the original to the Trash first. Both `runTool` and `removeJSONKeys` must match the `ToolPolicy` allow-list, or the engine refuses them; see [CONTRIBUTING.md](../CONTRIBUTING.md).
- `claimedPatterns` are locations the inspector owns. The generic layer shows them but routes cleanup through the inspector, and they are not double-counted.
- `category` puts the claimed paths in a By Category group. Developer tools return `.developerTools`; leave the default `nil` to group them by location kind.
- `toolSearchDirectories` lists extra directories where your tool may be installed, such as `~/.example/bin` (`~/` expands to the home directory). The engine only runs a tool at the path `ToolLocator` finds for it, so a directory listed here is searched for both discovery and cleanup. `ToolLocator` already searches Homebrew, `/usr/local/bin`, `/usr/bin`, `/bin`, `~/.cargo/bin`, `~/go/bin`, `~/.pyenv/bin`, `~/.local/bin`, the newest `~/.nvm` node, the Android SDK tools and Docker.app. Each entry must start with `~/` or `/`, be standardized (no `.`, `..`, empty segment, trailing `/` or `*`), and must not be inside `/tmp`, `/private/tmp`, `/var/tmp`, `/private/var/tmp`, `/Users/Shared`, `~/Downloads`, `~/Desktop` or `~/Documents`; the inspector conformance tests check this. Inspectors add `~/.bun/bin`, `~/Library/pnpm`, `~/.volta/bin`, `/usr/local/go/bin` and `/Applications/Ollama.app/Contents/Resources`.

`CleanupStep.isIrreversible` is true exactly when the step's effective action cannot be undone: a `runTool`, or a `delete` that the engine will not convert to a Trash move (🟢 and 🟡). A 🔴 `delete` counts as reversible because the engine moves it to the Trash; `trash` and `removeJSONKeys` (which backs up first) are reversible.

### Smallest real example: `UpdaterLeftoversInspector`

`Sources/StorageInspectors/Updaters/UpdaterLeftoversInspector.swift` finds leftover auto-update downloads. Read it first; it is under 100 lines. It shows the whole shape:

- `claimedPatterns` lists `~/Library/Caches/*.ShipIt`, `~/Library/Caches/*-updater` and `~/Library/Application Support/Caches/*-updater`.
- `discover` expands them with `claimedPaths(in:)`, skips symlinks and non-directories, sizes each with `context.sizer`, and builds one `InspectorItem` per folder (risk `.cache`, action "Delete leftover"). When the folder name is `<bundle id>.ShipIt` and the app is installed, it requires that app to be quit.
- `plan` maps each item to a `.delete` step that carries over the item's `requirement`.
- Its initializer takes `applicationsRoots`, so tests can point it at a fixture instead of `/Applications`.

### Advanced example: `ChromeInspector`

`Sources/StorageInspectors/Chrome/ChromeInspector.swift` (with `ChromeLocalState.swift`) handles profiles. It shows how to do several things a simple inspector does not:

- reads Chrome's `Local State` JSON to learn profile names, emails and which profile is active
- offers 🔴 profile removal as a `.trash` step, followed by a `.removeJSONKeys` step that removes the profile from Chrome's profile list
- offers 🟢 cache items per profile as `.delete` steps, and skips cache steps that sit inside a profile trashed in the same plan. The review plans each item on its own, so when you remove a profile and clear its cache in one cleanup, the app runs the plan in `CleanupPlan.orderedForExecution()` order: the profile goes to the Trash first, and its cache goes with it.
- fails safe, see below

### Rules every inspector follows

**Fail safe.** When an inspector cannot determine something safety-relevant, it does not offer the action. Real examples:

- *Chrome:* a profile can only be removed if `Local State` is readable and names the active profile. Otherwise every profile item is emitted with `isActionable: false` and the plan contains no profile steps. The active profile is never removable.
- *Missing tools* (`JSCachesInspector`, `NativeCachesInspector`): a cache whose clean command's tool is not installed is still listed, with subtitle "<tool> not found" and `isActionable: false`.
- *rustup* (`NativeCachesInspector`): toolchains are only listed when `rustup default` succeeds and names the default toolchain. If it fails, no toolchain is offered, because it could be the default one.
- *pyenv* (`NativeCachesInspector`): Python versions are only offered when `~/.pyenv/version` is readable, and never the active ones. If the file is missing, no uninstalls are offered.

**Partial failures are informational items, not errors.** If one part of the inspector fails (say `simctl` fails but the rest works), return an `InspectorItem` that reports it with `isActionable: false` and a `subtitle` with the reason. The same goes for anything listed but never cleaned, such as Xcode's admin-only CoreSimulator caches. Non-actionable items are shown but can't be added to the cleanup list, and `CleanupPlanner` never passes them to `plan`. (`XcodeInspector.errorItem` is the example.) If your `plan` returns no step for an actionable item, review shows "Nothing to do for <title>", so mark such items non-actionable in `discover` instead. Throw `InspectorUnavailable("reason")` from `discover` only when the whole inspector cannot run, for instance when Docker is not installed or not running. Never let any other error escape.

**🔴 items may use `runTool` steps.** Those are irreversible (a tool, not the Trash, does the removal) and the user must acknowledge them like any other 🔴 item. The review screen shows the command verbatim. Use `.trash` wherever a path-based removal is possible. A new tool or subcommand needs explicit maintainer approval; see CONTRIBUTING.md.

**Never put real personal data in fixtures.** No real emails, profile names, usernames, paths or tokens in test data, including data you copied from your own machine while learning a file format. Use made-up values.

**Never delete anything yourself.** An inspector only returns steps. Do not call `FileManager.removeItem` or run a destructive tool from `discover` or `plan`.

### Steps

1. Open an issue describing the app, what the inspector would find and why a definition is not enough.
2. Copy `templates/InspectorTemplate.swift.txt` to `Sources/StorageInspectors/<AppName>/<AppName>Inspector.swift` and `templates/InspectorTestTemplate.swift.txt` to `Tests/StorageInspectorsTests/<AppName>InspectorTests.swift`. Replace the placeholders listed at the top of each file (`__AppName__`, `__app-id__`, `__DisplayName__`, `__BundleID__`, `__ProcessName__`, `__SupportFolder__`; same meanings as in Walkthrough A, with `__AppName__` the UpperCamelCase type and folder name, e.g. `ExampleApp`). As copied, the pair compiles and the tests pass.
3. Write your tests first (see [Writing tests](#writing-tests)), then replace the template's discovery logic until they pass.
4. Add `<AppName>Inspector(),` on its own line at the end of the list in `Sources/StorageInspectors/AllInspectors.swift`, and add a section for it to [supported-apps.md](supported-apps.md).
   Code that needs the app's settings (today only the project-builds search folders) should use `configuredInspectors(codeRoots:)`, which returns `allInspectors` with those settings applied, rather than `allInspectors` directly.
5. Run `swift test --filter StorageInspectorsTests`. That runs your tests and `InspectorConformanceTests` against your inspector.

---

## Risk levels

Shown everywhere in the UI. Pick the highest that applies; when in doubt, go higher. A reviewer may ask you to raise a level, rarely to lower one.

| Level | Raw value | Label | Means | Examples |
|---|---|---|---|---|
| 🟢 | `cache` | Rebuildable cache | The app fully regenerates it without visible loss. Worst case: slower first launch or a re-download | Chromium `Cache`, `GPUCache`; Spotify `PersistentCache`; pip cache; Xcode DerivedData; logs; crash dumps |
| 🟡 | `rebuildable` | Costly to rebuild | Re-downloadable or rebuildable, but it takes time or bandwidth; the note states anything that is lost | Offline media, installed games, simulator runtimes, `node_modules`, Docker images, rustup toolchains, extensions, language servers |
| 🔴 | `userData` | Your data or config | Anything that could hold user content or settings | A Chrome profile, an Android AVD, Docker volumes, a chat database, drafts, local-only saves, settings, license files |

`DefinedLocation.kind` is a `LocationKind`: `cache` and `logs` map to 🟢, `rebuildable` to 🟡, `userData` and `config` to 🔴.

How to choose:

- If you cannot say for sure the app rebuilds it with nothing lost, it is not 🟢.
- If a folder mixes cache and user data, list only the cache subfolder, or list the whole folder as 🔴.
- Apps whose data is the point (note-taking, chat, password managers, database clients, audio workstations, games with local saves) default to 🔴 for anything outside a clear cache folder.

**🔴 files and folders always go to the Trash.** Definitions: 🔴 locations are moved to the Trash, 🟢 and 🟡 are deleted permanently after review. Inspectors: use `.trash` for 🔴 path steps; `InspectorConformanceTests` fails on a `.delete` of 🔴 data, and the `CleanupEngine` converts it to a move to the Trash anyway. Every 🔴 step needs an individual acknowledgement. Trashed bytes are reported as "frees space after emptying Trash" and counted separately from freed bytes. (`runTool` on a 🔴 item cannot be converted: it is irreversible and needs the acknowledgement; see above.)

## `AppStateRequirement`

Each location and each step says what state the owning app must be in:

| Case | Meaning | Use for |
|---|---|---|
| `.mustBeQuit(bundleIDs:processNames:)` | Blocked while the app runs. The user can ask it to quit gracefully; it is never force-quit. | Almost everything: caches and profiles an app holds open |
| `.mustBeRunning(bundleIDs:processNames:reason:)` | Blocked unless the app is running; `reason` explains why. | Tools that talk to a daemon, such as `docker` commands |
| `.none` | Does not matter. | Folders no process holds open, build folders |

For definitions, `mustQuitBeforeCleaning: true` (the default) means `.mustBeQuit` with the definition's bundle IDs and process names. The requirement is checked in review and again immediately before execution. With no identifiers the check could never find the app, which is why the validator requires at least one.

## Claims and precedence

When several things could explain a path, the most specific one decides how it is cleaned:

1. **Inspector claims** (`claimedPatterns`)
2. **Definitions**
3. **Location rules** (Caches, container caches, Logs)
4. **Generic attribution** (matching a folder to an installed app)
5. **Other**

A path claimed by an inspector is shown by the generic layer but cannot be raw-deleted; cleanup goes through the inspector's plan, and the bytes are not counted twice. A path covered by a definition overrides the location rules for that path. Which app a path is listed under in By App is decided separately, so it can differ from the order above.

Claims of different inspectors must not overlap; `InspectorConformanceTests` checks this.

---

## Writing tests

Use `StorageTestKit`; never test against your real home folder and never run a destructive tool.

- `FixtureHome()` creates a throwaway home directory, deleted when the object goes away. Build the tree with `file(_:bytes:modified:)`, `dir(_:)`, `symlink(_:to:)` and `json(_:_:)`, using paths relative to home. `fixture.home` is the home URL.
- `FakeToolRunner(tools: ["rustup": "/path/to/rustup"])` answers `locate`. Stub output with `stub(executable, arguments, output: ToolOutput(...))`. A call that was not stubbed throws, and `invocations` records every call so you can assert on them.
- `FakeAppChecker(running: [...])` simulates running apps (bundle ids or process names).
- `LogicalSizer()` is a `SizeMeasuring` that sums logical file sizes. Fixture files have real bytes, so sizes are exact.

Build an `InspectorContext(home: fixture.home, tools: ..., sizer: LogicalSizer())`, call `discover`, assert on the items, call `plan` with them, assert on the steps. `templates/InspectorTestTemplate.swift.txt` is a working starting point, and `Tests/StorageInspectorsTests/UpdaterLeftoversInspectorTests.swift` is a real example.

What to test:

- items found, with the right risk, size, paths and requirement
- the plan's steps and their actions
- nothing found when the app is not installed
- **the fail-safe paths:** the tool fails, the file is missing or unparseable, the output is surprising; the risky action must not be offered
- a partial failure or a "listed but not cleanable" case produces an item with `isActionable == false` (assert the flag), and `plan` returns no steps for it
- hostile input where it applies: symlinks, odd file names, very large listings

Definitions need no tests of their own.

## What the checks enforce

`swift test` runs these for every registered plugin, yours included. Their failure messages name the plugin and the rule.

**`DefinitionValidationTests`** runs `DefinitionValidator` over `allDefinitions`:

- `id` is unique and lowercase kebab-case; `displayName` is not empty
- at least one bundle ID or process name; bundle IDs are reverse-DNS (`com.example.App`); no blank process name
- at least one location; `sideEffectNote`, if set, is not empty
- every pattern starts with `~/Library/` or `~/.<folder>/`, has no empty, `.` or `..` segment, no trailing `/` and no `**`, and no `*` in its first three segments
- a `.cache`, `.logs` or `.rebuildable` pattern has at least three segments under `~/Library` and two under a dot-folder, and does not cover a whole app folder under `Application Support`, `Containers` or `Group Containers`, either as `<App>` or as `<App>/*` (those can only be 🔴)
- no pattern is a structural folder (`~/Library/Caches`, `~/Library/Application Support`, ...), which could never be cleaned
- no pattern is listed twice, in one definition or across definitions
- every location has a note
- no pattern equals, lies inside or contains a protected path
- `allDefinitions` is sorted by id

**`InspectorConformanceTests`** runs every inspector in `allInspectors` against fake homes (empty, and with a folder at each claimed pattern) and fake tools (none installed, failing, printing garbage):

- `id` is unique and lowercase kebab-case; `displayName` is not empty; no blank bundle ID
- claimed patterns start with `~/` or `/`, are well formed, have no `*` in their first two segments, do not overlap a protected path (`ProtectedPaths.overlaps(pattern:)`), cannot match a structural folder, and do not overlap other inspectors' claims or any definition's pattern (`PathPattern.overlaps`)
- `toolSearchDirectories` entries are absolute or `~/`, standardized, and outside shared, temporary and download folders
- `discover` and `plan` either succeed or throw `InspectorUnavailable`, nothing else
- every item has this inspector's id, a unique item id, a title, `whatYouLose` and `actionTitle`, a non-negative size and standardized absolute paths
- `plan` returns no steps for `[]` or for a non-actionable item
- for an actionable item, its paths are inside home (or inside the inspector's own absolute claims); every path step stays inside the item's paths; 🔴 data is never `.delete`d; no step has a lower risk than its item; `runTool` executables are absolute; `dependsOn` points to an earlier step

CI also fills in, registers and validates the templates (`scripts/check-templates.sh`), and `scripts/check-plugin-rules.sh` fails if plugin code mentions file-deleting, file-writing, process, AppleScript or network APIs, or if a definition is not registered. `InspectorRegistryTests` fails if a type in `Sources/StorageInspectors` conforms to `Inspector` but is not in `allInspectors`.

## Testing locally

```sh
swift build
swift test                                    # everything
swift test --filter StorageDefinitionsTests   # definitions only
swift test --filter StorageInspectorsTests    # inspectors, including conformance
```

To see your plugin in the app, build it with `scripts/build-app.sh` and open `build/Reclaim.app`. Look for the app in By App and check that each location shows the size and risk you expect. Use the review screen to read your notes and steps; you do not need to run a cleanup.

---

## PR checklist

- [ ] Definition: file in `Sources/StorageDefinitions/Apps/`, registered in `AllDefinitions.swift` (sorted by id). Inspector: file in `Sources/StorageInspectors/<AppName>/`, registered in `AllInspectors.swift`, with tests. Listed in `docs/supported-apps.md`.
- [ ] `swift test` passes, including `DefinitionValidationTests` and `InspectorConformanceTests`.
- [ ] Every location has an honest risk level and a one-line note about what is lost.
- [ ] Bundle ids and process names are right, so the running-app check works.
- [ ] The PR description says, for each location, how you verified it (app and macOS version, what the app does when the folder is gone, source).
- [ ] Inspector: `discover` and `plan` never delete; tool steps use absolute paths from `tools.locate` and argument arrays.
- [ ] Inspector: fail-safe behavior is implemented and tested; partial failures and listed-only items have `isActionable: false`.
- [ ] Tests use only `FixtureHome`, `FakeToolRunner`, `FakeAppChecker`, `LogicalSizer`; nothing touches the real home.
- [ ] No real personal data in fixtures.
- [ ] `swift build` and `swift test` pass with no new warnings.
