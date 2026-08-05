# Miller Gate 4B External Codex Runtime Closure Design

**Status:** Approved; supersedes the bundled/source-built runtime design

**Date:** 2026-08-04

## Purpose

Close Miller Gate 4B by using a separately installed official Codex CLI as
the v0.1 GPT-Live App Server runtime. Miller does not bundle, download, build,
update, or remove Codex. The earlier Cortana-backed live qualification remains
historical compatibility evidence only.

GPT-Live and hosted reasoning require network access. This design makes no
offline-voice or offline-reasoning claim. "External" describes runtime
ownership and distribution, not an offline capability.

## Decision

Miller v0.1 launches an owner-installed, OpenAI-signed Apple-silicon `codex`
executable with `app-server --listen stdio:// --strict-config`. The runtime is
resolved at application startup in this order:

1. the explicit `--gpt-live-app-server PATH` development override;
2. an owner-selected path stored in Miller preferences; and
3. bounded automatic discovery in documented npm/Homebrew/user-local
   installation locations and the inherited process `PATH`.

An npm launcher may be selected or discovered, but Miller resolves it to the
platform package's native Mach-O executable before admission. Miller never
launches a shell, sources a shell profile, or invokes the JavaScript launcher.

Settings show the resolved runtime or a truthful unavailable state. Choosing
or clearing a runtime is validated before it is saved and takes effect after
relaunch. Missing or incompatible Codex disables GPT-Live without affecting
typed Codex OAuth or OpenAI-compatible reasoning.

## Runtime Trust Boundary

Before credentials or protocol bytes enter the child, Miller requires:

- an absolute, canonical, regular executable path;
- a thin Apple-silicon Mach-O executable;
- a valid Developer ID signature for identifier `codex` and OpenAI team
  identifier `2DC432GLL2`;
- the same admitted executable path and signing requirement for the spawned
  PID; and
- a successful App Server initialization and required WebRTC v3 capability
  handshake.

Miller intentionally does not pin a CDHash or exact Codex version because the
external installation has its own update lifecycle. An update is admitted only
if the publisher, architecture, executable identity, and runtime capability
checks still pass. Protocol incompatibility fails closed as GPT-Live
unavailable; it never falls back to the rejected direct `/v1/live` route.

## Ownership and Data Flow

Miller continues to own conversations, typed history, selected provider,
readiness, cancellation, visible live state, and cleanup. SQLite excludes live
audio and transcripts. Keychain owns the Codex OAuth credential.

The selected Codex runtime remains a supervised child process with the
existing task-private `HOME`, `CODEX_HOME`, and `TMPDIR`. WebKit owns
microphone capture and remote audio. End, interrupt, failure, reset, credential
invalidation, and application exit terminate and reap the process group and
remove the private root.

Miller preferences may retain only the selected executable path. Miller does
not copy or modify the external installation and complete Miller removal does
not remove Codex.

## Distribution and Storage

The Miller application contains no Codex binary, Rust toolchain, Cargo cache,
`codex-rs` checkout, npm Codex package, or Cortana payload. Packaging verifies
that no such files enter the application. Qualification uses the existing
external runtime in place and retains only sanitized path-independent
identity, version, capability, and pass/fail evidence.

Task-local build, test, and qualification roots remain bounded and are removed
after every run. No Gate 4B step may clone or compile Codex.

## Failure Behavior

Missing installation, invalid saved path, unrecognized launcher layout,
signature failure, wrong architecture, spawn/PID mismatch, unsupported
protocol, credential rejection, microphone denial, session failure, and
cleanup failure map to bounded Miller readiness or live-session outcomes.

No failure may expose raw helper diagnostics, persist live content, disable
typed reasoning, retain a helper process, or silently select a different
runtime after startup.

## Verification

Deterministic verification covers automatic discovery, saved selection,
launcher-to-native resolution, invalid paths, symlinks escaping the expected
npm package shape, wrong publisher, wrong architecture, static/running-process
identity, missing runtime, protocol failure, typed independence, cancellation,
cleanup, and a Codex-free packaged application.

The remaining owner-visible gate launches Miller normally with an installed
official Codex runtime and confirms microphone permission, Listening, audible
response, chronological nonduplicated transcripts, a follow-up after thirty
seconds, mute/unmute, immediate interrupt, a second fresh session, truthful
failure, typed fallback, and complete cleanup.

The deterministic milestone is:

`EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN`

After the owner-visible gate passes, Gate 4B may record:

`GATE_4B_EXTERNAL_RUNTIME_CLOSED`

## Non-Goals

- No bundled Codex runtime, Rust build, runtime downloader, installer, updater,
  or optional-component manager.
- No Cortana or VoiceInk binary/source reuse.
- No direct `/v1/live` fallback.
- No local STT/TTS implementation, Miller Avatar implementation, Developer ID
  release signing, notarization, or publication. Miller Avatar ships
  separately and does not gate Miller v0.1.
- No promise that GPT-Live works without network access.
