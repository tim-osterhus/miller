# Wakeword donor audit

## Approved source boundary

- Canonical repository: reviewed external donor checkout (host and local path
  intentionally omitted from this public audit)
- Approved immutable commit: `8f4af867c575c089f45a8df4768663a521f88203`
- Owner-authorized scope: the nine files below, read only from that commit with
  `git show <commit>:<path>`

Approved donor files:

1. `Cortana/WakeWord/SherpaONNXBridge.h`
2. `Cortana/WakeWord/SherpaONNXBridge.mm`
3. `Cortana/WakeWord/SherpaWakeWordDetector.swift`
4. `Cortana/WakeWord/WakeCommandEndpointDetector.swift`
5. `Cortana/WakeWord/WakeWordContracts.swift`
6. `Cortana/WakeWord/WakeWordCoordinator.swift`
7. `Cortana/WakeWord/WakeWordFrameAccumulator.swift`
8. `Cortana/WakeWord/WakeWordProductionController.swift`
9. `Cortana/WakeWord/WakeWordSettingsController.swift`

`Cortana/Views/Settings/WakeWordSettingsView.swift` is explicitly excluded.
Miller owns its settings presentation. No test, probe, installed-application,
uncommitted-worktree, or other Cortana file is an approved source donor.

The immutable donor selection was checked with:

```text
git diff --quiet 8f4af867c575c089f45a8df4768663a521f88203 -- Cortana/WakeWord
exit status: 0
```

This comparison checked the donor's current `Cortana/WakeWord` subtree against
the approved immutable commit and found no divergence at audit time. Donor
source bytes were still read only from the pinned commit with `git show`.

VoiceInk was neither inspected nor used. No VoiceInk source, path, installed
application, generated artifact, or metadata was consulted.

## Adaptation policy

Miller recreates only the approved owner-authored behavior, with names and
integration points adapted narrowly to Miller. Existing ownership/provenance
comments are preserved. The import does not include Cortana settings UI,
donor audio, build products, or tests. Miller's Packet 5 adapters own
production AVAudioEngine capture, private keyword materialization, WebKit PCM
handoff, and settings composition.

## Packet 5 packaging boundary

The explicit verified bootstrap retains only the pinned arm64 static libraries
and the five model/token files needed by `MillerWake`. Packaging verifies that
root and copies only those model/token files into
`Contents/Resources/WakeWord/model`; linked native code remains in Miller.
Archives, headers, compiler inputs, extraction roots, and private generated
keyword files are excluded.

## Fetched dependency boundary

Wakeword archives are fetched only by the explicit bootstrap script into
`.build/vendor/wakeword/downloads`. Each archive must match its pinned SHA-256
and exact byte size before extraction. Downloads are capped at that exact size,
and failed or partial regular files are removed. The retained arm64 libraries,
both Sherpa headers, model, tokenizer, and tokens must match the hashes in
`PROVENANCE.md`. The verifier also requires an exact nine-file allowlist beneath
the locked root, rejecting extra files, symlinks, and other non-regular objects.
Nothing beneath the wakeword vendor root is committed.

## Storage measurements and cleanup

- Free space before the first bootstrap: `21,174,759,424` bytes.
- Conservative predicted peak: `1,073,741,824` bytes.
- Exact archive sizes: Sherpa `8,941,262` bytes, ONNX Runtime `17,358,514`
  bytes, and the keyword model `17,626,723` bytes.
- First-run observed generated-root consumption: `288,829,440` bytes.
- Retained locked inputs after transient archives and extraction trees were
  removed: `113,893,376` bytes.

The conservative forecast was well below the available 20 GiB budget. Final
qualification removes `.build/vendor/wakeword` with
`scripts/clean.sh --dependencies`. That cleanup reclaimed `129,097,728` bytes,
left `19,948,830,720` bytes free, and proved the vendor root absent. A
subsequent ordinary focused test completed without recreating the vendor root,
proving that non-wake tests do not download wakeword inputs. The existing
`.artifacts/release/Miller.app` and running Miller process were preserved.

The review repair added deterministic safety probes to both the bootstrap and
verifier. They reject vendor-root, nested staging-root, locked-root, and
partial-download symlinks while proving their targets remain unchanged. The
bootstrap additionally proves exact-size local downloads, oversize rejection,
failure cleanup, and offline behavior. The verifier proves that a tampered
header and an unexpected retained file are rejected. The real pinned bootstrap
and verifier then passed, as did all 827 Swift tests, all 49 gateway tests, and
the focused 21-test linked wakeword run. The repaired dependency cleanup
reclaimed `127,762,432` bytes from the wakeword and gateway dependency roots.
The vendor root remained absent after the ordinary no-download test, while the
existing release app and running process remained intact.
