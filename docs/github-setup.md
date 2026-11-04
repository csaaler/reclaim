# GitHub repository settings

A checklist for the maintainer. Apply it when the repository is created and check it again before making the repository public. Paths are as in the GitHub web UI.

## Before the first push

- [ ] Create the repository as **private** (`csaaler/reclaim`). Configure everything below, review the pushed tree, then make it public.
- [ ] Push only `main`. No worktree branches, no work-in-progress refs, no tags you do not mean to publish. Check with `git for-each-ref` before pushing.
- [ ] Publish only with `git push`, or from `git archive HEAD`. Never copy the working folder, which holds ignored local folders such as `build/` and `.build/`.
- [ ] Push to the private repository and get one **green CI run** before making it public. CI uses Xcode 16.4 (Swift 6.1), which has not been run against this code yet. If it fails, fix the code or select a newer Xcode that is on the `macos-15` image, and update the Xcode version in README.md and CONTRIBUTING.md to match.
- [ ] After that first green run, make the warnings-as-errors step in `.github/workflows/ci.yml` blocking: delete `continue-on-error: true` and its comment, and use `swift build --build-tests -Xswiftc -warnings-as-errors`. Then change the tag on CONTRIBUTING rule A2 ("no new compiler warnings") to `[CI]`.
- [ ] Scan the tree for secrets and personal data once (`scripts/check-privacy.sh`, plus a secrets scanner such as gitleaks).
- [ ] The maintainer account uses two-factor authentication, ideally with a passkey or hardware key.

## General (Settings > General)

- [ ] Description, website (none) and topics: `macos`, `swift`, `swiftui`, `disk-usage`, `cleanup`.
- [ ] Features: **Wiki off**. Projects off unless used. Discussions off (support goes through issues). Issues on.
- [ ] Pull requests: allow **squash merging only**, with the pull request title as the default commit message. Turn off merge commits and rebase merging.
- [ ] "Always suggest updating pull request branches" on.
- [ ] "Automatically delete head branches" on.

## Security (Settings > Code security, and Settings > Advanced Security)

- [ ] **Private vulnerability reporting: on.** SECURITY.md and the issue form link to it; it is the only channel for security reports.
- [ ] **Secret scanning: on.** **Push protection: on.**
- [ ] Dependabot alerts: on. Dependabot security updates: on. (The package has no dependencies; this covers GitHub Actions.)
- [ ] Optional: code scanning with CodeQL for Swift, with SHA-pinned actions on a macOS runner.

## Actions (Settings > Actions > General)

- [ ] Allow actions created by GitHub, plus explicitly listed third-party actions if any are pinned by SHA.
- [ ] Fork pull request workflows: **require approval for all outside collaborators**.
- [ ] Workflow permissions: **read repository contents** only.
- [ ] "Allow GitHub Actions to create and approve pull requests": off.
- [ ] No repository secrets. CI must never need any. Never use self-hosted runners for pull requests.

## Rules (Settings > Rules > Rulesets)

Create a branch ruleset for `main` (target: default branch):

- [ ] Restrict deletions; block force pushes.
- [ ] Require a pull request before merging, with **1 approving review**.
- [ ] **Require review from code owners** (see `.github/CODEOWNERS`).
- [ ] Dismiss stale approvals when new commits are pushed.
- [ ] Require approval of the most recent push.
- [ ] Require conversation resolution before merging.
- [ ] **Require status checks to pass**: the one CI job from `.github/workflows/ci.yml`, named `build-and-test` (it runs the build, the tests, `scripts/check-templates.sh`, `check-plugin-rules.sh` and `check-privacy.sh`, and assembles the app bundle). The warnings-as-errors step in that job is non-blocking until the first green run (see above). Require branches to be up to date.
- [ ] Optional: require linear history; require signed commits.
- [ ] Bypass list: empty. While the maintainer is the only reviewer, GitHub does not let authors approve their own pull requests; either add the maintainer as a bypass actor for pull requests only, or merge own changes through a pull request with an honest note. Remove the bypass once there is a second maintainer.

Create a tag ruleset for `v*`:

- [ ] Restrict creation, updates and deletions to the maintainer.

## Moderation (Settings > Moderation options)

- [ ] Reported content: allow reports from all users, so Code of Conduct reports can go to the maintainer through GitHub.
- [ ] Optional: temporary interaction limits if the repository gets spammed.

## Community standards (Insights > Community standards)

- [ ] Every item is green: description, README, Code of Conduct, CONTRIBUTING, LICENSE, SECURITY, issue templates, pull request template.

## Labels

- [ ] `bug`, `app support`, `needs-security-review` (for changes to the tool policy, the protected list or other safety-critical code), `good first issue`.

## After making it public

- [ ] Check that private vulnerability reporting and push protection are still on (some security features are only free on public repositories, so re-check after the switch).
- [ ] Open the repository in a private browser window and check what an anonymous visitor sees.
