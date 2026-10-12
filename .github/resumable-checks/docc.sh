#!/bin/bash
# Builds the WasmKit documentation of the checked-out variant and lists its warnings.
#
# Usage: docc.sh NAME. The head and core variants fail on any warning that upstream 0.4.2 does not
# have. The list of upstream warnings comes from the upstream variant of this job.
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
    # Upstream 0.4.2 already has these warnings. Any other warning is new.
    added="$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$(dirname "$0")/docc-upstream-warnings.txt") <(LC_ALL=C sort -u "$warnings"))"
    if [ -n "$added" ]; then
        echo "$added"
        echo "::error::warnings that upstream 0.4.2 does not have"
        exit 1
    fi
    echo "$name has only the upstream warnings"
    ;;
esac
