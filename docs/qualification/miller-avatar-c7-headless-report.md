# Miller Avatar C7 cross-repository source/headless qualification

Marker: `MILLER_AVATAR_C7_HEADLESS_PASS`

Terminal result: `HEADLESS_SOURCE_AND_PACKAGE_VERIFIED_HUMAN_IN_PROGRESS`

This report records deterministic, synthetic, nonlaunching qualification for
Miller's optional Miller Avatar integration. It makes no owner-visible claim
about a private model, motion quality, physical keyboard focus, VoiceOver,
real Live audio, signing, notarization, publication, or M1 performance.

## Qualified source boundary

- Miller's reviewed Avatar framing controls and listening-continuity
  checkpoint is `c94325afa851f7d13a4868922ad9143b10f10af8`. It descends from the
  authoritative Live-output-buffer continuity checkpoint
  `9731ffc1daad2b9d647dd994d48d0fd632133fdd`.
- Published Miller v0.1.2 commit
  `6280a38c3b0c0afa936f3af6550645306221ded4` is an ancestor of that head.
- Miller resolves Miller Avatar `v0.1.0-alpha.7` at the exact reviewed commit
  `34f9e58315e3f41c3202bf593276a5dd9d89cc26`.
- Alpha.7 retains the renderer-persistence and authored-root-motion repairs,
  frames only the active motion rather than the union of every bound motion,
  excludes non-rendered helper geometry from camera evidence, and fully
  settles the normalized static pose before Reduced Motion suspends updates.
  It also uses a conservative near plane, safely bottom-biased framing, and
  resize-driven camera refits.
- Avatar is off by default. Ordinary Avatar-off startup does not construct a
  renderer, capture a model, request microphone access, or add a network
  request.
- The prior integrated candidate and Gateway stopped cleanly before packaging.
  One replacement candidate was built from Miller `ab7d6ed`, verified, and
  launched only after the source/headless gate completed.

## Cross-repository source/headless matrix

| Boundary | Result | Deterministic evidence |
| --- | --- | --- |
| Model admission | `PASS` | Corrupt, malformed, over-budget, external-resource, symlink, changed-digest, removed, and rejected model paths fail before renderer authority. |
| Motion admission | `PASS` | Invalid, over-budget, missing, multiply bound, changed, removed, timed-out, and runtime-failed VRMA paths remain motion-local. Entry 33 is refused. |
| Quarantine and retry | `PASS` | Three model or per-motion failures enter the corresponding quarantine. Explicit retry, reselection, and successful load reset only the intended failure state, including the renderer-persistence repair in the reviewed alpha.3 checkpoint. |
| Renderer containment | `PASS` | Startup, bridge, first-frame, context-loss, invalid observation, timeout, retry, disposal, and late-callback paths are session fenced and idempotent. |
| Repeated replacement | `PASS` | Same-revision cross-profile replacement, active binding edits, hidden/resumed replacement, retry, disable, close, and reentrant callbacks preserve the current generation and release superseded bytes. |
| Presentation policy | `PASS_HEADLESS` | Avatar Off, no-profile, static fallback, hidden, occluded, and Reduced Motion states revoke mouth cues and do not restore stale playback. Alpha.7 isolates camera bounds to the active motion, settles the normalized static pose before animation suspension, protects forward-moving geometry with a conservative near plane, and safely biases portrait framing downward. Compact-surface scale and deformation remain owner-visible checks. |
| Noninteraction and accessibility contract | `PASS_HEADLESS` | The configurable Avatar region and installed WebKit view cannot accept first responder, do not join key-view traversal, ignore hit testing, and expose no accessibility children. Miller's content region remains fixed at 520 points. Physical focus preservation, Tab/Shift-Tab, and VoiceOver remain human checks. |
| Typed lifecycle | `PASS` | Accepted typed turns own their generation and project only bounded semantic states; stale, failed, stopped, and replaced turns cannot mutate a newer projection. Per-profile Avatar widths are bounded, durable, and pruned only after an authoritative profile refresh. |
| Live lifecycle and mouth cues | `PASS_HEADLESS` | Only measured audible remote output creates `speaking` and ordered mouth cues. User transcript deltas remain in `listening` instead of repeatedly projecting `responding`. WebRTC output-buffer start/stop events keep one playback identity across sentence silence; the acoustic 400 ms release remains a fallback for peers without that signal. Final silence, failure, renderer loss, hide, occlusion, Reduced Motion, and close return neutral and fence late samples. Real continuity remains an owner-visible check. |
| Feature isolation | `PASS` | Avatar errors are Avatar readiness failures. Typed operation, Live admission, history, settings, capability approvals, tool execution, wake start, and microphone ownership retain their existing authorities. |
| Source packaging and provenance contract | `PASS_PACKAGE_VERIFIED` | Miller links only `MillerAvatarCore` and `MillerAvatarHost`, declares the fixed five-file Web bundle, inventories the exact prerelease revision, and rejects VRM, VRMA, and private-fixture content from package inputs. The fresh integrated app passed its ad-hoc signature checks and 2,140/2,140 inventory verification. |
| Source-test cleanup | `PASS_HEADLESS` | Avatar's release gate proved deterministic native builds, failed-publication rollback, shared-cache stability, scoped cleanup, and no retained build process. Miller's nonlaunching tests left the protected release processes unchanged. Integrated app and WebKit child-process cleanup remain human checks. |

## Command evidence

| Repository | Command | Result |
| --- | --- | --- |
| Miller Avatar | `./scripts/test.sh` | `PASS`: 84 Web tests, TypeScript check, 311 Swift tests, shell contracts, deterministic independent builds, rollback, cache containment, and cleanup. |
| Miller | focused alpha.7 regression suites | `PASS`: listening continuity 1/1, Avatar settings 15/15, live width/layout 1/1, and pane-width persistence 1/1 passed against the exact alpha.7 lock. |
| Miller | `./scripts/test.sh` plus two isolated timing reruns | `PASS_WITH_FOCUSED_TIMING_RERUN`: all 49 Gateway tests passed. The loaded full Swift run passed 1,195 of 1,197 tests; a pre-existing 500 ms transport assertion completed in 1.799 seconds and a pre-existing refresh-order race missed its expected ordering. Immediate isolated reruns passed in 13 ms and 12 ms. None of these commands launches Miller. |
| Miller | `./scripts/run-task18-three-route-e2e.sh all` | `PASS`: the three synthetic tool routes passed against the exact resolved dependency lock after the pre-existing generated wake root was temporarily isolated and restored. This harness does not launch Miller. |
| Miller | `swift build --product MillerApp` | `PASS`: the integrated source builds without launching the app. |
| Miller | `./scripts/package-dev-app.sh --release` plus `./scripts/verify-release-package.sh` | `PASS`: one integrated candidate was built, ad-hoc signed, and verified at 2,140/2,140 inventory entries before launch. |
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
Alpha.6 narrowed that envelope to the active motion, removed invisible helper
geometry from bounds, and settled the static pose before suspension. Alpha.7
adds conservative depth clipping, safe bottom-biased framing, and live viewport
refits. Miller separately consumes the WebRTC output-buffer boundary so short
acoustic gaps inside one remote response do not terminate and recreate the
speaking action, and now keeps user transcript deltas in the listening state.

## Human gate

Status: `HUMAN_IN_PROGRESS_RETEST_REQUIRED`

The remaining C7 gate is defined in
`docs/qualification/miller-avatar-c7-human-protocol.md`. It requires a
separately coordinated integrated app candidate, a private user-supplied VRM
1.0 model, and compatible VRMA motions. That candidate must also pass package
inventory and cleanup verification. The protocol covers one typed turn, one
real Live turn, physical focus, VoiceOver, Reduced Motion, failure fallback,
and repeated lifecycle checks. The owner has verified keyboard traversal and
repeated profile/retry cycles. Alpha.5 owner testing exposed excessive
deadspace and an unsettled Reduced Motion pose. A later owner pass confirmed
speaking continuity but exposed listening restarts on every transcript delta.
Those visual and continuity issues, plus the new per-profile width control,
require retesting in the alpha.7-integrated candidate.
Retained evidence may contain no model, motion, image, transcript, audio,
source path, or identifying asset metadata.
