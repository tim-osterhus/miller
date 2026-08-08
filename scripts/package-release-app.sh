#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

package_start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
"$repo_root/scripts/package-dev-app.sh" --release
package_end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000')"
printf 'schema=miller-v0.1.1-package-measurement-v1\nclean_build_duration_ms=%s\n' \
  "$((package_end_ms - package_start_ms))" \
  > "$repo_root/.artifacts/release/package-measurement.env"
"/opt/homebrew/opt/node@22/bin/node" \
  "$repo_root/scripts/release-inventory.mjs" \
  "$repo_root/.artifacts/release/Miller.app" \
  "$repo_root/.artifacts/release/inventory.json"
"$repo_root/scripts/verify-release-package.sh"

printf 'MILLER_V0_1_1_UNSIGNED_RELEASE_APP_READY=1\n'
