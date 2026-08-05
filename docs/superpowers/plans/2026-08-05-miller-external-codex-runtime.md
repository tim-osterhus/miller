# Miller External Codex Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Use an owner-installed official Codex CLI as Miller v0.1's GPT-Live App Server without bundling or compiling Codex.

**Architecture:** A MillerApp-owned resolver maps saved or discovered launcher paths to a native arm64 Codex executable. A verifier admits only OpenAI-signed code and binds the spawned PID to the selected executable; existing MillerLive supervision and WebRTC behavior remain unchanged.

**Tech Stack:** Swift 6.1, AppKit/SwiftUI, Security.framework, Darwin process inspection, Swift Testing, zsh qualification scripts.

---

### Task 1: External runtime selection contract

**Files:**
- Create: `Sources/MillerApp/Voice/CodexRuntimeSelection.swift`
- Create: `Tests/MillerAppTests/CodexRuntimeSelectionTests.swift`

- [ ] Write failing tests for deterministic saved-path precedence, common
      candidate discovery, native paths, npm launcher translation, malformed
      launchers, and clearing preferences.
- [ ] Run `./scripts/test.sh --filter MillerAppTests` and confirm the new tests
      fail because the selection types do not exist.
- [ ] Implement the smallest resolver and preference store needed by the tests;
      use canonical filesystem paths and never launch a shell or Node.
- [ ] Re-run the focused tests and require a pass.

### Task 2: Official publisher and spawned-process verification

**Files:**
- Modify: `Sources/MillerApp/Security/CodexAppServerHelperVerifier.swift`
- Modify: `Tests/MillerAppTests/CodexAppServerHelperVerifierTests.swift`

- [ ] Replace Cortana-pin fixtures with OpenAI identifier/team/arm64 fixtures
      and add a failing spawned-path mismatch test.
- [ ] Run the focused tests and confirm the old exact Cortana pin fails them.
- [ ] Implement static Developer ID validation and PID validation bound to the
      selected canonical executable.
- [ ] Re-run focused tests and require a pass.

### Task 3: Production selection and settings

**Files:**
- Modify: `Sources/MillerApp/AppCoordinator.swift`
- Modify: `Sources/MillerApp/Presentation/SettingsView.swift`
- Modify: `Sources/MillerApp/Voice/GPTLiveController.swift`
- Modify: `Tests/MillerAppTests/GPTLiveDirectControllerTests.swift`

- [ ] Add failing tests proving production uses external discovery, an absent
      runtime yields unavailable voice, and direct `/v1/live` is not selected.
- [ ] Implement launch-time external selection, Settings Choose/Clear controls,
      restart-to-apply messaging, and exact PID verifier capture.
- [ ] Preserve the explicit command-line override for qualification only.
- [ ] Run MillerApp and MillerLive tests and require a pass.

### Task 4: Qualification, packaging, and documentation

**Files:**
- Modify: `scripts/run-gpt-live-app-server-check.sh`
- Modify: `scripts/package-dev-app.sh`
- Modify: `scripts/clean.sh`
- Modify: `README.md`, `PROVENANCE.md`, `THIRD_PARTY_NOTICES.md`
- Modify: `docs/architecture.md`, `docs/development.md`, `docs/privacy.md`,
  `docs/security.md`, `docs/removal.md`, and
  `docs/qualification/gpt-live-app-server-check.md`
- Create: `docs/qualification/gate-4b-external-runtime-report.md`

- [ ] Rewrite the qualification preflight around an external OpenAI-signed
      Codex path and add its deterministic refusal simulations.
- [ ] Preserve the packaging assertion that no Codex or Cortana payload enters
      `Miller.app`.
- [ ] Remove bundled/source-built runtime claims and document external
      installation ownership and online requirements.
- [ ] Run script help, dry-run/refusal, packaging inventory, and cleanup checks.

### Task 5: Full deterministic acceptance

**Files:**
- Modify only defects exposed by the required checks above.

- [ ] Run `git diff --check`, all Swift tests, all Gateway tests, and the clean
      build.
- [ ] Package and verify the development application and confirm a Codex-free
      inventory.
- [ ] Run text-only harness, process cleanup, and generated-root inspection.
- [ ] Record sanitized results and
      `EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN`; leave the human gate unrun.
