# Provider compatibility

## Typed reasoning

Miller v0.1 supports Codex OAuth through the reviewed Pi-derived gateway and
one configurable HTTPS OpenAI-compatible endpoint. DeepSeek is the qualified
OpenAI-compatible reference. Model identifiers are configurable; availability
is confirmed by the provider on first use.

Miller owns conversation history, context selection, cancellation, and visible
terminal outcomes. Providers do not own Miller's durable conversation state.

## GPT-Live voice

GPT-Live is available only through a selected Codex OAuth profile and a
separately installed compatible official Codex CLI. It is not the public
GPT-Realtime API and does not use an OpenAI API key. Account entitlement,
network availability, and the external Codex version can affect readiness.

DeepSeek and generic OpenAI-compatible profiles are text-only in v0.1. Local
STT/TTS adapters are planned after v0.1. Typed operation remains available
when voice is unavailable.
