#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${MILLER_CLEAN_ROOT:-}" ]]; then
  [[ "$MILLER_CLEAN_ROOT" == /private/tmp/miller-task18-clean-* ]] || {
    print -u2 "refusing unsafe clean test root"
    exit 1
  }
  repo_root="$MILLER_CLEAN_ROOT"
fi
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
bridge_metadata_file="$bridge_runtime_root/bridge.lease"

terminate_bridge() {
  [[ ! -e "$bridge_pid_file" && ! -e "$bridge_metadata_file" ]] && return 0
  [[ -f "$bridge_metadata_file" && ! -L "$bridge_metadata_file" ]] || {
    print -u2 "refusing unsafe capability bridge identity lease: $bridge_metadata_file"
    return 1
  }
  [[ "$(stat -f '%u' "$bridge_metadata_file")" == "$EUID" && \
     "$(stat -f '%Lp' "$bridge_metadata_file")" == "600" ]] || {
    print -u2 "refusing capability bridge identity lease ownership/mode mismatch"
    return 1
  }
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
  local lease_pid="$(sed -n 's/^pid=//p' "$bridge_metadata_file")"
  local lease_uid="$(sed -n 's/^uid=//p' "$bridge_metadata_file")"
  local lease_ppid="$(sed -n 's/^ppid=//p' "$bridge_metadata_file")"
  local lease_start="$(sed -n 's/^start=//p' "$bridge_metadata_file")"
  local lease_exec="$(sed -n 's/^exec=//p' "$bridge_metadata_file")"
  [[ "$lease_pid" == "$bridge_pid" && "$lease_uid" == "$EUID" && \
     "$lease_ppid" == <1-> && "$lease_ppid" -gt 0 && \
     -n "$lease_start" && "$lease_start" != *$'\n'* && \
     "$lease_exec" == /* && -x "$lease_exec" && ! -L "$lease_exec" ]] || {
    print -u2 "refusing incomplete or mismatched capability bridge identity lease"
    return 1
  }
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    return 0
  fi
  capture_bridge_identity "$bridge_pid" || {
    print -u2 "refusing PID lease for unexpected executable"
    return 1
  }
  local expected_bridge_uid="$bridge_uid"
  local expected_bridge_ppid="$bridge_ppid"
  local expected_bridge_start="$bridge_start"
  local expected_bridge_exec="$bridge_exec"
  local expected_bridge_executable_hash="$bridge_executable_hash"
  [[ "$expected_bridge_uid" == "$lease_uid" && \
     "$expected_bridge_ppid" == "$lease_ppid" && \
     "$expected_bridge_start" == "$lease_start" && \
     "$expected_bridge_exec" == "$lease_exec" ]] || {
    print -u2 "refusing PID lease with stale process identity"
    return 1
  }
  assert_bridge_identity \
    "$bridge_pid" \
    "$expected_bridge_uid" \
    "$expected_bridge_ppid" \
    "$expected_bridge_start" \
    "$expected_bridge_exec" \
    "$expected_bridge_executable_hash" || {
      print -u2 "refusing PID lease identity change or missing lease"
      return 1
    }
  kill -TERM "$bridge_pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    kill -0 "$bridge_pid" 2>/dev/null || return 0
    sleep 0.05
  done
  assert_bridge_identity \
    "$bridge_pid" \
    "$expected_bridge_uid" \
    "$expected_bridge_ppid" \
    "$expected_bridge_start" \
    "$expected_bridge_exec" \
    "$expected_bridge_executable_hash" || return 1
  kill -KILL "$bridge_pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$bridge_pid" 2>/dev/null || return 0
    sleep 0.05
  done
  print -u2 "capability bridge did not terminate: $bridge_pid"
  return 1
}

capture_bridge_identity() {
  local pid="$1"
  bridge_uid="$(ps -p "$pid" -o uid= | tr -d ' ')"
  bridge_ppid="$(ps -p "$pid" -o ppid= | tr -d ' ')"
  bridge_start="$(ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  bridge_exec="$(ps -p "$pid" -o command= | sed 's/^[[:space:]]*//' | awk '{print $1}')"
  [[ "$bridge_uid" == "$EUID" && "$bridge_ppid" == <1-> ]] || return 1
  [[ "${bridge_exec:t}" == "MillerCapabilityBridge" ]] || return 1
  [[ -x "$bridge_exec" && ! -L "$bridge_exec" ]] || return 1
  bridge_executable_hash="$(shasum -a 256 "$bridge_exec" | awk '{print $1}')"
  [[ "$bridge_executable_hash" =~ '^[0-9a-f]{64}$' ]] || return 1
}

assert_bridge_identity() {
  local pid="$1"
  local expected_uid="$2"
  local expected_ppid="$3"
  local expected_start="$4"
  local expected_exec="$5"
  local expected_executable_hash="$6"
  kill -0 "$pid" 2>/dev/null || return 1
  capture_bridge_identity "$pid" || return 1
  [[ "$bridge_uid" == "$expected_uid" && \
     "$bridge_ppid" == "$expected_ppid" && \
     "$bridge_start" == "$expected_start" && \
     "$bridge_exec" == "$expected_exec" && \
     "$bridge_executable_hash" == "$expected_executable_hash" ]] || return 1
  /usr/sbin/lsof -a -p "$pid" -Fn "$bridge_pid_file" 2>/dev/null \
    | grep -Fx "n$bridge_pid_file" >/dev/null && \
  /usr/sbin/lsof -a -p "$pid" -Fn "$bridge_metadata_file" 2>/dev/null \
    | grep -Fx "n$bridge_metadata_file" >/dev/null
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
       ("$entry" == "$bridge_pid_file" && -f "$entry" && ! -L "$entry") || \
       ("$entry" == "$bridge_metadata_file" && -f "$entry" && ! -L "$entry") ]] || {
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
  if [[ -f "$bridge_metadata_file" && ! -L "$bridge_metadata_file" ]]; then
    unlink "$bridge_metadata_file"
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

verify_preserved_release() {
  local artifacts_root="$repo_root/.artifacts"
  local release_root="$artifacts_root/release"
  local retained_release_entries=(
    "$release_root/Miller.app"
    "$release_root/inventory.json"
    "$release_root/package-measurement.env"
  )
  [[ -d "$artifacts_root" && ! -L "$artifacts_root" ]] || {
    print -u2 "unexpected retained artifacts root"
    return 1
  }
  [[ -d "$release_root" && ! -L "$release_root" ]] || {
    print -u2 "unexpected retained release root"
    return 1
  }

  # Finder residue outside the signed bundle is disposable; residue inside the
  # bundle is a package-integrity failure and is never silently removed.
  find -P "$artifacts_root" \
    -path "$release_root/Miller.app" -prune -o \
    -type f -name .DS_Store -delete
  [[ -z "$(find -P "$release_root" -type l -print -quit)" ]] || {
    print -u2 "unexpected retained symbolic link"
    return 1
  }
  [[ -z "$(find -P "$release_root/Miller.app" -type f -name .DS_Store -print -quit)" ]] || {
    print -u2 "unexpected retained .DS_Store inside release bundle"
    return 1
  }

  local entry expected=false
  for entry in "$artifacts_root"/*(DN); do
    [[ "$entry" == "$release_root" ]] || {
      print -u2 "unexpected retained artifact: $entry"
      return 1
    }
  done
  for entry in "$release_root"/*(DN); do
    expected=false
    for retained in "${retained_release_entries[@]}"; do
      [[ "$entry" == "$retained" ]] && expected=true
    done
    [[ "$expected" == true ]] || {
      print -u2 "unexpected retained release artifact: $entry"
      return 1
    }
  done
  [[ -d "$release_root/Miller.app" && ! -L "$release_root/Miller.app" ]] || return 1
  [[ -f "$release_root/inventory.json" && ! -L "$release_root/inventory.json" ]] || return 1
  [[ -f "$release_root/package-measurement.env" && \
     ! -L "$release_root/package-measurement.env" ]] || return 1
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
  verify_preserved_release
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
