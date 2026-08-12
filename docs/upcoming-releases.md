# Upcoming Miller releases

This document records the public feature order after the v0.1.2 source-release
closure. The owner-visible M1 gate remains `LIVE_NOT_RUN`, so publication still
requires separate owner approval.

## v0.1.2: daily-use repairs and stable seams — closure candidate

The closure candidate makes the current application easier to use while
preserving the desktop-only authority boundary. Its deterministic checks are
headless-ready; they do not prove the owner-visible microphone, audio, or M1
gate.

### Transcript interaction

- Route Command-C to the active typed or Live transcript selection.
- Allow pointer selection across rendered line breaks and message blocks.
- Preserve Markdown, links, code blocks, streaming, and follow-tail behavior.

These repairs remain narrow AppKit and presentation work. The owner-visible
selection and Command-C observation is listed in the unreached M1 gate.

### Custom wake phrases

- Integrate the completed source-only wakeword foundation into the application.
- Keep the feature optional and owner-controlled.
- Support one custom phrase, the system-default microphone, clear readiness,
  and deterministic disable and cleanup behavior.
- Treat the phrase only as a trigger: release wake capture, start one ordinary
  Live session, and ask Miller to acknowledge that it is ready before the owner
  speaks the request.
- The deterministic integration is complete; the microphone, default/custom
  phrase, and audible acknowledgement qualification remains `LIVE_NOT_RUN`.

### Live text feasibility

Before changing the product UI, run a bounded compatibility spike against the
supported external Codex App Server:

- Verify the exact `thread/realtime/appendText` request and response shape.
- Verify whether `initialItems` can seed a new Live session.
- Verify transcript event ordering, provider echoes, cancellation, and error
  behavior.
- Measure whether text injection leaves the WebRTC connection and first-audio
  latency unchanged.

This spike ended `INCONCLUSIVE`. It does not enable typed input during Live in
v0.1.2. A future confirmed result would inform a separate v0.1.3
implementation packet.

### In-process ownership seam

- Route manual and wake Live admission through one Miller-owned in-process
  operation.
- Persist the selected conversation before associating the Live transcript.
- Keep the existing capability RPC private to provider bridges.
- Add no daemon, transport, second database, or unused public host API.

`MillerHost` names the ownership boundary in v0.1.2. It does not require a new
Swift target or public client protocol. Transport remains deferred until a
second client exists.

## v0.1.3: unified Live text and file attachments

The target is one Miller conversation that accepts speech, typed text, and
bounded file context without replacing the low-latency WebRTC audio path.

### Typed input during Live

- Allow text submission while a Live session is active.
- Route typed text into the admitted Live session rather than opening a second
  provider thread.
- Bind the Live session to the selected Miller conversation.
- Seed only bounded, completed conversation context.
- Persist the owner's typed entry exactly once and suppress provider echoes.
- Serialize text submissions with session generation, ordinal, cancellation,
  and visible failed or unsent states.
- Preserve mute, interrupt, end, tool activity, and current audio latency.
- Treat typed input as a natural interruption or steering event unless the
  protocol spike proves a safer behavior.
- Offer an explicit post-Live continuation action. Any automatic attachment of
  the last voice session should remain an owner preference and default off.

### File attachments

- Add a Miller-owned, private, bounded attachment store with opaque IDs,
  atomic writes, hashes, and explicit deletion.
- Add picker, drag-and-drop, and attachment chips to typed and Live surfaces.
- Begin with text, source code, JSON, CSV, and PDFs that already contain text.
- Expose attachments through fixed read-only capabilities, not one tool per
  file and not raw host paths.
- Grant access only to the admitted conversation, turn, or Live session and
  revoke it on terminal cleanup.
- Keep file bytes out of App Server JSONL frames. Send only bounded control
  messages and capability results.
- Parse files off the main actor and enforce byte, count, text, result, and
  timeout limits.
- Treat extracted content as untrusted data, never as instructions.

Image understanding and scanned-PDF OCR may move to a later update if they
would expand the first attachment implementation materially.

## Later client work

Miller should eventually support more than one presentation client without
synchronizing multiple SQLite databases.

1. Keep one account-local `MillerHost` authoritative for data, credentials,
   providers, capabilities, Live sessions, and approvals.
2. Prove the Miller Client Protocol in-process in the desktop app.
3. Add a local Unix socket or XPC transport only when another local client
   needs it.
4. Prove remote text, status, and approval flows in a responsive web client.
5. Prove remote Live signaling while the phone carries WebRTC media directly
   whenever possible.
6. Consider a native iOS client after those semantics are stable.

The account-local host retains provider, MCP, and OAuth credentials. Remote
clients receive only the authority and results required for their admitted
operations.

## Planning sources

- `docs/superpowers/plans/2026-08-08-miller-unified-live-text-and-attachments.md`
  preserves the detailed architecture review and implementation proposal.
- `docs/superpowers/specs/2026-08-08-miller-host-client-protocol-direction.md`
  records the multi-client authority and extraction guardrails.

Both documents require a fresh source and upstream-protocol check before an
agent compiles them into executable task packets.
