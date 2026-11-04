#!/bin/bash
# Scans tracked files for personal data, secrets and internal-process wording.
# Usage: scripts/check-privacy.sh
#
# Owner-specific patterns (name, username, email domain, ...) are deliberately NOT stored in
# this repo. Put one extended regex per line (case-insensitive) in either:
#   - the file $(git rev-parse --git-common-dir)/info/privacy-patterns (untracked), or
#   - the RECLAIM_PRIVACY_PATTERNS environment variable (newline-separated).
# When neither exists that check is skipped with a notice; CI runs the generic checks only.
set -euo pipefail

cd "$(dirname "$0")/.."

SELF="scripts/check-privacy.sh"

fail=0

# report <title> <extended-regex> [-i]
# Greps every tracked text file except this script; prints matches and marks failure.
report() {
    local title="$1" regex="$2" flag="${3:-}" out
    out=$(git ls-files -z | grep -zv -x -F "$SELF" \
        | xargs -0 grep -InE ${flag:+"$flag"} -e "$regex" 2>/dev/null || true)
    if [ -n "$out" ]; then
        echo "FAIL: $title" >&2
        echo "$out" | sed 's/^/    /' >&2
        fail=1
    fi
}

patterns_file="$(git rev-parse --git-common-dir)/info/privacy-patterns"
owner="${RECLAIM_PRIVACY_PATTERNS:-}"
if [ -f "$patterns_file" ]; then
    owner="${owner:+$owner$'\n'}$(cat "$patterns_file")"
fi
owner="$(printf '%s\n' "$owner" | sed '/^[[:space:]]*$/d' | paste -sd'|' -)"
if [ -n "$owner" ]; then
    report "owner-specific personal data" "$owner" -i
else
    echo "NOTICE: no owner-specific patterns configured (info/privacy-patterns or RECLAIM_PRIVACY_PATTERNS); skipping that check"
fi

# Home directories other than the sample ones (/Users/Shared is a system folder).
# grep has no portable negative lookahead, so filter the allowed names afterwards.
out=$(git ls-files -z | grep -zv -x -F "$SELF" | xargs -0 grep -InoE '/Users/[A-Za-z0-9._-]+' 2>/dev/null \
    | grep -vE '/Users/(sample[A-Za-z0-9._-]*|Shared|me|tester|x|a|A|\.\.\.)$' || true)
if [ -n "$out" ]; then
    echo "FAIL: home path other than /Users/sample*, /Users/Shared or the short fake names (me, tester, x, a, A, ...)" >&2
    echo "$out" | sed 's/^/    /' >&2
    fail=1
fi

# Email addresses other than example.* / example.test / noreply addresses.
out=$(git ls-files -z | grep -zv -x -F "$SELF" | xargs -0 grep -InoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null \
    | grep -viE '@(example\.[a-z]+|users\.noreply\.github\.com)$|noreply@|\.example\.test$|@example\.test$' || true)
if [ -n "$out" ]; then
    echo "FAIL: email address that is not example.* or noreply" >&2
    echo "$out" | sed 's/^/    /' >&2
    fail=1
fi

report "private key" 'BEGIN [A-Z ]*PRIVATE KEY'
report "token-like string" '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,})'
report "signing identity or team id" 'DEVELOPMENT_TEAM|Apple Development: |Developer ID (Application|Installer)'
report "internal-process wording" 'superpowers|subagent|agentic|Ruling [0-9]|\(Task [0-9]+\)|Wave [0-9]|task brief|Review Focus' -i

if [ "$fail" -ne 0 ]; then
    echo "Privacy check failed." >&2
    exit 1
fi
echo "OK: no personal data, secrets or internal-process wording found in tracked files"
