# Supported apps and tools

Reclaim shows the disk usage of every app it can attribute a folder to. This page lists the apps and tools it has explicit knowledge of: which folders or commands it can clean, at what risk level, and how.

For everything else, folders are still shown under By App and By Category, but they are view-only ("No definition for this app yet"). To add an app, see [adding-an-app.md](adding-an-app.md).

Risk levels: 🟢 rebuildable cache, 🟡 costly to rebuild, 🔴 your data or config. 🟢 and 🟡 items are deleted permanently unless noted; 🔴 files and folders go to the Trash. Tool steps (marked "runs") cannot be undone. See the README's safety model for details.

## Apps

Definitions in `Sources/StorageDefinitions/Apps`. Each app must be quit before its folders are cleaned.

| App | What Reclaim can clean | Risk |
|---|---|---|
| Claude | Chromium caches; `vm_bundles` (sandbox VM image and session data, downloaded again) | 🟢; 🔴 |
| Cursor | Chromium caches | 🟢 |
| Linear | Chromium caches | 🟢 |
| Microsoft Teams | Chromium caches, including the WebView caches in its container | 🟢 |
| Notion | Chromium caches | 🟢 |
| Postman | Chromium caches | 🟢 |
| Slack | Chromium caches | 🟢 |
| Spotify | Streaming and offline cache (`PersistentCache`) | 🟢 |
| Steam | Client cache and download manifest cache; installed games (`steamapps`) | 🟢; 🟡 |
| Telegram | Chat history, media and account data | 🔴 |
| Visual Studio Code | Chromium caches | 🟢 |
| WhatsApp | Chat history, media and shared account data | 🔴 |

"Chromium caches" are the standard Electron cache folders under `~/Library/Application Support/<App>/`: `Cache`, `Code Cache`, `GPUCache`, the `Dawn*` caches, the service worker caches and `Crashpad`. The app rebuilds them.

## Inspectors

Inspectors in `Sources/StorageInspectors` list items that need more than a folder pattern, for example per profile or per version. Most show up under Dev Tools.

### Google Chrome

| Item | How it is cleaned | Risk |
|---|---|---|
| Cache of each profile | Deleted | 🟢 |
| On-device AI model | Deleted; Chrome may download it again | 🟢 |
| A whole profile | Moved to the Trash and removed from Chrome's profile list (`Local State` is backed up first) | 🔴 |

### Docker

Docker must be running. Every item runs a `docker … prune` command.

| Item | Risk |
|---|---|
| Build cache | 🟢 |
| Stopped containers | 🟡 |
| Unused images | 🟡 |
| Unused volumes | 🔴 |

### Xcode & Simulators

| Item | How it is cleaned | Risk |
|---|---|---|
| DerivedData of each project | Deleted | 🟢 |
| CoreSimulator caches (per user) | Deleted | 🟢 |
| System CoreSimulator caches | View-only, requires admin | 🟢 |
| Device support files per platform and OS version | Deleted; Xcode copies them again from a connected device | 🟡 |
| Simulator runtimes | Runs `xcrun simctl runtime delete` | 🟡 |
| Unavailable simulator devices | Runs `xcrun simctl delete unavailable` | 🟡 |
| Simulator devices not booted in 90+ days | Runs `xcrun simctl delete` | 🔴 |
| Archives | Moved to the Trash | 🔴 |

### Android SDK & Emulators

The emulator must not be running.

| Item | How it is cleaned | Risk |
|---|---|---|
| System images, SDK platforms, build-tools, the emulator package, SDK sources | Deleted; Android Studio downloads them again | 🟡 |
| Virtual devices (AVDs) | Moved to the Trash | 🔴 |

### JetBrains IDEs

| Item | How it is cleaned | Risk |
|---|---|---|
| Caches of each IDE version | Deleted | 🟢 |
| Settings of IDE versions that are no longer installed | Moved to the Trash | 🔴 |

### JavaScript & Homebrew

| Item | How it is cleaned | Risk |
|---|---|---|
| Homebrew cache | Runs `brew cleanup --prune=all -s` | 🟢 |
| Yarn cache | Runs `yarn cache clean` | 🟢 |
| Bun cache | Runs `bun pm cache rm` | 🟢 |
| npm cache | Runs `npm cache clean --force` | 🟡 |
| pnpm store | Runs `pnpm store prune` | 🟡 |
| Node versions installed with nvm | Deleted | 🟡 |

### Gradle, Maven, Python, Rust & Go

| Item | How it is cleaned | Risk |
|---|---|---|
| pip cache | Runs `pip3 cache purge`, or deleted when pip3 is missing | 🟢 |
| Go build cache | Runs `go clean -cache` | 🟢 |
| Cargo registry cache | Deleted | 🟢 |
| Gradle caches and wrapper distributions | Deleted | 🟡 |
| Maven repository (locally installed artifacts are lost for good) | Deleted | 🟡 |
| Go module cache | Runs `go clean -modcache` | 🟡 |
| Rust toolchains | Runs `rustup toolchain uninstall` | 🟡 |
| Python versions installed with pyenv | Runs `pyenv uninstall -f` | 🟡 |

### AI Models

Downloaded local models, one item per model. All are 🟡: each can be downloaded again, which can take a long time for large models.

| Item | How it is cleaned | Risk |
|---|---|---|
| Ollama model (`~/.ollama/models`) | Runs `ollama rm <model>`. Ollama must be running. Ollama removes only the layers no other model uses; Reclaim never deletes its blobs itself | 🟡 |
| LM Studio model folder (`~/.lmstudio/models/<publisher>/<model>`) | Deleted. LM Studio must be quit. A model you imported yourself (`lms import`) is gone for good | 🟡 |
| Hugging Face model or dataset (`~/.cache/huggingface/hub`) | Runs `hf cache rm <repo> --yes`. Without `hf`, the repo folder is deleted, but only when none of its files are in the cache's shared store (`hub/blobs`); otherwise the item is view-only | 🟡 |

Ollama sizes come from each model's manifest and count shared layers for every model that uses them. Hugging Face sizes count the repo folder plus the shared-store files it links to, so removing one model can free less than shown when another model shares its files. Without the `ollama` command, Ollama models are view-only.

Limitations: only the default locations are read. Models moved elsewhere with `OLLAMA_MODELS`, `HF_HOME` or `HF_HUB_CACHE`, or a models folder changed in LM Studio's settings, are not listed. Hugging Face Spaces in the cache are not listed. `hf` is found in Homebrew, `/usr/local/bin` and `~/.local/bin` (pipx, uv), not in a Python framework's `bin` folder.

### Project build folders

Searches `~/git`, `~/code`, `~/Developer` and `~/Projects` (change them with `defaults write dev.csaaler.reclaim codeRoots -array "~/git" "~/work"`) for build output next to a matching project file. All items are 🟡.

| Folder | Only when the folder next to it has | How it is cleaned |
|---|---|---|
| `node_modules` | `package.json` | Deleted |
| `dist` | `package.json` | Moved to the Trash |
| `build` | `build.gradle`, `build.gradle.kts` or `package.json` | Moved to the Trash |
| `target` | `Cargo.toml` or `pom.xml` | Deleted |
| `.gradle` | `settings.gradle*` | Deleted |
| `.next` | `next.config.*` or `package.json` | Deleted |
| `.build` | `Package.swift` | Deleted |
| `.venv`, `venv` | `pyproject.toml` or `requirements.txt` | Deleted |
| `DerivedData` | always | Deleted |

### Updater leftovers

Leftover auto-update downloads (Squirrel `*.ShipIt` and `*-updater` folders in the caches). Deleted, 🟢.
