#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_root="$repo_root/.build/vendor/wakeword"
downloads="$vendor_root/downloads"
extracted="$vendor_root/extracted"
locked="$vendor_root/locked"

sherpa_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-macos-xcframework-static.tar.bz2"
model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2"
onnx_url="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.24.4/onnxruntime-osx-arm64-static_lib-1.24.4.zip"

typeset -A archive_hashes=(
  sherpa.tar.bz2 8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e
  model.tar.bz2 f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
  onnx.zip 4752fa848d9d36143e3942537ff71736d2e581ce192a528482f7edd8d02c9ebf
)

[[ "$vendor_root" == "$repo_root/.build/vendor/wakeword" ]] || exit 1
[[ ! -L "$repo_root/.build" && ! -L "$repo_root/.build/vendor" && \
   ! -L "$vendor_root" ]] || {
  print -u2 "refusing symbolic-link wakeword vendor root"
  exit 1
}

# The three compressed archives total less than 45 MiB. Extraction, staging,
# and Swift compilation remain under a conservative 1 GiB peak allowance.
available_kib=$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')
required_kib=$((1024 * 1024))
if (( available_kib < required_kib )); then
  print -u2 "wakeword bootstrap requires at least 1 GiB free"
  exit 1
fi

mkdir -p "$downloads" "$extracted" "$locked"
chmod 700 "$vendor_root" "$downloads" "$extracted" "$locked"

fetch() {
  local url="$1"
  local destination="$2"
  local expected="$3"
  if [[ -f "$destination" ]] && \
     [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected" ]]; then
    return
  fi
  [[ ! -e "$destination" || (-f "$destination" && ! -L "$destination") ]] || {
    print -u2 "refusing unsafe archive path: $destination"
    exit 1
  }
  curl -fL --retry 3 --output "$destination.partial" "$url"
  local actual="$(shasum -a 256 "$destination.partial" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    unlink "$destination.partial"
    print -u2 "archive hash mismatch: ${destination:t}"
    exit 1
  }
  mv "$destination.partial" "$destination"
}

fetch "$sherpa_url" "$downloads/sherpa.tar.bz2" "$archive_hashes[sherpa.tar.bz2]"
fetch "$model_url" "$downloads/model.tar.bz2" "$archive_hashes[model.tar.bz2]"
fetch "$onnx_url" "$downloads/onnx.zip" "$archive_hashes[onnx.zip]"

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
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination"
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
  mkdir -p "$destination"
  unzip -q "$archive" -d "$destination"
}

find -P "$extracted" -depth -delete 2>/dev/null || true
mkdir -p "$extracted"
safe_tar_extract "$downloads/sherpa.tar.bz2" "$extracted/sherpa"
safe_tar_extract "$downloads/model.tar.bz2" "$extracted/model"
safe_zip_extract "$downloads/onnx.zip" "$extracted/onnx"

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

staging="$vendor_root/locked-staging"
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

find -P "$locked" -depth -delete 2>/dev/null || true
mv "$staging" "$locked"
chmod -R u=rwX,go=rX "$locked"

# Archives and full extraction trees are transient qualification inputs. Only
# the explicitly staged arm64 build inputs survive a successful bootstrap.
find -P "$downloads" -depth -delete
find -P "$extracted" -depth -delete

"$repo_root/scripts/verify-wakeword-dependencies.sh"
print "wakeword dependencies staged and verified"
