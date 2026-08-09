#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
canonical_vendor_root="$repo_root/.build/vendor/wakeword"
vendor_root="$canonical_vendor_root"
if [[ "${MILLER_WAKEWORD_BOOTSTRAP_TESTING:-0}" == "1" ]]; then
  vendor_root="${MILLER_WAKEWORD_VENDOR_ROOT:-}"
  [[ "$vendor_root" == "/private/tmp/miller-wakeword-test-${EUID}-"*/wakeword ]] || {
    print -u2 "refusing unsafe wakeword test vendor override"
    exit 1
  }
  test_parent="${vendor_root:h}"
  [[ -d "$test_parent" && ! -L "$test_parent" && \
     "$(stat -f '%u' "$test_parent")" == "$EUID" && \
     "$(stat -f '%Lp' "$test_parent")" == "700" ]] || {
    print -u2 "refusing unsafe wakeword test parent"
    exit 1
  }
elif [[ -n "${MILLER_WAKEWORD_VENDOR_ROOT:-}" ]]; then
  print -u2 "wakeword vendor override is test-only"
  exit 1
fi
downloads="$vendor_root/downloads"
extracted="$vendor_root/extracted"
locked="$vendor_root/locked"
staging="$vendor_root/locked-staging"

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

remove_regular_partial() {
  local partial="$1"
  [[ ! -e "$partial" && ! -L "$partial" ]] && return 0
  [[ -f "$partial" && ! -L "$partial" ]] || return 1
  unlink "$partial"
}

download_exact_archive() {
  local url="$1"
  local destination="$2"
  local expected_hash="$3"
  local expected_size="$4"
  local retries="${5:-3}"
  local parent="${destination:h}"
  local partial="$destination.partial"

  reject_symlink_paths "$parent" "$destination" "$partial" || return 1
  if [[ -f "$destination" && ! -L "$destination" ]] && \
     [[ "$(stat -f '%z' "$destination")" == "$expected_size" ]] && \
     [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_hash" ]]; then
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || {
      print -u2 "refusing unsafe archive path: $destination"
      return 1
    }
    unlink "$destination"
  fi
  if [[ -e "$partial" || -L "$partial" ]]; then
    remove_regular_partial "$partial" || {
      print -u2 "refusing unsafe partial archive path: $partial"
      return 1
    }
  fi

  if ! curl --fail --location --silent --show-error \
      --retry "$retries" \
      --max-filesize "$expected_size" \
      --output "$partial" \
      "$url"; then
    remove_regular_partial "$partial" || true
    return 1
  fi
  if [[ ! -f "$partial" || -L "$partial" ]]; then
    remove_regular_partial "$partial" || true
    print -u2 "download did not produce a regular partial archive"
    return 1
  fi
  if [[ "$(stat -f '%z' "$partial")" != "$expected_size" ]]; then
    remove_regular_partial "$partial"
    print -u2 "archive size mismatch: ${destination:t}"
    return 1
  fi
  if [[ "$(shasum -a 256 "$partial" | awk '{print $1}')" != "$expected_hash" ]]; then
    remove_regular_partial "$partial"
    print -u2 "archive hash mismatch: ${destination:t}"
    return 1
  fi
  if ! mv "$partial" "$destination"; then
    remove_regular_partial "$partial" || true
    return 1
  fi
}

run_safety_self_test() {
  typeset -g wakeword_bootstrap_self_test_root
  wakeword_bootstrap_self_test_root="$(mktemp -d "/private/tmp/miller-wakeword-test-${EUID}-XXXXXX")"
  chmod 700 "$wakeword_bootstrap_self_test_root"
  local test_root="$wakeword_bootstrap_self_test_root"
  local mutation_target="$test_root/mutation-target"
  mkdir "$mutation_target"
  print -n "unchanged" > "$mutation_target/marker"

  cleanup_wakeword_self_test() {
    [[ "$wakeword_bootstrap_self_test_root" == "/private/tmp/miller-wakeword-test-${EUID}-"* && \
       -d "$wakeword_bootstrap_self_test_root" && \
       ! -L "$wakeword_bootstrap_self_test_root" ]] || return 1
    find -P "$wakeword_bootstrap_self_test_root" -depth -delete
  }
  trap cleanup_wakeword_self_test EXIT

  ln -s "$mutation_target" "$test_root/wakeword"
  if env \
      MILLER_WAKEWORD_BOOTSTRAP_TESTING=1 \
      MILLER_WAKEWORD_VENDOR_ROOT="$test_root/wakeword" \
      "$0" >/dev/null 2>&1; then
    print -u2 "bootstrap accepted a symbolic-link internal root"
    exit 1
  fi
  [[ "$(<"$mutation_target/marker")" == "unchanged" ]] || {
    print -u2 "bootstrap mutated an internal-root symlink target"
    exit 1
  }
  unlink "$test_root/wakeword"

  mkdir -p "$test_root/wakeword/downloads"
  ln -s "$mutation_target" "$test_root/wakeword/extracted"
  if env \
      MILLER_WAKEWORD_BOOTSTRAP_TESTING=1 \
      MILLER_WAKEWORD_VENDOR_ROOT="$test_root/wakeword" \
      "$0" >/dev/null 2>&1; then
    print -u2 "bootstrap accepted a symbolic-link internal staging root"
    exit 1
  fi
  [[ "$(<"$mutation_target/marker")" == "unchanged" ]] || {
    print -u2 "bootstrap mutated an internal staging symlink target"
    exit 1
  }
  unlink "$test_root/wakeword/extracted"

  mkdir -p \
    "$test_root/wakeword/extracted" \
    "$test_root/wakeword/locked"
  ln -s "$mutation_target/marker" \
    "$test_root/wakeword/downloads/sherpa.tar.bz2.partial"
  if env \
      MILLER_WAKEWORD_BOOTSTRAP_TESTING=1 \
      MILLER_WAKEWORD_VENDOR_ROOT="$test_root/wakeword" \
      "$0" >/dev/null 2>&1; then
    print -u2 "bootstrap accepted a symbolic-link partial download"
    exit 1
  fi
  [[ "$(<"$mutation_target/marker")" == "unchanged" ]] || {
    print -u2 "bootstrap mutated a partial-download symlink target"
    exit 1
  }
  print "wakeword bootstrap symlink safety verified"
}

run_download_self_test() {
  typeset -g wakeword_download_self_test_root
  wakeword_download_self_test_root="$(mktemp -d "/private/tmp/miller-wakeword-test-${EUID}-XXXXXX")"
  chmod 700 "$wakeword_download_self_test_root"
  local test_root="$wakeword_download_self_test_root"

  cleanup_wakeword_download_self_test() {
    [[ "$wakeword_download_self_test_root" == "/private/tmp/miller-wakeword-test-${EUID}-"* && \
       -d "$wakeword_download_self_test_root" && \
       ! -L "$wakeword_download_self_test_root" ]] || return 1
    find -P "$wakeword_download_self_test_root" -depth -delete
  }
  trap cleanup_wakeword_download_self_test EXIT

  local source="$test_root/exact.archive"
  local destination="$test_root/downloaded.archive"
  print -n "exact-pinned-bytes" > "$source"
  local exact_size="$(stat -f '%z' "$source")"
  local exact_hash="$(shasum -a 256 "$source" | awk '{print $1}')"
  download_exact_archive \
    "file://$source" "$destination" "$exact_hash" "$exact_size" 0
  [[ -f "$destination" && ! -e "$destination.partial" ]] || {
    print -u2 "exact local archive was not admitted cleanly"
    exit 1
  }
  unlink "$destination"

  local oversized="$test_root/oversized.archive"
  print -n "one-byte-too-large" > "$oversized"
  local capped_size=$(($(stat -f '%z' "$oversized") - 1))
  if download_exact_archive \
      "file://$oversized" "$destination" "$exact_hash" "$capped_size" 0 \
      >/dev/null 2>&1; then
    print -u2 "oversized local archive bypassed the download cap"
    exit 1
  fi
  [[ ! -e "$destination" && ! -e "$destination.partial" ]] || {
    print -u2 "oversized download retained partial bytes"
    exit 1
  }

  if download_exact_archive \
      "file://$test_root/missing.archive" \
      "$destination" "$exact_hash" "$exact_size" 0 \
      >/dev/null 2>&1; then
    print -u2 "missing local archive unexpectedly downloaded"
    exit 1
  fi
  [[ ! -e "$destination" && ! -e "$destination.partial" ]] || {
    print -u2 "failed download retained partial bytes"
    exit 1
  }
  print "wakeword exact-size download safety verified"
}

if [[ "$#" == 1 && "$1" == "--self-test-safety" ]]; then
  run_safety_self_test
  exit 0
fi
if [[ "$#" == 1 && "$1" == "--self-test-download-safety" ]]; then
  run_download_self_test
  exit 0
fi
[[ "$#" == 0 ]] || {
  print -u2 "usage: $0 [--self-test-safety|--self-test-download-safety]"
  exit 64
}

sherpa_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-macos-xcframework-static.tar.bz2"
model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2"
onnx_url="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.24.4/onnxruntime-osx-arm64-static_lib-1.24.4.zip"

typeset -A archive_hashes=(
  sherpa.tar.bz2 8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e
  model.tar.bz2 f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
  onnx.zip 4752fa848d9d36143e3942537ff71736d2e581ce192a528482f7edd8d02c9ebf
)
typeset -A archive_sizes=(
  sherpa.tar.bz2 8941262
  model.tar.bz2 17626723
  onnx.zip 17358514
)
archive_total_bytes=$((8941262 + 17626723 + 17358514))
minimum_free_kib=$((6 * 1024 * 1024))
forecast_peak_generated_bytes=$((1024 * 1024 * 1024))

measure_bytes() {
  local root="$1"
  du -sk "$root" | awk '{ print $1 * 1024 }'
}

assert_free_floor() {
  local label="$1"
  local free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
  printf 'MILLER_WAKEWORD_FREE_KIB label=%s value=%s\n' "$label" "$free_kib"
  (( free_kib >= minimum_free_kib )) || {
    print -u2 "wakeword bootstrap would reduce free space below 6 GiB"
    exit 75
  }
}

if [[ "$vendor_root" == "$canonical_vendor_root" ]]; then
  reject_symlink_paths \
    "$repo_root/.build" \
    "$repo_root/.build/vendor" || exit 1
fi
reject_symlink_paths \
  "$vendor_root" "$downloads" "$extracted" "$locked" "$staging" || exit 1
reject_tree_symlinks "$downloads" || exit 1
reject_tree_symlinks "$extracted" || exit 1
reject_tree_symlinks "$locked" || exit 1
reject_tree_symlinks "$staging" || exit 1

# The three compressed archives total less than 45 MiB. Extraction, staging,
# and Swift compilation remain under a conservative 1 GiB peak allowance.
printf 'MILLER_WAKEWORD_FORECAST_ARCHIVE_BYTES=%s\n' "$archive_total_bytes"
printf 'MILLER_WAKEWORD_FORECAST_PEAK_GENERATED_BYTES=%s\n' \
  "$forecast_peak_generated_bytes"
available_kib=$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')
required_kib=$((1024 * 1024))
if (( available_kib < required_kib )); then
  print -u2 "wakeword bootstrap requires at least 1 GiB free"
  exit 1
fi
assert_free_floor "pre-bootstrap"

mkdir -p "$downloads" "$extracted" "$locked"
chmod 700 "$vendor_root" "$downloads" "$extracted" "$locked"

fetch() {
  local url="$1"
  local destination="$2"
  local expected="$3"
  local expected_size="$4"
  download_exact_archive \
    "$url" "$destination" "$expected" "$expected_size" || exit 1
}

fetch \
  "$sherpa_url" "$downloads/sherpa.tar.bz2" \
  "$archive_hashes[sherpa.tar.bz2]" "$archive_sizes[sherpa.tar.bz2]"
fetch \
  "$model_url" "$downloads/model.tar.bz2" \
  "$archive_hashes[model.tar.bz2]" "$archive_sizes[model.tar.bz2]"
fetch \
  "$onnx_url" "$downloads/onnx.zip" \
  "$archive_hashes[onnx.zip]" "$archive_sizes[onnx.zip]"

downloaded_archive_bytes=0
for archive in "$downloads/sherpa.tar.bz2" "$downloads/model.tar.bz2" "$downloads/onnx.zip"; do
  downloaded_archive_bytes=$((downloaded_archive_bytes + $(stat -f '%z' "$archive")))
done
printf 'MILLER_WAKEWORD_MEASURED_ARCHIVE_BYTES=%s\n' "$downloaded_archive_bytes"
assert_free_floor "after-download"

safe_tar_extract() {
  local archive="$1"
  local destination="$2"
  tar -tf "$archive" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
    END { exit bad }
  ' || {
    print -u2 "unsafe tar archive: ${archive:t}"
    exit 1
  }
  tar -tvf "$archive" | awk '
    substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { bad = 1 }
    END { exit bad }
  ' || {
    print -u2 "tar archive contains links: ${archive:t}"
    exit 1
  }
  reject_symlink_paths "$extracted" "$destination" || exit 1
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination"
  reject_tree_symlinks "$destination" || exit 1
}

safe_zip_extract() {
  local archive="$1"
  local destination="$2"
  unzip -Z1 "$archive" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
    END { exit bad }
  ' || {
    print -u2 "unsafe zip archive: ${archive:t}"
    exit 1
  }
  zipinfo -l "$archive" | awk '
    substr($1, 1, 1) == "l" { bad = 1 }
    END { exit bad }
  ' || {
    print -u2 "zip archive contains symbolic links: ${archive:t}"
    exit 1
  }
  reject_symlink_paths "$extracted" "$destination" || exit 1
  mkdir -p "$destination"
  unzip -q "$archive" -d "$destination"
  reject_tree_symlinks "$destination" || exit 1
}

reject_tree_symlinks "$extracted" || exit 1
find -P "$extracted" -depth -delete 2>/dev/null || true
mkdir -p "$extracted"
safe_tar_extract "$downloads/sherpa.tar.bz2" "$extracted/sherpa"
safe_tar_extract "$downloads/model.tar.bz2" "$extracted/model"
safe_zip_extract "$downloads/onnx.zip" "$extracted/onnx"
extracted_bytes="$(measure_bytes "$extracted")"
printf 'MILLER_WAKEWORD_MEASURED_EXTRACTED_BYTES=%s\n' "$extracted_bytes"
assert_free_floor "after-extraction"

one_file() {
  local root="$1"
  local name="$2"
  local matches=("$root"/**/"$name"(N.))
  (( ${#matches} == 1 )) || {
    print -u2 "expected exactly one $name in ${root:t}"
    exit 1
  }
  print -r -- "$matches[1]"
}

sherpa_lib="$(one_file "$extracted/sherpa" libsherpa-onnx.a)"
onnx_lib="$(one_file "$extracted/onnx" libonnxruntime.a)"
c_api_header="$(one_file "$extracted/sherpa" c-api.h)"
cxx_api_header="$(one_file "$extracted/sherpa" cxx-api.h)"
encoder="$(one_file "$extracted/model" encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx)"
decoder="$(one_file "$extracted/model" decoder-epoch-12-avg-2-chunk-16-left-64.onnx)"
joiner="$(one_file "$extracted/model" joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx)"
bpe="$(one_file "$extracted/model" bpe.model)"
tokens="$(one_file "$extracted/model" tokens.txt)"

reject_tree_symlinks "$staging" || exit 1
find -P "$staging" -depth -delete 2>/dev/null || true
mkdir -p \
  "$staging/include/sherpa-onnx/c-api" \
  "$staging/lib" \
  "$staging/model"
cp "$c_api_header" "$staging/include/sherpa-onnx/c-api/c-api.h"
cp "$cxx_api_header" "$staging/include/sherpa-onnx/c-api/cxx-api.h"
cp "$sherpa_lib" "$staging/lib/libsherpa-onnx.a"
cp "$onnx_lib" "$staging/lib/libonnxruntime.a"
cp "$encoder" "$staging/model/encoder.onnx"
cp "$decoder" "$staging/model/decoder.onnx"
cp "$joiner" "$staging/model/joiner.onnx"
cp "$bpe" "$staging/model/bpe.model"
cp "$tokens" "$staging/model/tokens.txt"

staged_bytes="$(measure_bytes "$staging")"
peak_generated_bytes="$extracted_bytes"
(( staged_bytes > peak_generated_bytes )) && peak_generated_bytes="$staged_bytes"
printf 'MILLER_WAKEWORD_MEASURED_PEAK_GENERATED_BYTES=%s\n' "$peak_generated_bytes"
assert_free_floor "after-staging"

reject_tree_symlinks "$locked" || exit 1
find -P "$locked" -depth -delete 2>/dev/null || true
mv "$staging" "$locked"
chmod -R u=rwX,go=rX "$locked"
retained_bytes="$(measure_bytes "$locked")"
printf 'MILLER_WAKEWORD_MEASURED_RETAINED_INPUT_BYTES=%s\n' "$retained_bytes"
assert_free_floor "after-retain"

# Archives and full extraction trees are transient qualification inputs. Only
# the explicitly staged arm64 build inputs survive a successful bootstrap.
reject_tree_symlinks "$downloads" || exit 1
reject_tree_symlinks "$extracted" || exit 1
find -P "$downloads" -depth -delete
find -P "$extracted" -depth -delete

printf 'MILLER_WAKEWORD_MEASURED_RETAINED_INPUT_BYTES_FINAL=%s\n' \
  "$(measure_bytes "$locked")"
assert_free_floor "post-bootstrap"

"$repo_root/scripts/verify-wakeword-dependencies.sh"
print "wakeword dependencies staged and verified"
