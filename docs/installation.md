# Install Miller v0.1

## Requirements

- Apple Silicon Mac running macOS 15 or newer.
- Network access for hosted reasoning and GPT-Live.
- A separately installed official OpenAI Codex CLI for GPT-Live voice.
- A Codex OAuth profile or a configured HTTPS OpenAI-compatible endpoint for
  typed reasoning.

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
