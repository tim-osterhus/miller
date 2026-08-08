# Install Miller v0.1

## Requirements

- Apple Silicon Mac running macOS 15 or newer.
- Network access for hosted reasoning and GPT-Live.
- A separately installed official OpenAI Codex CLI for GPT-Live voice.
- A Codex OAuth profile or a configured HTTPS OpenAI-compatible endpoint for
  typed reasoning.

The tested external Codex boundary for v0.1.1 is official Codex CLI/App Server
`0.146.0` on Apple Silicon. `0.145.0` is retained only as protocol
reference/evidence from the App Server fixtures and is not a runtime support
claim. GPT-Live cannot start without an owner-installed external Codex App
Server; Miller does not download or package it.
Protocol reference: `0.145.0`; tested runtime: `0.146.0`.

Miller does not install, update, or remove Codex. Miller v0.1 contains no
avatar renderer or VRM asset.

## Source-release build

The current source-first artifact is ad-hoc signed for structural testing. It
is not notarized and is not a public download:

```bash
./scripts/package-release-app.sh
```

The result is `.artifacts/release/Miller.app`. Do not redistribute it as a
finished release. Developer ID signing, notarization, and clean-machine
Gatekeeper validation remain separate gates.

## First run

Open Miller, choose or create a reasoning-provider profile in Settings, and
complete Codex login or configure an OpenAI-compatible endpoint. Miller can be
used as a typed assistant when Codex or GPT-Live is unavailable. Microphone
permission is requested only after **Start Live Voice**.

Before packaging from a clean checkout, network access is required once for the
bounded, explicit `./scripts/bootstrap-gateway-dependencies.sh` lockfile
bootstrap. It verifies the exact Node and npm dependency closure. Headless
qualification does not call that bootstrap. Wakeword dependencies and models
remain source-only for v0.1.2 and are not packaged.
