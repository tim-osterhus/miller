# Miller Configurable Global Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Miller's conflicting fixed shortcut with a persisted,
configurable preset whose default is Command-Shift-Space.

**Architecture:** Represent the three reviewed shortcuts as one value type,
persist its raw identifier through `UserDefaults`, register the selected value
through the existing Carbon service, and bind a native Settings picker to the
presentation model.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Carbon HIToolbox, UserDefaults,
Swift Testing.

---

### Task 1: Specify Presets and Persistence

**Files:**
- Create: `Sources/MillerApp/Activation/GlobalShortcutPreferences.swift`
- Modify: `Tests/MillerAppTests/SmokeTests.swift`

- [x] Add failing tests for the Command-Shift-Space default, all three display
      names and modifier mappings, invalid-value fallback, and isolated
      UserDefaults round-trip.
- [x] Run the focused tests and confirm failure because the shortcut and
      preference types do not exist.
- [x] Implement only the value type and preference wrapper required by those
      tests.
- [x] Re-run the focused tests to green.

### Task 2: Re-register from Settings

**Files:**
- Modify: `Sources/MillerApp/Activation/GlobalActivationService.swift`
- Modify: `Sources/MillerApp/AppCoordinator.swift`
- Modify: `Sources/MillerApp/Presentation/SettingsView.swift`
- Modify: `Tests/MillerAppTests/PresentationTests.swift`

- [x] Add failing presentation tests proving selection invokes registration,
      updates availability, and retains menu access on failure.
- [x] Change the activation service to register an explicit preset.
- [x] Add selected-shortcut state and a registration callback to the
      presentation model.
- [x] Load, save, and apply the preference in `AppCoordinator`.
- [x] Replace the fixed settings label with a native preset picker and dynamic
      readiness presentation.
- [x] Run focused Miller app tests.

### Task 3: Reconcile Contracts and Requalify

**Files:**
- Modify: `docs/qualification/text-alpha-host-check.md`
- Modify: `docs/superpowers/specs/2026-07-30-miller-h1-qualification-repair-design.md`
- Modify (workspace research only): `lab/assist/research/designs/miller-mvp-production-architecture.md`
- Modify (workspace research only): `lab/assist/research/plans/2026-07-29-miller-text-alpha-implementation-plan.md`

- [x] Replace fixed Command-Option-Space claims with the configurable contract
      and Command-Shift-Space default.
- [x] Return the shortcut-related H1 fields to `NOT_RUN` before retesting.
- [x] Run complete Swift, Node, package, provenance, shell, and diff checks.
- [x] Launch H1 and stop for physical Command-Shift-Space verification.
- [x] Record the supported result, terminate owned processes, and remove all
      generated roots and dependencies.
