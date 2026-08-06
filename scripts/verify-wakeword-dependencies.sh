#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_root="$repo_root/.build/vendor/wakeword"
locked="$vendor_root/locked"

if [[ "$#" == 1 && "$1" == "--if-present" && ! -e "$vendor_root" ]]; then
  exit 0
fi
[[ "$#" == 0 || ("$#" == 1 && "$1" == "--if-present") ]] || {
  print -u2 "usage: $0 [--if-present]"
  exit 64
}

[[ "$vendor_root" == "$repo_root/.build/vendor/wakeword" ]] || exit 1
[[ -d "$locked" && ! -L "$vendor_root" && ! -L "$locked" ]] || {
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
