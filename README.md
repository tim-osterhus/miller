# Miller

Miller is a planned, standalone-capable personal assistant for real-time voice,
messaging, and governed delegation.

Miller is currently at the design stage. This repository establishes its
product boundary, public license, and provenance policy; it does not yet
contain a runnable assistant.

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

No voice pipeline, desktop donor, messaging framework, model runtime, or model
asset has been selected yet.

Miller intends to use only Apache-2.0, MIT, BSD, or equivalently permissive
source dependencies in its distributed product. Repository licenses alone are
not sufficient: native binaries, transitive dependencies, model weights,
tokenizers, phonemizers, voices, wake-word models, fonts, audio, and artwork
must each pass provenance and redistribution review.

See `PROVENANCE.md` and `THIRD_PARTY_NOTICES.md`.

## License

Miller is licensed under the Apache License 2.0. See `LICENSE` and `NOTICE`.
