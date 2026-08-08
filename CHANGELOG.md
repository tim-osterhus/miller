# Changelog

## 0.1.1

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
- Fixed stale capability-bridge lease recovery so consecutive typed
  conversations remain available after a short-lived bridge exits.
- Completed owner-visible Live Voice, mute/unmute, interruption, transcript,
  history, Markdown, browser-link, and typed-fallback qualification.

Known v0.1.1 limitation: transcript text can be copied through the native
context menu only within one rendered line. Command-C routing and selection
across line breaks are deferred to v0.1.2 together with wakeword integration.

Signing and notarization were not run. This is a source-first release; no
unsigned application bundle is published.
