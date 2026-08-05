#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/swift"
swift_cache="$repo_root/.cache/swift-module-cache"
clang_cache="$repo_root/.cache/clang-module-cache"
node_path="/opt/homebrew/opt/node@22/bin/node"

mkdir -p "$build_root" "$swift_cache" "$clang_cache"
test "$("$node_path" --version)" = "v22.22.0"
"$node_path" --test "$repo_root/Gateway/tests/protocol.test.mjs"
env \
  SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
  CLANG_MODULE_CACHE_PATH="$clang_cache" \
  swift test \
    --package-path "$repo_root" \
    --scratch-path "$build_root" \
    --no-parallel \
    "$@"
