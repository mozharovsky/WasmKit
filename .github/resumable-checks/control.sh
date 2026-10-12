#!/bin/bash
# Runs one negative control. The baseline must pass. A mutant must fail its named test within the
# time limit, and the tree must be clean again afterwards.
#
# Usage: control.sh NAME FILTER EXPECT
#   NAME    baseline, or the name of a patch in mutants/.
#   FILTER  The swift test filter.
#   EXPECT  "pass", or an extended regular expression that the failing log must match.
set -uo pipefail

name="$1"
filter="$2"
expect="$3"
here="$(cd "$(dirname "$0")" && pwd)"
traits="FileSystem,MultiThread,ComponentModel,WasmDebuggingSupport,Disassembler"
log="$RUNNER_TEMP/$name.log"

git config --global --add safe.directory "$GITHUB_WORKSPACE"
echo "head $(git rev-parse HEAD^) checks $(git rev-parse HEAD)"
if [ "$name" != baseline ]; then
    git apply "$here/mutants/$name.patch" || { echo "::error::$name does not apply"; exit 1; }
fi
git diff --stat -- Sources

swift --version
swift build --build-tests --traits "$traits" || { echo "::error::$name does not build"; exit 1; }

start=$(date +%s)
timeout 600 swift test --skip-build --traits "$traits" --filter "$filter" > "$log" 2>&1
status=$?
elapsed=$(($(date +%s) - start))
grep -E 'Test run with|recorded an issue|failed|signal|Fatal error|watchdog' "$log" | sed 's/ after [0-9.]* seconds//' | sort -u | head -60
echo "$name exit $status after ${elapsed}s"

if [ "$name" != baseline ]; then
    git apply -R "$here/mutants/$name.patch" || { echo "::error::$name does not revert"; exit 1; }
fi
dirty="$(git status --short -- Sources Tests)"
[ -z "$dirty" ] || { echo "::error::the tree is not clean: $dirty"; exit 1; }

if [ "$expect" = pass ]; then
    [ "$status" -eq 0 ] || { echo "::error::the baseline failed"; exit 1; }
    grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log" || { echo "::error::no passing test run"; exit 1; }
    exit 0
fi
[ "$status" -ne 124 ] || { echo "::error::$name ran into the time limit"; exit 1; }
[ "$status" -ne 0 ] || { echo "::error::$name survived"; exit 1; }
grep -qE "$expect" "$log" || { echo "::error::$name failed without matching: $expect"; exit 1; }
echo "$name caught by: $expect"
