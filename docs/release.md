# Cutting a release

Reclaim is distributed as source only for now. A release is a tag on `main` plus release notes; there are no downloadable app builds, because the app is not signed with a Developer ID or notarized. Users build it themselves with `scripts/build-app.sh`.

This page is for the maintainer.

## Versioning

- [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`. While the version is below 1.0, a minor bump may contain breaking changes.
- Tags are `vX.Y.Z` and point at a commit on `main`.
- The version lives in `Sources/ReclaimApp/Resources/Info.plist`: `CFBundleShortVersionString` is the version (`0.1.0`), `CFBundleVersion` is a build number that only goes up.

## Steps

1. **Start from a clean, up-to-date `main`.**

   ```sh
   git switch main
   git pull --ff-only
   git status            # must be clean
   ```

2. **Check that CI is green on the commit you are releasing** (for the first release, that includes the first green run on GitHub described in `docs/github-setup.md`), then run the same checks locally:

   ```sh
   swift build
   swift test
   scripts/check-templates.sh
   scripts/check-plugin-rules.sh
   scripts/check-privacy.sh
   ```

3. **Smoke-test the app.** Build a release build and open it:

   ```sh
   scripts/build-app.sh release
   open build/Reclaim.app
   ```

   Run a scan, add a few 🟢 items to the cleanup list and open the review screen. Do not confirm cleanups you do not want on your own machine.

4. **Bump the version** in a pull request: `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, and in `CHANGELOG.md` move the entries under `[Unreleased]` to a new `[X.Y.Z] - YYYY-MM-DD` section (the date is the day you tag; for 0.1.0 the `[0.1.0] - Unreleased` heading becomes `[0.1.0] - YYYY-MM-DD`) and update the comparison links at the bottom. Merge it after CI passes.

5. **Tag the merge commit** with an annotated tag and push it:

   ```sh
   git switch main && git pull --ff-only
   git tag -a vX.Y.Z -m "Reclaim X.Y.Z"
   git push origin vX.Y.Z
   ```

6. **Create the GitHub release** from the tag. Paste the changelog section as the notes and add:
   - the Xcode and Swift version you tested with, and the macOS version;
   - "Source only. Build with `scripts/build-app.sh`. The app is ad-hoc or development signed and not notarized.";
   - a link to the README's safety section.

   Do not attach app bundles or zips while releases are not notarized.

## Security fixes

Fix privately reported problems in a temporary private fork (GitHub creates one from the security advisory), merge the fix to `main`, release a patch version, then publish the advisory. Credit the reporter if they want it. The app has no auto-update, so the release notes must say clearly that users need to pull and rebuild.

## Later: binary releases

Shipping a downloadable app needs a Developer ID certificate (Apple Developer Program), a hardened runtime, notarization with `notarytool` and stapling. That would also keep Full Disk Access across updates. Build such releases only from a reviewed tag on `main`, on the maintainer's machine or in a workflow that runs only on tag pushes with a protected environment, never from pull request workflows. Publish SHA-256 checksums with every artifact. Update this page, the README and SECURITY.md when that happens.
