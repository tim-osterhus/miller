# Changelog

## 0.1.1 — deterministic qualification candidate

- Packaged the Miller capability bridge and production Node/Pi gateway.
- Set the application and application-SBOM version to 0.1.1.
- Limited the application SBOM and runtime inventory to the shipped MCP SDK,
  capability bridge, Node.js, Pi overlay, and existing JavaScript packages.
- Added deterministic coverage for the read-only MCP path through Codex typed,
  Codex Live sideband, and Pi, including all three approval policies,
  unsupported-model handling, transcript persistence/review, selectable text,
  and cleanup.
- Documented Live Voice audio behavior, text-only history, MCP trust, provider
  portability, audit policy, removal, storage cleanup, and the v0.1.2 wake-word
  deferral.

Signing and notarization were not run. Human microphone, audio, browser,
clipboard, account, and real-provider rows remain not run. This changelog does
not claim public binary publication.
