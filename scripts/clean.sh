#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bridge_runtime_parent="/private/tmp/ai.millrace.miller-${EUID}"
if [[ "${MILLER_CLEAN_TESTING:-0}" == "1" && \
      -n "${MILLER_CLEAN_BRIDGE_PARENT:-}" ]]; then
  [[ "${MILLER_CLEAN_BRIDGE_PARENT:h}" == "/private/tmp" && \
     "${MILLER_CLEAN_BRIDGE_PARENT:t}" == "miller-clean-test-${EUID}-"* ]] || {
    print -u2 "refusing unsafe test capability parent override"
    exit 1
  }
  bridge_runtime_parent="$MILLER_CLEAN_BRIDGE_PARENT"
fi
bridge_runtime_root="$bridge_runtime_parent/capability-bridge"
bridge_socket="$bridge_runtime_root/capability.sock"
bridge_pid_file="$bridge_runtime_root/bridge.pid"

terminate_bridge() {
  [[ ! -e "$bridge_pid_file" ]] && return 0
  [[ -f "$bridge_pid_file" && ! -L "$bridge_pid_file" ]] || {
    print -u2 "refusing unsafe capability bridge PID lease: $bridge_pid_file"
    return 1
  }
  [[ "$(stat -f '%u' "$bridge_pid_file")" == "$EUID" && \
     "$(stat -f '%Lp' "$bridge_pid_file")" == "600" ]] || {
    print -u2 "refusing capability bridge PID lease ownership/mode mismatch"
    return 1
  }
  local bridge_pid="$(<"$bridge_pid_file")"
  [[ "$bridge_pid" == <1-> && "$bridge_pid" -gt 1 ]] || {
    print -u2 "refusing non-numeric capability bridge PID lease"
    return 1
  }
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    return 0
  fi
  local command_path="$(ps -p "$bridge_pid" -o comm= | sed 's/^[[:space:]]*//')"
  [[ "${command_path:t}" == "MillerCapabilityBridge" ]] || {
    print -u2 "refusing PID lease for unexpected executable"
    return 1
  }
  /usr/sbin/lsof -a -p "$bridge_pid" -Fn "$bridge_pid_file" 2>/dev/null \
    | grep -Fx "n$bridge_pid_file" >/dev/null || {
      print -u2 "refusing PID lease not held by the recorded bridge"
      return 1
    }
  kill -TERM "$bridge_pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    kill -0 "$bridge_pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$bridge_pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$bridge_pid" 2>/dev/null || return 0
    sleep 0.05
  done
  print -u2 "capability bridge did not terminate: $bridge_pid"
  return 1
}

clean_bridge_runtime() {
  [[ "$bridge_runtime_root" == \
    "$bridge_runtime_parent/capability-bridge" ]] || exit 1
  [[ ! -L "$bridge_runtime_parent" ]] || {
    print -u2 "refusing symbolic-link capability parent: $bridge_runtime_parent"
    exit 1
  }
  if [[ -e "$bridge_runtime_parent" ]]; then
    [[ -d "$bridge_runtime_parent" && \
       "$(stat -f '%u' "$bridge_runtime_parent")" == "$EUID" && \
       "$(stat -f '%Lp' "$bridge_runtime_parent")" == "700" ]] || {
      print -u2 "refusing capability parent ownership/mode mismatch"
      exit 1
    }
  fi
  [[ ! -L "$bridge_runtime_root" ]] || {
    print -u2 "refusing symbolic-link capability runtime: $bridge_runtime_root"
    exit 1
  }
  [[ ! -e "$bridge_runtime_root" ]] && return
  [[ -d "$bridge_runtime_root" && \
     "$(stat -f '%u' "$bridge_runtime_root")" == "$EUID" && \
     "$(stat -f '%Lp' "$bridge_runtime_root")" == "700" ]] || {
    print -u2 "refusing capability runtime ownership/mode mismatch"
    exit 1
  }
  terminate_bridge
  local entries=("$bridge_runtime_root"/*(DN))
  for entry in "${entries[@]}"; do
    [[ ("$entry" == "$bridge_socket" && -S "$entry" && ! -L "$entry") || \
       ("$entry" == "$bridge_pid_file" && -f "$entry" && ! -L "$entry") ]] || {
      print -u2 "refusing unrecognized capability runtime entry: $entry"
      exit 1
    }
  done
  if [[ -e "$bridge_socket" ]]; then
    [[ -S "$bridge_socket" && ! -L "$bridge_socket" && \
       "$(stat -f '%u' "$bridge_socket")" == "$EUID" && \
       "$(stat -f '%Lp' "$bridge_socket")" == "600" ]] || {
      print -u2 "refusing capability socket ownership/mode mismatch"
      exit 1
    }
  fi
  if [[ -S "$bridge_socket" && ! -L "$bridge_socket" ]]; then
    unlink "$bridge_socket"
  fi
  if [[ -f "$bridge_pid_file" && ! -L "$bridge_pid_file" ]]; then
    unlink "$bridge_pid_file"
  fi
  rmdir "$bridge_runtime_root"
}

clean_bridge_runtime

if [[ "$#" == 1 && "$1" == "--bridge-runtime" ]]; then
  exit 0
fi

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
  for _ in {1..3}; do
    find -P "$target" -depth -delete 2>/dev/null || true
    [[ ! -e "$target" ]] && return 0
    sleep 0.05
  done
  print -u2 "could not remove generated root: $target"
  return 1
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
    "$repo_root/.artifacts/overlay-build" \
    "$repo_root/.build/vendor/wakeword"
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
      "$repo_root/.artifacts/overlay-build" \
      "$repo_root/.build/vendor/wakeword"
  done
  if [[ -f "$repo_root/.artifacts/.DS_Store" ]]; then
    find -P "$repo_root/.artifacts" -maxdepth 1 -type f -name .DS_Store -delete
  fi
elif [[ "$#" == 1 && "$1" == "--dependencies" ]]; then
  for target in \
    "$repo_root/Gateway/node_modules" \
    "$repo_root/.cache/npm" \
    "$repo_root/.artifacts/overlay-build" \
    "$repo_root/.build/vendor/wakeword"
  do
    safe_remove_tree \
      "$target" \
      "$repo_root/Gateway/node_modules" \
      "$repo_root/.cache/npm" \
      "$repo_root/.artifacts/overlay-build" \
      "$repo_root/.build/vendor/wakeword"
  done
  rmdir "$repo_root/.build/vendor" 2>/dev/null || true
  rmdir "$repo_root/.cache" 2>/dev/null || true
  rmdir "$repo_root/.artifacts" 2>/dev/null || true
else
  print -u2 \
    "usage: $0 [--bridge-runtime|--build-caches|--dependencies|--preserve-release]"
  exit 64
fi
