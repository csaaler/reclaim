#!/bin/bash
# Plugins (definitions and inspectors) only describe cleanup plans; the CleanupEngine acts.
# Fails if code under Sources/StorageDefinitions or Sources/StorageInspectors uses a
# deletion/mutation API, starts a process or opens a network connection directly.
# Reading files is allowed.
# Also fails if a definition is declared but not registered in AllDefinitions.swift (it would
# compile, never be validated and never ship). Inspector registration is checked by
# InspectorRegistryTests.everyDeclaredInspectorIsRegistered, which compares against allInspectors.
# Usage: scripts/check-plugin-rules.sh
set -euo pipefail

cd "$(dirname "$0")/.."

DIRS=(Sources/StorageDefinitions Sources/StorageInspectors)

# Extended regex, matched per line. Comment-only lines are skipped.
# Method calls on FileManager, Data, String, FileHandle and similar.
METHODS='\.(removeItem|trashItem|moveItem|copyItem|createFile|createDirectory|createSymbolicLink|linkItem|replaceItem|setAttributes|setUbiquitous|recycle|write|truncate|truncateFile|synchronizeFile) *\('
# C functions and other bare calls (not preceded by a dot, so `store.open(` is not a hit), and the
# same calls qualified with their module (`Darwin.unlink(`).
CNAMES='unlink|unlinkat|rmdir|rename|renameat|renameatx_np|renamex_np|remove|removefile|system|popen|execl|execle|execlp|execv|execve|execvp|execvP|fork|vfork|chmod|fchmod|chown|fchown|truncate|ftruncate|mkdir|mkdirat|mkfifo|mknod|symlink|symlinkat|link|linkat|copyfile|fcopyfile|clonefile|clonefileat|fopen|freopen|open|openat|creat|dup2|fcntl'
FUNCS="(^|[^.[:alnum:]_])(${CNAMES}) *\\(|\\b(Darwin|Glibc|Foundation)\\.(${CNAMES}) *\\("
# Process and script execution.
EXEC='\bProcess\b|\bNSTask\b|posix_spawn|\bNSAppleScript\b|\bOSAScript\b|\bNSUserUnixTask\b|\bNSUserScriptTask\b|\bNSWorkspace\b'
# File handles opened for writing, and open flags that write.
WRITES='\bFileHandle\( *for(Writing|Updating)|\bO_(TRUNC|CREAT|WRONLY|RDWR|APPEND)\b|\boutputStream\(|\bOutputStream\b'
# Network.
NET='\b(NS)?URL(Session|Connection|Request)\b|\bNWConnection\b|\bNWBrowser\b|\bNWListener\b|\bCFStream|\bCFSocket|\bCFHTTP|\b(socket|connect|getaddrinfo)\(|contentsOf: *URL\(string:'
PATTERN="${METHODS}|${FUNCS}|${EXEC}|${WRITES}|${NET}"

violations=$(grep -rnE --include='*.swift' "$PATTERN" "${DIRS[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [ -n "$violations" ]; then
    echo "FAIL: plugin code must not delete, modify, run processes or use the network. Return a CleanupPlan instead." >&2
    echo "$violations" >&2
    exit 1
fi

unregistered=""
for name in $(sed -nE 's/^[[:space:]]*static let ([A-Za-z0-9_]+) = AppDefinition.*/\1/p' Sources/StorageDefinitions/Apps/*.swift); do
    grep -qE "^[[:space:]]*\.${name}," Sources/StorageDefinitions/AllDefinitions.swift \
        || unregistered+="definition .${name} is not listed in Sources/StorageDefinitions/AllDefinitions.swift"$'\n'
done
if [ -n "$unregistered" ]; then
    echo "FAIL: register every definition." >&2
    printf '%s' "$unregistered" >&2
    exit 1
fi

echo "OK: no deletion, mutation, process or network APIs under ${DIRS[*]}; every definition is registered"
