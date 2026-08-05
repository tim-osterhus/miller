#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

safe_remove_tree() {
  local target="$1"
  shift
  local allowed=false
  local expected

  for expected in "$@"; do
    [[ "$target" == "$expected" ]] && allowed=true
  done
  [[ "$allowed" == true ]] || exit 1

  [[ ! -L "$target" ]] || {
    print -u2 "refusing to remove symbolic-link root: $target"
    exit 1
  }
  [[ ! -e "$target" ]] && return
  find -P "$target" -depth -delete
}

if (( $# == 0 )); then
  for target in "$repo_root/.build" "$repo_root/.artifacts" "$repo_root/.cache"; do
    safe_remove_tree \
      "$target" \
      "$repo_root/.build" \
      "$repo_root/.artifacts" \
      "$repo_root/.cache"
  done
elif [[ "$#" == 1 && "$1" == "--build-caches" ]]; then
  for target in "$repo_root/.build" "$repo_root/.cache"; do
    safe_remove_tree \
      "$target" \
      "$repo_root/.build" \
      "$repo_root/.cache"
  done
elif [[ "$#" == 1 && "$1" == "--preserve-release" ]]; then
  for target in \
    "$repo_root/.build" \
    "$repo_root/.cache" \
    "$repo_root/Gateway/node_modules" \
    "$repo_root/.artifacts/Miller.app" \
    "$repo_root/.artifacts/tests" \
    "$repo_root/.artifacts/package-staging" \
    "$repo_root/.artifacts/release-staging" \
    "$repo_root/.artifacts/overlay-build"
  do
    safe_remove_tree \
      "$target" \
      "$repo_root/.build" \
      "$repo_root/.cache" \
      "$repo_root/Gateway/node_modules" \
      "$repo_root/.artifacts/Miller.app" \
      "$repo_root/.artifacts/tests" \
      "$repo_root/.artifacts/package-staging" \
      "$repo_root/.artifacts/release-staging" \
      "$repo_root/.artifacts/overlay-build"
  done
  if [[ -f "$repo_root/.artifacts/.DS_Store" ]]; then
    find -P "$repo_root/.artifacts" -maxdepth 1 -type f -name .DS_Store -delete
  fi
elif [[ "$#" == 1 && "$1" == "--dependencies" ]]; then
  for target in \
    "$repo_root/Gateway/node_modules" \
    "$repo_root/.cache/npm" \
    "$repo_root/.artifacts/overlay-build"
  do
    safe_remove_tree \
      "$target" \
      "$repo_root/Gateway/node_modules" \
      "$repo_root/.cache/npm" \
      "$repo_root/.artifacts/overlay-build"
  done
  rmdir "$repo_root/.cache" 2>/dev/null || true
  rmdir "$repo_root/.artifacts" 2>/dev/null || true
else
  print -u2 "usage: $0 [--build-caches|--dependencies|--preserve-release]"
  exit 64
fi
