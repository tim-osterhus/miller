# Gate 4B external runtime report

Date: 2026-08-05

## Decision

Miller v0.1 uses a separately installed official Codex CLI for GPT-Live. Miller
does not distribute, build, download, update, or remove Codex. The abandoned
source-build attempt is superseded and is not an architecture blocker.

## Deterministic result

Status: PASS

Required terminal marker:

```text
EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN
```

Recorded result:

```text
EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN
```

Sanitized evidence:

- 360 Swift tests passed.
- 57 Gateway tests passed.
- The clean build and ad-hoc development package completed.
- Strict bundle-signature verification passed.
- The package inventory contains no Codex, Cortana, Rust, Cargo, `codex-rs`,
  or third-party WebRTC payload.
- The external runtime dry run admitted an arm64 `codex` executable signed by
  OpenAI team `2DC432GLL2` and made no provider request.
- Text-only harness and synthetic cleanup checks passed.
- The obsolete source checkout and stale development-app descendants were
  removed; no task-local App Server, fake helper, or private live root remained.

## Human result

Status: PASS

Recorded result:

```text
GATE_4B_EXTERNAL_RUNTIME_CLOSED
```

The owner-visible gate passed external-runtime detection, microphone
permission, spoken input and audible output, local date/time context,
chronological nonduplicated transcripts, delayed follow-up, mute/unmute,
immediate interruption, a fresh second session, truthful failure behavior,
typed fallback, child-process reaping, and private-root cleanup. Sanitized
details are retained in `gate-4b-external-codex-human-report.md`.

No credential, account identifier, provider payload, SDP, transcript, audio,
private path, or private runtime log is retained in this report.

## Source-release continuation

The avatar-independent source-first package and headless M1 baseline are
recorded in `source-first-headless-report.md`. Its automated terminal marker
remains `SOURCE_RELEASE_READY_HUMAN_LIVE_NOT_RUN` because the headless script
does not perform or infer the separate human gate.
