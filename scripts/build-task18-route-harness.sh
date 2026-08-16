#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
expected_resolved_hash="10c7313d32729acd59f2d88f8185be22b29df56ee95b321a8b8a6d2ab53736ba"
scratch_root="$repo_root/.build/task18-route-harness"

[[ ! -L "$repo_root/.build" ]] || exit 77
[[ ! -L "$scratch_root" ]] || exit 77

resolved_hash="$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')"
[[ "$resolved_hash" == "$expected_resolved_hash" ]] || {
  print -u2 "task18_lock_hash_mismatch"
  exit 78
}
for wake_root in \
  "$repo_root/.build/vendor/wakeword" \
  "$repo_root/Gateway/vendor/wakeword" \
  "$repo_root/.cache/wakeword"; do
  [[ ! -e "$wake_root" && ! -L "$wake_root" ]] || {
    print -u2 "task18_wake_input_present"
    exit 79
  }
done

free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"
expected_peak_kib=3145728
print -u2 "MILLER_STORAGE_CHECK label=task18-route-harness free_kib=$free_kib expected_peak_kib=$expected_peak_kib"
(( free_kib >= expected_peak_kib )) || exit 75

swift build \
  --package-path "$repo_root" \
  --scratch-path "$scratch_root" \
  -c release \
  --product MillerTask18RouteHarness >&2

bin_path="$(swift build \
  --package-path "$repo_root" \
  --scratch-path "$scratch_root" \
  -c release \
  --product MillerTask18RouteHarness \
  --show-bin-path 2>/dev/null)"
case "$bin_path" in
  "$scratch_root"/*) ;;
  *) exit 80 ;;
esac
harness="$bin_path/MillerTask18RouteHarness"
[[ -f "$harness" && -x "$harness" && ! -L "$harness" ]] || exit 80
print "$harness"
