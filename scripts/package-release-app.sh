#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

"$repo_root/scripts/package-dev-app.sh" --release
"$repo_root/scripts/verify-release-package.sh"
"/opt/homebrew/opt/node@22/bin/node" \
  "$repo_root/scripts/release-inventory.mjs" \
  "$repo_root/.artifacts/release/Miller.app" \
  "$repo_root/.artifacts/release/inventory.json"

printf 'MILLER_SOURCE_RELEASE_READY_LIVE_NOT_RUN=%s\n' \
  "$repo_root/.artifacts/release/Miller.app"
