# Wakeword donor audit

## Approved source boundary

- Canonical repository: `/Users/alex/Desktop/bonzo-dashboard/cortana` on
  `kindly-macmini`
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
git diff --quiet 8f4af867c575c089f45a8df4768663a521f88203 \
  8f4af867c575c089f45a8df4768663a521f88203 -- Cortana/WakeWord
exit status: 0
```

This comparison deliberately uses the approved commit as both endpoints. It
confirms that the copied source set is anchored to one immutable Git tree
without reading or making any claim about the donor's current working tree.

VoiceInk was neither inspected nor used. No VoiceInk source, path, installed
application, generated artifact, or metadata was consulted.

## Adaptation policy

Miller recreates only the approved owner-authored behavior, with names and
integration points adapted narrowly to Miller. Existing ownership/provenance
comments are preserved. The import does not include Cortana settings UI,
audio, models, binary libraries, build products, or tests.

## Fetched dependency boundary

Wakeword archives are fetched only by the explicit bootstrap script into
`.build/vendor/wakeword/downloads`. Each archive must match its pinned SHA-256
before extraction. The retained arm64 libraries, headers, model, tokenizer,
and tokens must match the hashes in `PROVENANCE.md`. Nothing beneath the
wakeword vendor root is committed.

## Storage measurements and cleanup

- Free space before the first bootstrap: `21,174,759,424` bytes.
- Conservative predicted peak: `1,073,741,824` bytes.
- Three archive sizes: `8,941,262`, `17,626,723`, and `17,358,514` bytes.
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
