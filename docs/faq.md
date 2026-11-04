# FAQ and troubleshooting

## Full Disk Access

### I granted Full Disk Access, but Reclaim still shows the banner

macOS ties the Full Disk Access grant to the app's code signature. A build signed ad-hoc (the default when you have no Apple Development certificate) gets a new signature every time you rebuild, so macOS treats it as a different app, even though the old entry in the list still looks switched on.

1. Quit Reclaim.
2. Open System Settings > Privacy & Security > Full Disk Access.
3. Select the Reclaim entry and remove it with the minus button.
4. Click +, add `build/Reclaim.app` again and switch it on.
5. Open Reclaim.

To stop this from happening after every rebuild, sign with a stable identity. `scripts/build-app.sh` uses the first "Apple Development" certificate in your keychain automatically, or the identity in `SIGN_IDENTITY`. A free Apple account in Xcode is enough to create one.

### Why doesn't Reclaim ask for Full Disk Access?

macOS has no permission prompt for Full Disk Access. An app can only point you to the setting, which is what the banner's button does. You have to add and enable the app yourself.

### What is skipped without Full Disk Access?

Reclaim works without it, but cannot see everything:

- To avoid stalling on privacy prompts, the scan does not open each app's folder in `~/Library/Containers` and `~/Library/Group Containers`, the Music, TV and Photos libraries, or `/Volumes`. They are counted as unreadable.
- Other folders that macOS reserves for apps with Full Disk Access, such as Mail and Safari data, cannot be read either.

Everything it cannot read is listed as unreadable, and its size ends up in "Not explained". Nothing is lost; the numbers are just less complete.

### macOS asked whether Reclaim may access a folder

Without Full Disk Access, macOS may still ask once for some folders that the scan does not skip, for example Desktop, Documents or Downloads. Allowing it includes the folder in the scan. Declining marks it as unreadable. Reclaim only reads names, sizes and dates; it never reads file contents for the scan. Granting Full Disk Access avoids these prompts.

## Understanding the numbers

### What is "Unreadable"?

The number of folders the scan could not open. Their size is unknown, so it is part of "Not explained". Without Full Disk Access the title says "(grant Full Disk Access)". With Full Disk Access, the remaining unreadable folders are ones macOS protects even from apps with that permission.

### What is "Not explained"?

Used disk space that the scan did not find. It is the used space minus the scanned data, the macOS system volume and purgeable space. It includes unreadable folders, other volumes in the same APFS container (such as VM, Preboot and Recovery) and space held by files that were deleted but are still open in some app.

### What are "macOS system volume" and "Purgeable / local snapshots"?

The system volume is the read-only volume macOS itself lives on. It cannot be cleaned. Purgeable space includes local Time Machine snapshots; macOS frees it on its own when space runs low.

### The freed space does not match the size shown

A few reasons:

- Items moved to the Trash free space only after you empty the Trash. Reclaim reports them separately, as "frees space after emptying Trash".
- For tool steps (such as a Docker prune), Reclaim reports the change in free disk space before and after, which other activity on the Mac can affect.
- APFS clones and snapshots share blocks between files. Removing one copy of a cloned file, or a file that is still in a local snapshot, frees less than its size until the snapshot is gone.

## Cleaning up

### Why can't I clean some items?

Items that are view-only show the reason. The common ones:

- **Apple system cache.** Caches and logs whose folder belongs to Apple (`com.apple.*`) are left to macOS. Removing them can break or slow down system features, and macOS manages them itself.
- **No definition for this app yet.** Reclaim knows which app owns the folder but not what is safe to remove inside it. You can [add a definition](adding-an-app.md) or ask for one with the app support request form.
- **Not attributed to an app.** Reclaim could not tell which app owns the folder.
- **Requires admin.** Root-owned files. Reclaim has no privileged helper, so it never deletes them.
- **App bundle; uninstall the app to remove it.** Apps themselves are not deleted from Reclaim.
- **Empty the Trash in Finder.** Reclaim does not empty the Trash.
- **Protected paths** (system folders, SSH and GnuPG keys, Keychains, Accounts, Cookies, iCloud Drive and other cloud storage, Photos libraries, Mail, Messages, Calendars, Contacts, Safari, Notes, iPhone and iPad backups, Preferences, the Trash, Time Machine backups) never have a cleanup action.
- In Large & Old Files, only files directly in Downloads, Desktop, Documents, Movies, Music, Pictures or a project folder can be cleaned.

### Why does an app have to be quit first?

Apps keep their caches and databases open while they run. Removing files under a running app can corrupt its data, or the app simply writes them back. Reclaim checks on the review screen and again right before each step. It can ask the app to quit normally; it never force-quits. If the app does not quit, quit it yourself and click Check again.

Some steps need the opposite: Docker commands only work while Docker is running.

### Docker or another tool shows as unavailable

Inspectors that use a command-line tool need it to be installed in a standard location (Homebrew, `/usr/local/bin`, `/usr/bin`, the tool's own app bundle and a few per-user tool folders). Docker must also be running to list and prune its data.

### How do I undo a cleanup?

- **🔴 files and folders** (and some 🟡 ones, such as project build folders) are moved to the Trash. Open the Trash in Finder, select the item and choose File > Put Back.
- **Edited files** (for example Chrome's profile list) are backed up to the Trash first, as a copy named "... (Reclaim backup <date>)". To restore it, quit the app, then replace the edited file with the backup.
- **🟢 and 🟡 items** are deleted permanently. They are caches and rebuildable data, so the app recreates or re-downloads them when needed.
- **Tool steps** (Docker prune, deleting a simulator, uninstalling a toolchain) cannot be undone, even when the item is 🔴. The review shows "Runs command (irreversible)" and 🔴 tool steps need your acknowledgement like any other 🔴 item.

Time Machine or another backup is the only way back for permanently deleted data. Keep one.

### Where is the cleanup log?

`~/Library/Application Support/Reclaim/cleanup-log.jsonl`. It has one JSON line per step with the date, the action as it was performed (including paths and commands), the risk level and the outcome. The History view shows the same data.

The log contains full paths, which can include your user name and project or profile names. Redact it before you share it.

## Uninstalling

1. Quit Reclaim and delete `Reclaim.app` (or the `build` folder of your checkout).
2. Delete `~/Library/Application Support/Reclaim/` to remove the cleanup log.
3. Run `defaults delete dev.csaaler.reclaim` to remove its preferences.
4. Remove its entry from System Settings > Privacy & Security > Full Disk Access.

## Something else

- A bug: open an issue with the bug report form, and redact paths first.
- A missing app: use the app support request form, or [add it yourself](adding-an-app.md).
- Anything that could make Reclaim delete or change the wrong data: report it privately, see [SECURITY.md](../SECURITY.md).
