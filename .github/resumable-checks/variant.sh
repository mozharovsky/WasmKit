#!/bin/bash
# Checks out one source variant in detached state.
#
# Usage: variant.sh NAME, where NAME is head, base, upstream, or core.
#   head      The pull request head, the parent of the checks commit.
#   base      release/0.4.2 with execution control.
#   upstream  WasmKit 0.4.2.
#   core      The resumable core on upstream 0.4.2 with its documentation fix, without control.
set -euo pipefail

name="$1"
here="$(cd "$(dirname "$0")" && pwd)"
scratch="$RUNNER_TEMP/resumable-checks"
mkdir -p "$scratch"
cp "$here/core-docs.patch" "$scratch/"
git config --global --add safe.directory "$GITHUB_WORKSPACE"

case "$name" in
head) git checkout --quiet --detach HEAD^ ;;
base) git checkout --quiet --detach ac035e8b28b9c3d73afe5e93cd4d623b6e12382a ;;
upstream) git checkout --quiet --detach a7455cb8474b96b2c58f0adc1f70d0270b8010bf ;;
core)
    git checkout --quiet --detach e1df1c18b3494fb3c9799150d59f2f91fcba6d1d
    git apply "$scratch/core-docs.patch"
    git add -A
    tree="$(git write-tree)"
    [ "$tree" = a867fc3eeec53f406789feed894397f9b7c52d35 ] || { echo "::error::core tree $tree"; exit 1; }
    if git grep -n -e executionControl -e ExecutionControl -e ExecutionTermination -- Sources; then
        echo "::error::the core refers to execution control"
        exit 1
    fi
    ;;
*) echo "::error::unknown variant $name"; exit 1 ;;
esac
echo "$name at $(git rev-parse HEAD) tree $(git write-tree)"
