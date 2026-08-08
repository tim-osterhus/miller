#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
route="${1:-all}"
case "$route" in
  typed|sideband|pi|all) ;;
  *)
    print -u2 "usage: $0 [typed|sideband|pi|all]"
    exit 64
    ;;
esac

# This bounded deterministic check uses the fake Codex App Server, a fake Pi provider,
# and the local MCP fixture. One read-only tool is exercised by Codex typed, Codex Live
# sideband, and Pi/Gateway; no real provider or owner data is involved.
# Fixtures: Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs,
# Tests/MillerCapabilitiesTests/Fixtures/read-only-mcp-server.mjs, and the fake Pi provider.
node_path="${MILLER_NODE_PATH:-/opt/homebrew/opt/node@22/bin/node}"
[[ -x "$node_path" ]] || {
  print -u2 "Node 22 is required for the deterministic Task 18 E2E"
  exit 1
}

# The E2E creates only bounded temporary fixture state and does not bootstrap dependencies.
MILLER_TASK18_ROUTE="$route" \
  "$node_path" --test "$repo_root/Gateway/tests/task18-three-route-e2e.test.mjs"

print "MILLER_TASK18_THREE_ROUTE_E2E_PASS route=$route tool=miller_mcp/task18/read_only_lookup"
