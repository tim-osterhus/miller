#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
route="${1:-all}"
case "$route" in
  typed|sideband|pi|all) ;;
  *) print -u2 "usage: $0 [typed|sideband|pi|all]"; exit 64 ;;
esac

release_app="${MILLER_TASK18_RELEASE_APP:-$repo_root/.artifacts/release/Miller.app}"
node_path="$release_app/Contents/Resources/Gateway/runtime/node"
bridge_path="$release_app/Contents/Helpers/MillerCapabilityBridge"
node_hash="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
expected_lock_hash="10c7313d32729acd59f2d88f8185be22b29df56ee95b321a8b8a6d2ab53736ba"

[[ -x "$node_path" && ! -L "$node_path" ]] || {
  print -u2 "task18_packaged_node_missing"
  exit 1
}
[[ -x "$bridge_path" && ! -L "$bridge_path" ]] || {
  print -u2 "task18_packaged_bridge_missing"
  exit 1
}
[[ "$("$node_path" --version)" == "v22.22.0" ]] || exit 1
[[ "$(shasum -a 256 "$node_path" | awk '{print $1}')" == "$node_hash" ]] || {
  print -u2 "task18_packaged_node_hash_mismatch"
  exit 1
}
[[ "$(shasum -a 256 "$repo_root/Package.resolved" | awk '{print $1}')" == "$expected_lock_hash" ]] || {
  print -u2 "task18_lock_hash_mismatch"
  exit 1
}
[[ -d "$repo_root/Gateway/node_modules" && ! -L "$repo_root/Gateway/node_modules" ]] || {
  print -u2 "task18_gateway_dependencies_missing"
  exit 1
}
"$repo_root/scripts/verify-provenance.sh" --development-bundle-inventory >/dev/null

broker_harness="$("$repo_root/scripts/build-task18-route-harness.sh")"
[[ -x "$broker_harness" && ! -L "$broker_harness" ]] || exit 1

# This bounded deterministic check uses fake Codex typed/App Server, fake Codex
# GPT-Live sideband, fake Pi/Gateway, the Swift Miller capability broker, the
# packaged MillerCapabilityBridge, and one local read-only MCP fixture. The
# child harness owns only its temporary fixture tree and receives no credentials.
# Fixtures: Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs,
# Tests/MillerLiveTests/Fixtures/task18-bridge-client.mjs, and the fake Pi provider.
MILLER_TASK18_ROUTE="$route" \
MILLER_TASK18_NODE_PATH="$node_path" \
MILLER_TASK18_BRIDGE_PATH="$bridge_path" \
MILLER_TASK18_BROKER_HARNESS="$broker_harness" \
  "$node_path" --test "$repo_root/Gateway/tests/task18-three-route-e2e.test.mjs"

print "MILLER_TASK18_THREE_ROUTE_E2E_PASS route=$route tool=miller_mcp/task18_fixture/lookup_note"
