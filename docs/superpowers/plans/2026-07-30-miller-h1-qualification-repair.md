# Miller H1 Qualification Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Miller's development-only H1 runner expose a deterministic,
cancellable streamed turn without changing normal fake-helper or production
gateway behavior.

**Architecture:** Add a timer-backed `qualification` mode to the existing fake
helper, pass that mode through an explicit development environment hook, and
select it only in the H1 runner. Keep the production protocol and ordinary
helper mode unchanged.

**Tech Stack:** Node.js 22, Swift 6/AppKit, zsh, Swift Testing, Node test runner.

---

### Task 1: Prove the Missing Qualification Behavior

**Files:**
- Modify: `Gateway/tests/protocol.test.mjs`
- Modify: `Tests/MillerAppTests/SmokeTests.swift`
- Modify: `scripts/run-host-check.sh`

- [ ] Add a Node test that starts the fake helper in `qualification` mode,
      observes `accepted` plus ordinal-zero partial text, sends cancel, observes
      `stopped`, waits beyond the completion deadline, and asserts that neither
      completion nor a late delta appeared.
- [ ] Add a second Node test that leaves a qualification turn alone and asserts
      bounded ordered completion.
- [ ] Add a Swift test for construction of helper arguments from
      `MILLER_FAKE_HELPER_MODE`.
- [ ] Tighten runner validation to require
      `MILLER_FAKE_HELPER_MODE=qualification`.
- [ ] Run the focused tests and confirm they fail only because qualification
      mode and argument construction do not exist.

### Task 2: Implement the Minimal Qualification Mode

**Files:**
- Modify: `Gateway/src/fake-helper.mjs`
- Modify: `Sources/MillerApp/AppCoordinator.swift`
- Modify: `scripts/run-host-check.sh`

- [ ] Add bounded timer ownership to the active fake-helper request.
- [ ] In qualification mode, emit one immediate partial, one delayed delta,
      and a delayed completion.
- [ ] On cancel, clear every timer, emit exactly one stopped terminal, and
      clear active state.
- [ ] Extract helper-argument construction in `AppCoordinator`; append only a
      nonempty `MILLER_FAKE_HELPER_MODE` value.
- [ ] Set `MILLER_FAKE_HELPER_MODE=qualification` in each H1 launch.
- [ ] Re-run the focused tests until they pass.

### Task 3: Correct and Verify Qualification State

**Files:**
- Modify: `docs/qualification/text-alpha-host-check.md`

- [ ] Return keyboard reachability and fake-helper Stop to `NOT_RUN` before the
      repaired manual run; remove unsupported failure codes.
- [ ] Run all Swift and Node tests, H1 validation, packaging, provenance
      verification, and shell syntax checks.
- [ ] Launch H1 and complete every automatable UI check.
- [ ] Stop at the physical-keyboard, VoiceOver, menu-bar, and Keychain actions
      with exact operator instructions.
- [ ] After the human checkpoint, record only supported result vocabulary,
      stop owned processes, and remove all generated roots and dependencies.
