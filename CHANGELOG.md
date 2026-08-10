# Changelog

## 0.1.2

- Fixed truthful external Codex readiness and timeout presentation, including
  typed fallback after a timed-out optional probe.
- Fixed native transcript Command-C and selection across rendered line breaks
  and Markdown blocks without adding a transcript-specific pasteboard path.
- Integrated optional Wake Listening with the default **Hey Miller** phrase and
  one bounded custom English phrase. Wake is off by default and its human
  microphone/custom-phrase gate remains `LIVE_NOT_RUN`.
- Recorded the bounded Live-text compatibility spike as `INCONCLUSIVE`; typed
  input during an active Live session, `initialItems`, and attachments remain
  outside this release.
- Updated the source package, inventory, SPDX SBOM, notices, provenance, and
  qualification schemas to v0.1.2.

Release closure result: `HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN`. The
owner-visible M1 gate, signing, notarization, tagging, publication, and push
were not run.

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
