# Provider compatibility

## Typed reasoning

Miller v0.1 supports Codex OAuth through the reviewed Pi-derived gateway and
one configurable HTTPS OpenAI-compatible endpoint. DeepSeek is the qualified
OpenAI-compatible reference. Model identifiers are configurable; availability
is confirmed by the provider on first use. Settings checks only local Codex
process and protocol readiness, so opening settings does not start a model
turn. The explicit `Refresh Codex` and `Retry helper readiness` actions each
run at most one bounded remote/provider probe; its result is cached until a
credential or profile mutation.

Miller owns conversation history, context selection, cancellation, and visible
terminal outcomes. Providers do not own Miller's durable conversation state.

The v0.1.1 tested external Codex minimum is official Codex CLI/App Server
`0.146.0` on Apple Silicon. The fixtures preserve `0.145.0` as protocol
reference/evidence only; it is not a supported runtime boundary. The Pi gateway
and OpenAI-compatible path are provider-portable for typed reasoning, while the
account-backed app surface remains Codex-only.
Protocol reference: `0.145.0`; tested runtime: `0.146.0`.

### External Codex readiness

Miller keeps local and remote facts separate. The bounded local check verifies
the selected executable, starts App Server, completes initialization, and
completes the in-memory OAuth handshake. It does not require a model turn.
The owner-visible states are:

- executable missing;
- executable rejected by identity or signature verification;
- local credential unavailable (missing or invalidated);
- authentication required;
- App Server unavailable during spawn or initialization;
- unsupported App Server protocol;
- remote readiness probe timed out;
- provider unavailable after local initialization;
- Codex cleanup pending; and
- ready.

The optional remote provider and capability probe has its own 30-second
ceiling and cleans up its child and temporary root. It is not polled or
repeated while Settings loads. A timeout is reported as
`Readiness probe timed out`; it does not rewrite known executable,
initialization, or authentication evidence as process absence. A normal typed
turn may still be attempted after that optional probe, and its result does not
erase the earlier local facts. If private-root cleanup reaches its hard
deadline, Miller reports `Codex cleanup pending`, refuses unsafe same-root
reuse, and permits recovery after a later cleanup retry succeeds.

## GPT-Live voice

GPT-Live is available only through a selected Codex OAuth profile and a
separately installed compatible official Codex CLI. It is not the public
GPT-Realtime API and does not use an OpenAI API key. Account entitlement,
network availability, and the external Codex version can affect readiness.

DeepSeek and generic OpenAI-compatible profiles are text-only in v0.1. Local
STT/TTS adapters are planned after v0.1. Typed operation remains available
when voice is unavailable.
