# Miller Gate 4B external-Codex human qualification

Date: 2026-08-05

Machine: Apple Silicon M1 floor, 8 GiB memory, macOS 15.7.7

External runtime: official Codex CLI 0.146.0, arm64

Result: `GATE_4B_EXTERNAL_RUNTIME_CLOSED`

## Scope

This report records the sanitized owner-visible qualification required by
`gpt-live-app-server-check.md`. Miller used a separately installed official
Codex CLI and the existing Codex/ChatGPT OAuth profile. Miller did not bundle,
copy, update, or remove Codex.

No transcript text, audio, SDP, credential, account identifier, callback URL,
provider payload, or private runtime log is retained in this report.

## Owner-visible results

- Miller discovered and admitted the installed official Codex runtime. Live
  Voice was available without an OpenAI API key.
- Microphone permission and WebRTC media startup reached the truthful
  Listening state without duplicate capture or output.
- Spoken input and audible output worked. Local date and time context was
  correct after the compatibility repairs.
- User and Miller transcript turns remained chronological, role-separated,
  bounded, and nonduplicated across a delayed follow-up.
- Mute and unmute stopped and restored outbound microphone media without
  ending the session.
- Interrupt silenced output immediately and closed the active live session.
- A second session negotiated through a fresh peer after cleanup. Live Voice
  did not fabricate continuity from the closed live session.
- During qualification, unsupported model, provider, permission, timeout, and
  protocol incompatibilities produced bounded unavailable or failed states.
  Typed conversation remained available.
- Typed reasoning and visible conversation history remained Miller-owned and
  independent of the live-session lifecycle.
- The final close released the live session and external helper child. A
  subsequent process scan found no Miller or Miller-owned Codex process. The
  Miller GPT-Live cache parent was empty and contained no task-private child
  root.

## Sanitized responsiveness observations

Owner stopwatch observations measured perceived time to first substantive
audio, not transcript rendering or complete-turn duration:

- ordinary live responses began in under approximately one second;
- responses requiring current network information began within approximately
  seven seconds in the observed session; and
- interruption silenced output immediately at owner-visible precision.

An external accessibility sample measured approximately 2.31 seconds from the
first visible committed user transcript to the first visible assistant
transcript segment. That value represents presentation timing and is not used
as an audible-latency benchmark.

## Compatibility repairs accepted by the gate

The live run demonstrated two compatibility defects that were corrected and
covered by deterministic tests:

1. Spawn admission now derives the executable path from the admitted running
   Security.framework code object instead of relying on a fragile process-path
   lookup.
2. The App Server decoder accepts omitted default metadata and additive
   metadata while continuing to require and validate the isolation, sandbox,
   model-provider, thread-identity, and realtime fields Miller depends on.

The focused post-repair check admitted and spawned the installed OpenAI-signed
Codex 0.146.0 runtime, then stopped and reaped it without making a provider
request.

## Boundary

This closes the owner-visible Gate 4B external-runtime requirement. It does not
claim Developer ID signing, notarization, clean-account Gatekeeper behavior,
upgrade qualification, beta approval, or publication. Miller Avatar remains a
separate follow-on release and is not part of Miller v0.1.
