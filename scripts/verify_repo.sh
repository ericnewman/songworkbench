#!/bin/bash

set -euo pipefail

workspace="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace"

git diff --check

python3 -m compileall -q scripts Benchmarks/Tools
swift format lint --strict --recursive Sources Tests

scratch_path="$(mktemp -d "${TMPDIR:-/tmp}/songworkbench-verify.XXXXXX")"
trap 'rm -rf "$scratch_path"' EXIT
swift test --scratch-path "$scratch_path" --jobs 1
swift build --scratch-path "$scratch_path" -c release --jobs 1
