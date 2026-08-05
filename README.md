# Miller

Miller is a standalone-capable personal assistant for real-time messaging,
voice, and governed delegation.

Miller is preparing its source-first v0.1 release. The initial product is a
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

The text-first alpha uses a native Swift 6.1 application with AppKit and
SwiftUI, system SQLite for durable conversation state, and a supervised Node
helper behind a Miller-owned JSONL gateway. The reviewed Node 22.22.0 macOS
arm64 runtime is bundled in development and source-release packages; the
source-release package is ad-hoc signed and does not establish Developer ID or
notarization status. GPT-Live uses
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
- `docs/qualification/offline-gate-4a-report.md`: sanitized headless
  qualification evidence and remaining human gates.

The deterministic source and package checks do not claim the owner-visible
microphone/audio gate, Developer ID signing, notarization, clean-machine
installation, or beta qualification.

## License

Miller is licensed under the Apache License 2.0. See `LICENSE` and `NOTICE`.
