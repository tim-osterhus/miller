# Miller v0.1 release checklist

## Source-first closure

- [ ] Complete Swift and Gateway suites pass from a clean dependency install.
- [ ] Release-mode package contains only the production gateway and reviewed
      runtime closure.
- [ ] Release inventory, SPDX SBOM, provenance, licenses, and notices agree.
- [ ] No Codex, Rust/Cargo, Cortana, fake helper, avatar renderer, or VRM asset
      is distributed.
- [ ] Headless M1 size, process, write-root, and cleanup evidence is retained.

## Owner-visible closure

- [ ] External Codex discovery and compatibility pass on the M1 floor.
- [ ] Microphone permission, spoken input/output, transcript ordering,
      delayed follow-up, mute, interruption, second session, failure handling,
      typed fallback, and cleanup pass.

## Deferred signing and publication

- [ ] Build from a clean checkout on a Mac with the full Xcode toolchain.
- [ ] Apply Developer ID signing without exposing credentials to the repo.
- [ ] Notarize and staple the application.
- [ ] Pass clean-account Gatekeeper, upgrade, reset, and removal checks.
- [ ] Complete a small beta and correct release blockers.
- [ ] Freeze version, changelog, checksums, SBOM, and notices.
- [ ] Publish source and the signed/notarized application.

Miller Avatar is released separately and is not part of this checklist.
