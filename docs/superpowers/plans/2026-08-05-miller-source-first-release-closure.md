# Miller Source-First Release Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the avatar-independent Miller v0.1 source, production package, compliance evidence, headless qualification, and operator protocol without signing, notarizing, publishing, or running the owner-visible microphone/audio gate.

**Architecture:** Keep the existing native Swift application, Miller-owned SQLite state, bundled pinned Node/Pi reasoning gateway, and externally installed official Codex App Server. Add a release-mode package that excludes qualification-only payloads and produces sanitized inventories; retain development packaging separately for deterministic fixtures.

**Tech Stack:** Swift 6.1/SwiftPM, AppKit/SwiftUI, system SQLite/WebKit, Node.js 22.22.0, zsh, SPDX 2.3, GitHub Actions macOS 15.

---

### Task 1: Freeze the avatar-independent public boundary

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/security.md`
- Modify: `docs/privacy.md`
- Modify: `docs/removal.md`
- Modify: `docs/qualification/gpt-live-app-server-check.md`
- Modify: `docs/superpowers/specs/2026-08-04-miller-gate-4b-public-runtime-closure-design.md`
- Modify: `PROVENANCE.md`
- Modify: `THIRD_PARTY_NOTICES.md`

- [x] Remove stale claims that Miller Avatar or a public VRM asset gates v0.1.
- [x] State that Miller v0.1 contains no avatar renderer or asset and runs independently.
- [x] Describe the external Codex prerequisite and complete typed fallback accurately.
- [x] Keep signing, notarization, live audio, clean-machine, and beta results explicitly unclaimed.

### Task 2: Add a production-shaped unsigned package

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/MillerApp/AppDelegate.swift`
- Modify: `scripts/package-dev-app.sh`
- Create: `scripts/package-release-app.sh`
- Create: `scripts/verify-release-package.sh`
- Create: `scripts/release-inventory.mjs`
- Modify: `scripts/verify-provenance.sh`
- Modify: `.github/workflows/ci.yml`

- [x] Write release-package assertions first and run them against the development bundle; expect rejection of the development harness marker and fake helper.
- [x] Exclude noninteractive harness modes from release compilation.
- [x] Assemble `.artifacts/release/Miller.app` with the release Swift binary, production gateway, reviewed dependencies, and pinned Node runtime.
- [x] Exclude fake helpers, harness metadata, Codex, Rust/Cargo, Cortana, WebRTC binaries, avatar runtimes, and VRM assets.
- [x] Ad-hoc sign only for structural verification and label the artifact unsigned/unnotarized.
- [x] Emit a sanitized file/hash/size inventory and verify bundle structure, provenance, and cleanup.

### Task 3: Close headless release documentation and compliance

**Files:**
- Create: `docs/installation.md`
- Create: `docs/troubleshooting.md`
- Create: `docs/provider-compatibility.md`
- Create: `docs/release-checklist.md`
- Create: `docs/qualification/source-first-headless-report.md`
- Modify: `README.md`
- Modify: `docs/development.md`
- Modify: `PROVENANCE.md`
- Modify: `THIRD_PARTY_NOTICES.md`

- [x] Document macOS 15/Apple Silicon, separate Codex ownership, first launch, provider setup, typed fallback, reset, and removal.
- [x] Record the exact items that remain owner-visible or require Developer ID credentials.
- [x] Verify the release SBOM, licenses, notices, native-binary inventory, and distributed-file inventory.

### Task 4: Run deterministic reliability and M1 measurements

**Files:**
- Create: `scripts/run-headless-release-qualification.sh`
- Create: `docs/qualification/source-first-headless-report.md`

- [x] Run all Swift and Gateway tests nonparallel.
- [x] Run provenance and release-package checks.
- [x] Measure release bundle size, text-only cold/warm storage initialization, and bounded generated roots.
- [x] Confirm no Codex/Rust/Cargo/avatar payload, live credential, microphone, audio, provider request, or notarization action occurred.
- [x] Clean compiler, package, dependency, and measurement artifacts after retaining only the release app and sanitized report.

### Task 5: Curate and checkpoint the source

**Files:**
- Modify: `.gitignore`
- Review: all intended source and documentation files

- [x] Inspect the complete source diff and exclude private/generated artifacts.
- [x] Run the full verification commands again from the final tree.
- [x] Commit the source-first Miller v0.1 foundation on `main` without publishing it.
- [x] Stop before the owner-visible GPT-Live gate, Developer ID signing, notarization, beta, or publication.
