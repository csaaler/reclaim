## What

<!-- What this changes and why. For an app or tool: its name, the version you tested, and your macOS version. -->

## Evidence

<!-- Required for new or changed definitions, inspectors and tool commands. One row per location or command.
     Anonymize paths: /Users/sample/... See CONTRIBUTING.md, section D. -->

| Path or command | Recreated by the app? | What the user loses | Source or how you verified it |
|---|---|---|---|
| | | | |

## New tool commands or file edits

<!-- Leave "None" unless this adds a runTool step, a removeJSONKeys step, or a ToolPolicy entry.
     Otherwise explain why it is needed and why it is safe. These need the maintainer's approval. -->

None

## Safety checklist

- [ ] No protected path, credential, document, cloud-synced or other user-content location is touched
- [ ] Risk levels are the most conservative honest choice; folders that mix caches and user data are narrowed or 🔴
- [ ] Patterns are specific (no wildcard in the first three segments, no whole app folder unless 🔴 and justified)
- [ ] Bundle ids and process names are verified, so the running-app check works
- [ ] No new `runTool` or JSON-edit step, or it is explained above and on the `ToolPolicy` allow-list
- [ ] Inspector: `discover` and `plan` never delete, write or spawn processes directly; fail-safe behaviour is tested
- [ ] Tests use only `FixtureHome`, `FakeToolRunner`, `FakeAppChecker` and `LogicalSizer`; nothing touches my real home folder
- [ ] No personal data in code, fixtures, docs or screenshots
- [ ] No network access, telemetry, dependencies, binaries or logos added
- [ ] `swift build`, `swift test` and the `scripts/check-*.sh` checks pass without new warnings
- [ ] I agree that my contribution is licensed under the project's MIT License
