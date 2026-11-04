#!/bin/bash
# Verifies the contributor templates in templates/*.swift.txt still compile and pass, with valid
# placeholder values, registered like a real contribution, and run through DefinitionValidator and
# the inspector conformance tests.
# Works on a temporary copy of the repo; the working tree is never modified.
#
# Assumptions (derived from the templates, not hard-coded):
#   - AppDefinitionTemplate.swift.txt declares `static let <name> = AppDefinition...`
#   - InspectorTemplate.swift.txt declares `public struct <Name>: Inspector`
#   - InspectorTestTemplate.swift.txt refers to that same <Name> (suffixed with "Tests" for the suite)
# The placeholder names are replaced with unique ones so they cannot clash with real code.
# Usage: scripts/check-templates.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

fail() { echo "FAIL: $*" >&2; exit 1; }

APP_T=templates/AppDefinitionTemplate.swift.txt
INSP_T=templates/InspectorTemplate.swift.txt
TEST_T=templates/InspectorTestTemplate.swift.txt
for f in "$APP_T" "$INSP_T" "$TEST_T"; do
    [ -f "$f" ] || fail "missing $f"
done

APP_NAME="$(sed -nE 's/^[[:space:]]*static let ([A-Za-z0-9_]+) = AppDefinition.*/\1/p' "$APP_T" | head -n 1)"
INSP_NAME="$(sed -nE 's/^public struct ([A-Za-z0-9_]+): Inspector.*/\1/p' "$INSP_T" | head -n 1)"
[ -n "$APP_NAME" ] || fail "cannot find the 'static let <name> = AppDefinition' placeholder in $APP_T"
[ -n "$INSP_NAME" ] || fail "cannot find the 'public struct <Name>: Inspector' placeholder in $INSP_T"
grep -q "$INSP_NAME" "$TEST_T" || fail "$TEST_T does not refer to $INSP_NAME"

NEW_APP="templateCheckApp"
NEW_INSP="TemplateCheckInspector"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-templates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Copy only the package sources, without build output.
mkdir -p "$TMP/pkg"
rsync -a --exclude .build --exclude build \
    Package.swift Sources Tests "$TMP/pkg/"

mkdir -p "$TMP/pkg/Sources/StorageDefinitions/Apps" \
         "$TMP/pkg/Sources/StorageInspectors/TemplateCheck" \
         "$TMP/pkg/Tests/StorageInspectorsTests"

# Fill in every placeholder with valid values. The definition and the inspector get different ids,
# bundle ids and folders so they cannot collide with each other or with real code.
fill() {
    sed -E \
        -e "s/${APP_NAME}/${NEW_APP}/g" \
        -e "s/${INSP_NAME}/${NEW_INSP}/g" \
        -e "s/__AppName__/TemplateCheck/g" \
        -e "s/__app-id__/$1/g" \
        -e "s/__DisplayName__/Template Check $2/g" \
        -e "s/__BundleID__/com.example.TemplateCheck$2/g" \
        -e "s/__ProcessName__/Template Check $2/g" \
        -e "s/__SupportFolder__/Template Check $2/g" \
        "$3"
}
fill zz-template-check-definition Definition "$APP_T" \
    > "$TMP/pkg/Sources/StorageDefinitions/Apps/TemplateCheckApp.swift"
fill template-check-inspector Inspector "$INSP_T" \
    > "$TMP/pkg/Sources/StorageInspectors/TemplateCheck/${NEW_INSP}.swift"
fill template-check-inspector Inspector "$TEST_T" \
    > "$TMP/pkg/Tests/StorageInspectorsTests/${NEW_INSP}Tests.swift"

# (The definition id sorts last so the registry stays sorted when it is appended.)
# Register both, as a contributor would, so the validator and the conformance tests see them.
sed -i '' -E "s/^\\]\$/    .${NEW_APP},\\
]/" "$TMP/pkg/Sources/StorageDefinitions/AllDefinitions.swift"
sed -i '' -E "s/^(public let allInspectors: \\[any Inspector\\] = \\[)\$/\\1\\
    ${NEW_INSP}(),/" "$TMP/pkg/Sources/StorageInspectors/AllInspectors.swift"
grep -q "\\.${NEW_APP}," "$TMP/pkg/Sources/StorageDefinitions/AllDefinitions.swift" || fail "could not register the template definition"
grep -q "${NEW_INSP}()," "$TMP/pkg/Sources/StorageInspectors/AllInspectors.swift" || fail "could not register the template inspector"

cd "$TMP/pkg"
echo "Compiling templates (app: $NEW_APP, inspector: $NEW_INSP) in a temporary copy..."
swift build --build-tests >"$TMP/build.log" 2>&1 || { tail -n 40 "$TMP/build.log" >&2; fail "templates do not compile"; }
swift test --filter "${NEW_INSP}Tests" --filter DefinitionValidationTests --filter InspectorConformanceTests --filter RegistryTests \
    >"$TMP/test.log" 2>&1 || { tail -n 60 "$TMP/test.log" >&2; fail "template tests, definition validation or inspector conformance failed"; }

cd "$ROOT"
echo "OK: templates compile, pass their own test and pass definition validation and inspector conformance"
