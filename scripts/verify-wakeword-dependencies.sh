#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
canonical_vendor_root="$repo_root/.build/vendor/wakeword"
vendor_root="$canonical_vendor_root"
if [[ "${MILLER_WAKEWORD_VERIFY_TESTING:-0}" == "1" ]]; then
  vendor_root="${MILLER_WAKEWORD_VENDOR_ROOT:-}"
  [[ "$vendor_root" == "/private/tmp/miller-wakeword-test-${EUID}-"*/wakeword ]] || {
    print -u2 "refusing unsafe wakeword verification test override"
    exit 1
  }
  test_parent="${vendor_root:h}"
  [[ -d "$test_parent" && ! -L "$test_parent" && \
     "$(stat -f '%u' "$test_parent")" == "$EUID" && \
     "$(stat -f '%Lp' "$test_parent")" == "700" ]] || {
    print -u2 "refusing unsafe wakeword verification test parent"
    exit 1
  }
elif [[ -n "${MILLER_WAKEWORD_VENDOR_ROOT:-}" ]]; then
  print -u2 "wakeword vendor override is test-only"
  exit 1
fi
downloads="$vendor_root/downloads"
extracted="$vendor_root/extracted"
locked="$vendor_root/locked"
include_root="$locked/include"
lib_root="$locked/lib"
model_root="$locked/model"

reject_symlink_paths() {
  local candidate
  for candidate in "$@"; do
    [[ ! -L "$candidate" ]] || {
      print -u2 "refusing symbolic-link wakeword path: $candidate"
      return 1
    }
  done
}

reject_tree_symlinks() {
  local root="$1"
  reject_symlink_paths "$root" || return 1
  [[ ! -e "$root" ]] && return 0
  if find -P "$root" -type l -print -quit | grep -q .; then
    print -u2 "refusing symbolic link beneath wakeword path: $root"
    return 1
  fi
}

run_safety_self_test() {
  typeset -g wakeword_verify_self_test_root
  wakeword_verify_self_test_root="$(mktemp -d "/private/tmp/miller-wakeword-test-${EUID}-XXXXXX")"
  chmod 700 "$wakeword_verify_self_test_root"
  local test_root="$wakeword_verify_self_test_root"
  local mutation_target="$test_root/mutation-target"
  mkdir "$mutation_target"
  print -n "unchanged" > "$mutation_target/marker"

  cleanup_wakeword_verify_self_test() {
    [[ "$wakeword_verify_self_test_root" == "/private/tmp/miller-wakeword-test-${EUID}-"* && \
       -d "$wakeword_verify_self_test_root" && \
       ! -L "$wakeword_verify_self_test_root" ]] || return 1
    find -P "$wakeword_verify_self_test_root" -depth -delete
  }
  trap cleanup_wakeword_verify_self_test EXIT

  ln -s "$mutation_target" "$test_root/wakeword"
  if env \
      MILLER_WAKEWORD_VERIFY_TESTING=1 \
      MILLER_WAKEWORD_VENDOR_ROOT="$test_root/wakeword" \
      "$0" --if-present >/dev/null 2>&1; then
    print -u2 "verifier accepted a symbolic-link vendor root"
    exit 1
  fi
  [[ "$(<"$mutation_target/marker")" == "unchanged" ]] || {
    print -u2 "verifier mutated a vendor-root symlink target"
    exit 1
  }
  unlink "$test_root/wakeword"

  mkdir -p "$test_root/wakeword"
  ln -s "$mutation_target" "$test_root/wakeword/locked"
  if env \
      MILLER_WAKEWORD_VERIFY_TESTING=1 \
      MILLER_WAKEWORD_VENDOR_ROOT="$test_root/wakeword" \
      "$0" --if-present >/dev/null 2>&1; then
    print -u2 "verifier accepted a symbolic-link locked root"
    exit 1
  fi
  [[ "$(<"$mutation_target/marker")" == "unchanged" ]] || {
    print -u2 "verifier mutated a locked-root symlink target"
    exit 1
  }
  print "wakeword verifier symlink safety verified"
}

if [[ "$#" == 1 && "$1" == "--self-test-safety" ]]; then
  run_safety_self_test
  exit 0
fi
[[ "$#" == 0 || ("$#" == 1 && "$1" == "--if-present") ]] || {
  print -u2 "usage: $0 [--if-present|--self-test-safety]"
  exit 64
}

if [[ "$vendor_root" == "$canonical_vendor_root" ]]; then
  reject_symlink_paths \
    "$repo_root/.build" \
    "$repo_root/.build/vendor" || exit 1
fi
reject_symlink_paths \
  "$vendor_root" "$downloads" "$extracted" "$locked" \
  "$include_root" "$lib_root" "$model_root" || exit 1
reject_tree_symlinks "$vendor_root" || exit 1

if [[ "$#" == 1 && "$1" == "--if-present" && ! -e "$vendor_root" ]]; then
  exit 0
fi

[[ -d "$locked" ]] || {
  print -u2 "wakeword dependencies are absent or unsafe"
  exit 1
}

typeset -A expected_hashes=(
  lib/libsherpa-onnx.a cd6f73e84bb78d5041a085fb388f43d6c66107e6f12e97a39cda6c7ce534b8a6
  lib/libonnxruntime.a 9f3e92dd112cd39aa495aec55352f9daaac756c3879bc1b4b3586105c1e85e34
  model/encoder.onnx 1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678
  model/decoder.onnx f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3
  model/joiner.onnx eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c
  model/bpe.model c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24
  model/tokens.txt fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53
)

for relative expected in ${(kv)expected_hashes}; do
  file="$locked/$relative"
  [[ -f "$file" && ! -L "$file" ]] || {
    print -u2 "missing wakeword input: $relative"
    exit 1
  }
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    print -u2 "wakeword input hash mismatch: $relative"
    exit 1
  }
done

for header in \
  include/sherpa-onnx/c-api/c-api.h \
  include/sherpa-onnx/c-api/cxx-api.h
do
  [[ -f "$locked/$header" && ! -L "$locked/$header" ]] || {
    print -u2 "missing wakeword header: $header"
    exit 1
  }
done

if find -P "$locked" -type l | grep -q .; then
  print -u2 "wakeword inputs must not contain symbolic links"
  exit 1
fi
lipo -info "$locked/lib/libonnxruntime.a" | grep -q 'arm64' || {
  print -u2 "ONNX Runtime library is not arm64"
  exit 1
}
lipo -info "$locked/lib/libsherpa-onnx.a" | grep -q 'arm64' || {
  print -u2 "Sherpa library does not contain arm64"
  exit 1
}

print "wakeword dependencies verified"
