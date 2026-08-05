# Miller v0.1 source-first headless qualification

Date: 2026-08-05

Machine: Apple Silicon, macOS 15

Headless result: `SOURCE_RELEASE_READY_HUMAN_LIVE_NOT_RUN`

Companion owner-visible result: `GATE_4B_EXTERNAL_RUNTIME_CLOSED`

Overall source-first status: `SOURCE_RELEASE_READY`

## Scope

This report covers deterministic source, release-mode packaging, dependency,
provenance, reliability, size, process-start, and cleanup checks. It does not
claim real provider traffic, Codex OAuth interaction, microphone permission,
spoken input, audible output, Developer ID signing, notarization, clean-machine
Gatekeeper behavior, beta approval, or publication. The completed live gate is
recorded independently in `gate-4b-external-codex-human-report.md`; the
headless marker deliberately does not infer it.

Miller Avatar is a separate follow-on product. The v0.1 package contains no
avatar renderer or VRM asset.

## Automated results

- Gateway: 57 tests passed, 0 failed.
- Swift: 360 tests passed, 0 failed, using nonparallel execution.
- Gateway provenance and reviewed dependency closure: passed.
- Release-mode Swift build: passed.
- Release bundle structural and ad-hoc signature verification: passed.
- Release bundle inventory: 2,235 files.
- Development harness strings, harness plist metadata, fake helper, Codex,
  Rust/Cargo, Cortana, third-party WebRTC binary, avatar renderer, and VRM
  package checks: passed with no prohibited payload found.
- Packaged SPDX 2.3 document contains exactly Miller, the Pi-derived overlay,
  OpenAI JavaScript, partial-json, and Node.js. Codex remains an external
  prerequisite and is not listed as distributed software.

## M1 measurements

The package occupies 127,740 KiB (`du -sk`), approximately 125 MiB. Its main
binary is 4,071,904 bytes; the pinned Node executable is 111,673,840 bytes; and
the closed Gateway dependency tree occupies 13,756 KiB.

With fresh task-private database and cache roots, the release process created
its SQLite database after 237 ms on the cold run and 127 ms on the warm run.
Sampled application RSS was 25,120 KiB cold and 25,504 KiB warm. The production
Gateway is lazy and no provider request was submitted, so its ordinary idle RSS
was 0 KiB. A separate synthetic active-turn measurement exercised the same
Node executable and repository fake-helper contract at 42,064 KiB RSS; it must
not be described as live-provider or full-app active RSS. These numbers are an
internal storage-initialization/process baseline, not a claim about visible UI
readiness, live typed reasoning, or GPT-Live latency.

## Storage and cleanup

After qualification, `.build/`, `.cache/`, `Gateway/node_modules/`, the
development application, and task-private measurement roots were absent. Only
the approximately 125 MiB source-release inspection artifact and its sanitized
inventory/report remain under `.artifacts/release/`. Available disk space was
approximately 19 GiB after cleanup.

No credential, OAuth value, provider payload, transcript, SDP, microphone
audio, private runtime log, or identifying private fixture was retained.

## Remaining gates

1. Review and checkpoint the intended source-release tree.
2. Publish the source-first repository when that review is clean.
3. Later, build with Developer ID credentials, notarize, and pass clean-account
   Gatekeeper, upgrade, removal, and beta qualification before publishing a
   public application binary.
