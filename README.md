# Miller

Miller is a standalone-capable personal assistant for real-time messaging,
voice, and governed delegation.

Miller v0.1.1 is the source-first capability and voice-history candidate. It is a
local Apple Silicon macOS 15 menu-bar assistant with durable typed
conversations, Codex OAuth, an OpenAI-compatible provider path, and GPT-Live
voice through a separately installed official Codex CLI.

## Where Miller sits

Miller will own the human-facing interaction loop: conversations, voice and
messaging sessions, streaming responses, interruption, identity, permission
presentation, notifications, and delegation.

It will be useful on its own, without requiring another Millrace product. It
will also provide first-class integrations with:

- **Millrace**, for governed, durable, multi-stage work with recovery and
  auditable completion;
- **Millrace OS**, for coherent discovery, control, and presentation alongside
  the rest of the local ecosystem.

Miller will not become a second workflow runtime or treat model, client,
process, or interface state as Millrace runtime truth.

## Miller Protocol

Miller Protocol is the planned versioned contract between clients, Miller
Core, model and media providers, and delegated systems. It will describe
conversation identity, turn and stream events, interruption, capability
proposals, approvals, tool results, delegation receipts, progress, and final
outcomes without binding Miller to one transport, model, UI, or borrowed
framework.

The protocol is a target, not an implemented API.

## Dependency posture

The v0.1.1 application uses a native Swift 6.1 application with AppKit and
SwiftUI, system SQLite for durable conversation state, and a supervised Node
helper behind a Miller-owned JSONL gateway. The capability bridge, MCP Swift
SDK, reviewed Node 22.22.0 macOS arm64 runtime, Pi overlay, and existing
JavaScript dependencies are the complete shipped runtime inventory. The
source-release package is ad-hoc signed for structural checks only and does
not establish Developer ID or notarization status. GPT-Live uses
the App Server in a separately installed official Codex CLI. Miller discovers
common installation locations or uses an owner-selected path, admits only an
OpenAI-signed arm64 `codex` executable, and launches that native binary
directly. Miller does not bundle, build, download, update, or remove Codex.
macOS system WebKit owns the WebRTC media plane. The direct OpenAI `/v1/live`
adapter remains experimental comparator evidence and is not selected in
production. The provider path is limited to Codex OAuth and one configurable
OpenAI-compatible endpoint.

Hosted reasoning and GPT-Live require network access. Typed conversation and
local history remain usable when Live Voice is unavailable, but the v0.1 voice
path is not an offline feature.

The GPT-Live path supplies its own WebRTC speech input and output for the MVP.
Live Voice captures microphone audio only after the explicit Start Live Voice
action and plays remote WebRTC audio through the system media peer. Audio is
not saved. The visible transcript is selectable text; saving a text turn never
implies that audio was saved. History is reviewed explicitly from Miller's
history surface.
Replaceable standalone STT and TTS adapters and local neural speech remain
deferred to the first post-MVP update. Miller Avatar is a separate follow-on
product. Miller v0.1 contains no avatar renderer or VRM asset and does not
require Miller Avatar to be installed.

Miller will source code and assets only from Apache-2.0, MIT, BSD, or
equivalently permissive projects. Repository licenses alone are not sufficient:
native binaries, transitive dependencies, model weights, tokenizers,
phonemizers, voices, wake-word models, fonts, audio, and artwork must each pass
provenance and redistribution review.

See `PROVENANCE.md` and `THIRD_PARTY_NOTICES.md`.

## Documentation

- `docs/architecture.md`: implemented ownership and process boundaries.
- `docs/development.md`: build, test, package, CI, and cleanup commands.
- `docs/privacy.md`: local storage and provider-context disclosure.
- `docs/security.md`: credential, helper, endpoint, and Gate 4B boundaries.
- `docs/removal.md`: reset-before-removal procedure and residual effects.
- `docs/installation.md`: requirements, installation, and first-run setup.
- `docs/provider-compatibility.md`: supported reasoning and voice paths.
- `docs/troubleshooting.md`: bounded recovery for common failures.
- `docs/release-checklist.md`: source, human, signing, and publication gates.
- `docs/qualification/source-first-headless-report.md`: sanitized source-release
  package, reliability, M1 baseline, and cleanup evidence.
- `docs/qualification/gate-4b-external-codex-human-report.md`: sanitized
  owner-visible external-Codex and GPT-Live qualification evidence.
- `docs/qualification/offline-gate-4a-report.md`: sanitized headless
  qualification evidence and remaining human gates.
- `docs/qualification/v0.1.1-headless-report.md`: deterministic sanitized
  release-candidate evidence.
- `docs/qualification/v0.1.1-human-protocol.md`: owner-visible rows that remain
  not run in this bounded qualification.

The deterministic source and package checks do not claim Developer ID signing,
notarization, clean-machine installation, microphone/audio behavior, or beta
qualification. Human rows in the v0.1.1 protocol remain not run.

## v0.1.1 operating boundaries

MCP setup is explicit: add a local or remote server, review its displayed
identity and declared tools, and choose a trust policy before enabling it.
Read-only calls may run automatically under the read-only policy; changing or
unknown calls require approval under ask-before-changes; fully trusted mode is
an explicit owner choice. Policy decisions and tool outcomes are recorded as
bounded audit events.

Account-backed apps are Codex-only in v0.1.1. Other providers are reachable
through the provider adapter boundary and do not receive Codex account
installation or management. Codex Live Voice therefore requires an
owner-installed official Codex App Server; missing, incompatible, unavailable,
or failed external Codex leaves typed operation and local history available.
Provider portability applies to typed reasoning and the Pi gateway, not to
the Codex-only account surface.

Wake-word inputs remain source-only for v0.1.2. v0.1.1 packaging does not
bootstrap, download, compile, or ship wake dependencies or models.

## License

Miller is licensed under the Apache License 2.0. See `LICENSE` and `NOTICE`.
