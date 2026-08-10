# Miller v0.1.2 release checklist

## Source-first closure

- [x] Complete Swift and Gateway suites pass from a clean dependency install.
- [x] Release-mode package contains only the production gateway and reviewed
      runtime closure.
- [x] Release inventory, SPDX SBOM, provenance, licenses, and notices agree.
- [x] No Codex, Rust/Cargo, Cortana, fake helper, avatar renderer, or VRM asset
      is distributed.
- [x] Headless M1 size, process, write-root, and cleanup evidence is retained.
- [x] Packet 3 Live-text spike is recorded as `INCONCLUSIVE` without product
      support.
- [x] Packet 5 wake integration is headless-approved; its human gate is
      `LIVE_NOT_RUN`.

## Owner-visible M1 gate — NOT RUN

- [ ] External Codex readiness/timeout plus one typed turn.
- [ ] Overlay/full-window selection and Command-C.
- [ ] GPT-Live speech/transcript/interrupt/end/second session/cleanup.
- [ ] Default/custom wake phrase.
- [ ] Typed fallback with wake disabled and Live unavailable.
- [ ] Reset/removal/relaunch with no lingering helper or microphone owner.

Evidence: `docs/qualification/v0.1.2-headless-report.md` and
`docs/qualification/v0.1.2-human-protocol.md`. These artifacts explicitly
record `HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN` and do not claim a human
pass.

## Deferred signing and publication

- [ ] Build from a clean checkout on a Mac with the full Xcode toolchain.
- [ ] Apply Developer ID signing without exposing credentials to the repo.
- [ ] Notarize and staple the application.
- [ ] Pass clean-account Gatekeeper, upgrade, reset, and removal checks.
- [ ] Complete a small beta and correct release blockers.
- [x] Freeze version, changelog, checksums, SBOM, and notices for the closure
      candidate.
- [ ] Publish source and the signed/notarized application.

The closure candidate is not publication-ready until the owner-visible M1 gate
passes and publication is separately authorized.

Miller Avatar is released separately and is not part of this checklist.
