# Security policy

Reclaim deletes, moves and edits files. A bug that makes it touch the wrong data is a security problem, even when no attacker is involved, so please report such problems privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and click **Report a vulnerability**. Only the maintainer can see the report.

Do not open a public issue, pull request or discussion for anything that could be exploited or could cause data loss. There is no email address for security reports; private vulnerability reporting is the only channel.

Please include:

- what happens and what you expected;
- the steps, or a test case using `StorageTestKit`, that reproduce it;
- the commit you built from and your macOS version;
- any paths involved, anonymized (`/Users/sample/...`).

Do not test on data you care about, and do not run destructive commands against other people's systems.

## In scope

- Any way Reclaim can delete, move, overwrite or edit data outside the set of items the user confirmed on the review screen.
- Bypasses of the protected path list or of the execution-time path checks (`PathValidator`), including symlink, hard link, mount point and path-normalization tricks.
- Time-of-check to time-of-use races between validating a path and acting on it.
- A cleanup that crosses into another volume (a mounted disk image, share or external drive).
- `runTool` or JSON-edit steps that get past the engine's tool policy, or run a command other than the one shown on the review screen. (Tool lookup and the inherited environment have known limits; see below.)
- A definition or inspector that would pass review and CI but deletes user data, reads data it does not need, or makes network connections.
- 🔴 path steps (files and folders) that are deleted permanently instead of moved to the Trash, or any 🔴 step that runs without the user's acknowledgement. (🔴 tool steps such as a Docker volume prune cannot use the Trash by nature; the review labels them irreversible.)
- Personal data leaking out of the app (it is designed to make no network connections and to store only the cleanup log).

## Out of scope

- Risk levels you think are too low, or a missing note, when there is no way to exploit it. Open a normal issue.
- Problems that need an attacker who already runs code as your user or has administrator rights.
- Damage caused by confirming a cleanup whose review screen accurately described what would happen.
- Issues in macOS, Xcode, Docker or other third-party tools themselves.

## Known limitations

These are accepted risks. Reports that only restate them are not vulnerabilities.

- **Tool lookup includes user-writable directories.** Reclaim finds developer tools (`docker`, `npm`, `cargo`, `pyenv` and others) in places such as `~/.cargo/bin`, `~/.local/bin` and `~/.nvm`, because that is where they are installed. `ToolPolicy` allows only listed tools, subcommands and arguments, and only at the path the lookup finds, but it cannot tell a real tool from a replacement planted in one of those directories by something already running as you.
- **Tools run with your environment.** Only `PATH` is replaced; the rest of your environment is passed to the tool.
- **Inspectors are trusted Swift code.** They are compiled into the app and run with your permissions. CI checks catch obvious misuse, but they are not a sandbox. Maintainer review of every inspector and of `ToolPolicy` is the boundary.

See [docs/architecture.md](docs/architecture.md#known-limitations).

## Supported versions

Only the latest commit on `main` is supported. There are no binary releases yet; fixes land on `main`, and you get them by pulling and rebuilding.

## What to expect

Reclaim is maintained by one person in their spare time. You can expect:

- an acknowledgement within about 7 days;
- an assessment and, for confirmed problems, a plan for a fix within about 30 days;
- credit in the advisory and the release notes, if you want it.

Please give the maintainer a reasonable chance to fix the problem before you disclose it publicly. Once a fix is on `main`, the report is published as a GitHub security advisory.
