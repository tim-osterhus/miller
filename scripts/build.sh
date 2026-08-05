#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/.build/swift"
swift_cache="$repo_root/.cache/swift-module-cache"
clang_cache="$repo_root/.cache/clang-module-cache"

mkdir -p "$build_root" "$swift_cache" "$clang_cache"
env \
  SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache" \
  CLANG_MODULE_CACHE_PATH="$clang_cache" \
  swift build --package-path "$repo_root" --scratch-path "$build_root"
