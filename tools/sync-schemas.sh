#!/bin/zsh
# Copies schemas/ into the conformance suite's bundle (Sources/MESConformance/Resources/schemas), which a test keeps
# identical to the source.
set -euo pipefail
repo=${0:A:h:h}
rm -rf "$repo/Sources/MESConformance/Resources/schemas"
cp -R "$repo/schemas" "$repo/Sources/MESConformance/Resources/schemas"
echo "synced $(find "$repo/schemas" -name '*.json' | wc -l | tr -d ' ') schemas"
