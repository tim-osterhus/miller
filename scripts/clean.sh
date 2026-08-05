#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bridge_runtime_root="/private/tmp/ai.millrace.miller-${EUID}-capability-rpc"
bridge_socket="$bridge_runtime_root/capability.sock"

terminate_bridge() {
  pkill -TERM -x MillerCapabilityBridge 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -x MillerCapabilityBridge >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  pkill -KILL -x MillerCapabilityBridge 2>/dev/null || true
}

clean_bridge_runtime() {
  [[ "$bridge_runtime_root" == \
    "/private/tmp/ai.millrace.miller-${EUID}-capability-rpc" ]] || exit 1
  [[ ! -L "$bridge_runtime_root" ]] || {
    print -u2 "refusing symbolic-link capability runtime: $bridge_runtime_root"
    exit 1
  }
  [[ ! -e "$bridge_runtime_root" ]] && return
  [[ -d "$bridge_runtime_root" ]] || exit 1
  local entries=("$bridge_runtime_root"/*(DN))
  for entry in "${entries[@]}"; do
    [[ "$entry" == "$bridge_socket" && -S "$entry" && ! -L "$entry" ]] || {
      print -u2 "refusing unrecognized capability runtime entry: $entry"
      exit 1
    }
  done
  if [[ -S "$bridge_socket" && ! -L "$bridge_socket" ]]; then
    unlink "$bridge_socket"
  fi
  rmdir "$bridge_runtime_root"
}

terminate_bridge
clean_bridge_runtime

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
