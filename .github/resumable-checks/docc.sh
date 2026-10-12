#!/bin/bash
# Builds the WasmKit documentation of the checked-out variant and lists its warnings.
#
# Usage: docc.sh NAME. The head and core variants fail on a warning in a file that the resumable
# change touches, so the job compares warnings across variants without hiding older ones.
set -uo pipefail

name="$1"
log="$RUNNER_TEMP/docc-$name.log"
warnings="$RUNNER_TEMP/docc-$name-warnings.txt"

xcodebuild -version
xcrun xcodebuild -skipMacroValidation -skipPackagePluginValidation docbuild \
    -scheme WasmKit -destination generic/platform=macOS \
    -derivedDataPath "$RUNNER_TEMP/docc-derived-data" > "$log" 2>&1
status=$?
tail -3 "$log"
grep -E ': warning: ' "$log" | sed "s|$GITHUB_WORKSPACE/||g" | sort -u > "$warnings"
echo "$name docbuild exit $status, $(wc -l < "$warnings" | tr -d ' ') distinct warnings"
cat "$warnings"
[ "$status" -eq 0 ] || { echo "::error::docbuild failed"; exit 1; }

case "$name" in
head | core)
    if grep -E 'ResumableCall\.swift|Execution/Execution\.swift|Execution/Function\.swift|Execution/Store\.swift|Docs\.docc' "$warnings"; then
        echo "::error::warnings in files of the resumable change"
        exit 1
    fi
    ;;
esac
