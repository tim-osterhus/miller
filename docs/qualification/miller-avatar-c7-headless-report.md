# Miller Avatar C7 cross-repository source/headless qualification

Marker: `MILLER_AVATAR_C7_HEADLESS_PASS`

Terminal result: `HEADLESS_SOURCE_VERIFIED_INTEGRATED_ARTIFACT_NOT_BUILT_HUMAN_NOT_RUN`

This report records deterministic, synthetic, nonlaunching qualification for
Miller's optional Miller Avatar integration. It makes no owner-visible claim
about a private model, motion quality, physical keyboard focus, VoiceOver,
real Live audio, signing, notarization, publication, or M1 performance.

## Qualified source boundary

- Miller's reviewed Avatar integration and sentence-gap continuity checkpoint
  is `886cf2181f9bb7e9ee8c92cc53fb406c0d8c9faa`. It descends from the prior
  package-integration checkpoint
  `6d2c3e98c9a544c22224c1639033a245ca392430`. The packaging/provenance
  update containing this report does not change coordinator behavior.
- Published Miller v0.1.2 commit
  `6280a38c3b0c0afa936f3af6550645306221ded4` is an ancestor of that head.
- Miller resolves Miller Avatar `v0.1.0-alpha.5` at the exact reviewed commit
  `0a63ef310514f758079caf9f16490507e128dc92`.
- That reviewed alpha.5 checkpoint contains the renderer-persistence repair,
  authored root-motion preservation, and fixed root-motion camera envelope
  exercised by this matrix.
- Avatar is off by default. Ordinary Avatar-off startup does not construct a
  renderer, capture a model, request microphone access, or add a network
  request.
- The retained owner-qualified v0.1.2 app was not launched, replaced, or used
  as C7 evidence. Its Miller and Gateway processes remained running from the
  retained release bundle throughout this headless pass.

## Cross-repository source/headless matrix

| Boundary | Result | Deterministic evidence |
| --- | --- | --- |
| Model admission | `PASS` | Corrupt, malformed, over-budget, external-resource, symlink, changed-digest, removed, and rejected model paths fail before renderer authority. |
| Motion admission | `PASS` | Invalid, over-budget, missing, multiply bound, changed, removed, timed-out, and runtime-failed VRMA paths remain motion-local. Entry 33 is refused. |
| Quarantine and retry | `PASS` | Three model or per-motion failures enter the corresponding quarantine. Explicit retry, reselection, and successful load reset only the intended failure state, including the renderer-persistence repair in the reviewed alpha.3 checkpoint. |
| Renderer containment | `PASS` | Startup, bridge, first-frame, context-loss, invalid observation, timeout, retry, disposal, and late-callback paths are session fenced and idempotent. |
| Repeated replacement | `PASS` | Same-revision cross-profile replacement, active binding edits, hidden/resumed replacement, retry, disable, close, and reentrant callbacks preserve the current generation and release superseded bytes. |
| Presentation policy | `PASS` | Avatar Off, no-profile, static fallback, hidden, occluded, and Reduced Motion states revoke mouth cues and do not restore stale playback. Reduced Motion stops animation advancement and restores rest pose. |
| Noninteraction and accessibility contract | `PASS_HEADLESS` | The 200-point Avatar region and installed WebKit view cannot accept first responder, do not join key-view traversal, ignore hit testing, and expose no accessibility children. Physical focus preservation, Tab/Shift-Tab, and VoiceOver remain human checks. |
| Typed lifecycle | `PASS` | Accepted typed turns own their generation and project only bounded semantic states; stale, failed, stopped, and replaced turns cannot mutate a newer projection. |
| Live lifecycle and mouth cues | `PASS` | Only measured audible remote output creates `speaking` and ordered mouth cues. Short sentence gaps retain one playback identity and animation action; final silence, failure, renderer loss, hide, occlusion, Reduced Motion, and close return neutral and fence late samples. |
| Feature isolation | `PASS` | Avatar errors are Avatar readiness failures. Typed operation, Live admission, history, settings, capability approvals, tool execution, wake start, and microphone ownership retain their existing authorities. |
| Source packaging and provenance contract | `PASS_HEADLESS` | Miller links only `MillerAvatarCore` and `MillerAvatarHost`, declares the fixed five-file Web bundle, inventories the exact prerelease revision, and rejects VRM, VRMA, and private-fixture content from package inputs. A fresh integrated app artifact has not yet been built or inspected. |
| Source-test cleanup | `PASS_HEADLESS` | Avatar's release gate proved deterministic native builds, failed-publication rollback, shared-cache stability, scoped cleanup, and no retained build process. Miller's nonlaunching tests left the protected release processes unchanged. Integrated app and WebKit child-process cleanup remain human checks. |

## Command evidence

| Repository | Command | Result |
| --- | --- | --- |
| Miller Avatar | `./scripts/test.sh` | `PASS`: 78 Web tests, TypeScript check, 311 Swift tests, shell contracts, deterministic independent builds, rollback, cache containment, and cleanup. |
| Miller | `./scripts/test.sh` plus `swift test --filter oversizedUnterminatedStdioFrameFailsQuickly` | `PASS_WITH_FOCUSED_TIMING_RERUN`: all 49 Gateway tests passed. The loaded full Swift run passed 1,183 of 1,184 tests; the sole failure was a pre-existing 500 ms transport timing assertion that completed in 565 ms. Its immediate isolated rerun passed in 7 ms. Neither command launches Miller. |
| Miller | `./scripts/run-task18-three-route-e2e.sh all` | `PASS`: the three synthetic tool routes passed against the exact resolved dependency lock after the pre-existing generated wake root was temporarily isolated and restored. This harness does not launch Miller. |
| Miller | `swift build --product MillerApp` | `PASS`: the integrated source builds without launching the app. |
| Miller | `git merge-base --is-ancestor 6280a38c3b0c0afa936f3af6550645306221ded4 HEAD` | `PASS` |

One deterministic harness defect was found during the first Avatar run. The
Web-bundle shell contract scanned the shared `.generated` root, so a prior
native build's embedded compile path could fail an otherwise clean Web-only
check. A regression probe now places unrelated native output in that root, and
the assertion checks only the five published Web resources. The focused
contract and complete Avatar gate pass from the previously failing state.

Adversarial review found two integration defects after the first complete
pass. Miller's final package adapter did not forward the coordinator's mouth
cue, and Miller Avatar did not commit accepted-profile renderer outcomes to
durable quarantine state. Exact-payload and stale-surface mouth regressions now
pass in Miller. Exact-once failure, three-session quarantine, validated
first-frame recovery, startup/stale-session exclusion, and motion-isolation
regressions now pass in Miller Avatar. The complete source gates above were
rerun after both repairs.

The alpha.5 correction was driven by exact private-fixture diagnosis without
copying private content into either repository. The imported motion bindings
and hashes were correct. One test motion deliberately turns the avatar around,
and another begins crouched and has a large loop seam; those are authored clip
properties. The actual renderer defect was an extra first-frame hips
reanchoring step combined with rest-pose-only camera framing. Alpha.5 preserves
Pixiv's target-relative conversion and computes one fixed root-motion envelope.
Miller separately retains the speaking playback identity across bounded
sentence gaps so one animation action is not restarted for every audio segment.

## Human gate

Status: `HUMAN_NOT_RUN`

The remaining C7 gate is defined in
`docs/qualification/miller-avatar-c7-human-protocol.md`. It requires a
separately coordinated integrated app candidate, a private user-supplied VRM
1.0 model, and compatible VRMA motions. That candidate must also pass package
inventory and cleanup verification. The protocol covers one typed turn, one
real Live turn, physical focus, VoiceOver, Reduced Motion, failure fallback,
and repeated lifecycle checks. Retained evidence may contain no model, motion,
image, transcript, audio, source path, or identifying asset metadata.
