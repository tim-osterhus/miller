# Miller Avatar lip-sync and High Quality owner protocol

Status: `NOT_RUN_PENDING_FINAL_CANDIDATE`

Expected marker: `MILLER_AVATAR_LIP_SYNC_AND_HIGH_QUALITY_HUMAN_PASS`

This protocol is the owner-visible qualification record for Miller Avatar
v0.1.1 as consumed by Miller. The final packaged candidate has not been
qualified yet. Every outcome below is therefore intentionally `NOT_RUN`.

The protocol uses two disposable, owner-supplied VRM 1.0 test profiles:

- **Model A — all-five capability:** reports the complete five-vowel mouth-cue
  capability and is expected to show a responsive five-vowel approximation.
- **Model B — partial/aa-only capability:** reports only a partial capability
  and is expected to use the scalar fallback without failing the session.

No model, motion, texture, audio, transcript, provider payload, credential,
FFT/spectral value, vowel value, private path, or identifying asset name is
recorded in this document. The phrase “responsive five-vowel approximation”
describes the intended behavior; it is never a claim of phoneme accuracy.

## Qualification rules

1. Run the checks against one final packaged Miller candidate containing the
   exact Miller Avatar v0.1.1 dependency and reviewed lip-sync resource.
2. Use disposable local copies of the two profiles. Do not modify or remove
   an original owner asset.
3. Record only the status field, bounded timings or memory measurements, and a
   short sanitized failure code if a row fails.
4. Do not record conversation content, audio, raw or derived audio data,
   transcript text, provider details, credentials, or asset identity.
5. A `PASS` requires direct owner-visible observation. A deterministic test
   result alone does not turn an unobserved owner row into `PASS`.
6. Any visual, lifecycle, privacy, accessibility, or functional `FAIL` blocks
   release closure until corrected and retested.

## Preconditions and baseline

| Check | Outcome | Sanitized observation |
| --- | --- | --- |
| Final Miller candidate is present and its Avatar dependency resolves to v0.1.1 | `NOT_RUN` | Pending final candidate |
| Candidate inventory contains the classifier resource and no model, motion, texture, or audio asset | `NOT_RUN` | Pending final candidate |
| Avatar is disabled before the first enabled run | `NOT_RUN` | Pending final candidate |
| Ordinary Miller content and native controls remain usable with Avatar disabled | `NOT_RUN` | Pending final candidate |
| Model A and Model B are disposable local test profiles | `NOT_RUN` | Pending owner test setup |

## Two-model Live Voice matrix

Each cell is an explicit owner-visible result field. Exercise both profiles
with one final candidate and record only `PASS`, `FAIL`, or `NOT_RUN` plus a
sanitized bounded failure code when applicable.

| Scenario | Model A — all-five capability | Model B — partial/aa-only capability |
| --- | --- | --- |
| Normal Live output | `NOT_RUN` | `NOT_RUN` |
| Rapid Live output | `NOT_RUN` | `NOT_RUN` |
| Quiet or low-level Live output | `NOT_RUN` | `NOT_RUN` |
| Pause-heavy Live output | `NOT_RUN` | `NOT_RUN` |
| Multi-sentence Live output | `NOT_RUN` | `NOT_RUN` |
| Audible played output produces mouth presentation | `NOT_RUN` | `NOT_RUN` |
| Silence returns to neutral without stale presentation | `NOT_RUN` | `NOT_RUN` |
| Expected result | Responsive five-vowel approximation; never phoneme accurate | Graceful scalar fallback; session remains functional |

Model A must show more than one visibly responsive mouth shape across the
normal, rapid, quiet, pause-heavy, and multi-sentence rows. Model B must not
be rejected merely because its capability is partial. It may use the scalar
mouth cue, but it must not expose malformed or partial five-vowel data.

## Lifecycle and setting matrix

Run these rows for each profile where the row is profile-specific. `NOT_RUN`
means the final candidate has not yet been exercised.

| Check | Model A | Model B | Required result |
| --- | --- | --- | --- |
| Interrupt during played output | `NOT_RUN` | `NOT_RUN` | Mouth presentation clears promptly; Live remains usable |
| Second Live session after interruption | `NOT_RUN` | `NOT_RUN` | Fresh session starts without stale mouth state |
| Repeated Live sessions | `NOT_RUN` | `NOT_RUN` | No drift, stuck pose, or unbounded resource growth |
| Toggle lip sync Off during speech | `NOT_RUN` | `NOT_RUN` | Mouth cues stop and clear; speech and animation continue |
| Toggle lip sync On during speech | `NOT_RUN` | `NOT_RUN` | New cues begin without replaying an old cue |
| Reduced Motion during played output | `NOT_RUN` | `NOT_RUN` | Skeletal and mouth motion stop; normalized static pose remains valid |
| Replace selected profile while idle | `NOT_RUN` | `NOT_RUN` | Old presentation is cleared before the replacement appears |
| Replace selected profile during Live | `NOT_RUN` | `NOT_RUN` | No stale callback or mouth cue reaches the replacement |
| Retry after renderer or asset failure | `NOT_RUN` | `NOT_RUN` | Retry is truthful; unaffected Miller and Live controls remain usable |
| Disable and re-enable Avatar | `NOT_RUN` | `NOT_RUN` | Surface and mouth state detach/reinitialize cleanly |
| Close and reopen the overlay | `NOT_RUN` | `NOT_RUN` | No duplicate surface, stuck pose, or lost native focus |

## Privacy and compatibility checks

| Check | Outcome | Required result |
| --- | --- | --- |
| Lip sync setting defaults On | `NOT_RUN` | Default is On when the capability is available |
| Scalar-only compatibility | `NOT_RUN` | Existing scalar cue path remains functional |
| Partial capability compatibility | `NOT_RUN` | Partial model falls back without malformed payloads |
| Microphone-derived mouth motion | `NOT_RUN` | Must not occur |
| Raw audio or spectral data across the Avatar bridge | `NOT_RUN` | Must not occur |
| Transcript or provider lifecycle alone creates mouth motion | `NOT_RUN` | Must not occur |
| Lip-sync setting does not require renderer restart | `NOT_RUN` | Toggle applies without restarting the renderer |
| Accessibility and native focus remain intact | `NOT_RUN` | Avatar remains noninteractive; native controls remain reachable |

The implementation observes played remote output only. The protocol does not
authorize a second microphone path, raw-audio bridge, transcript-derived cue,
or phoneme-accuracy evaluation.

## M1 lip-sync measurements

Repeat the same bounded Live Voice exercise with lip sync On and Off. Record
numbers only; do not retain audio, transcript, spectral, provider, or cue
payload data.

| Measurement | Lip sync On | Lip sync Off | Required result |
| --- | --- | --- | --- |
| Process-family resident-memory baseline | `NOT_RUN` | `NOT_RUN` | Record bounded value |
| Process-family resident-memory peak | `NOT_RUN` | `NOT_RUN` | No material unexplained regression |
| Stable analysis sample cadence | `NOT_RUN` | `NOT_RUN` | At least 34 ms between samples |
| Per-sample analyser-buffer allocation | `NOT_RUN` | `NOT_RUN` | No per-sample allocation pattern |
| Repeated-session memory trend | `NOT_RUN` | `NOT_RUN` | No unbounded growth |
| Audible playback behavior | `NOT_RUN` | `NOT_RUN` | No audible regression |

Any material regression is recorded as a defect; it does not authorize
silently changing the disclosed admission or performance policy.

## High Quality admission matrix

High Quality is a finite, explicit per-import/per-profile mode. Lightweight
remains the default. These checks join the lip-sync gate and must use the same
final candidate.

| Check | Outcome | Required result |
| --- | --- | --- |
| Generated fixture above Lightweight but below High Quality | `NOT_RUN` | Lightweight rejects deterministically; High Quality admits it |
| Lightweight safety posture | `NOT_RUN` | Existing Lightweight limits and five-second preflight remain unchanged |
| High Quality outer captured-file ceiling | `NOT_RUN` | Exactly 2.5 GiB / 2,684,354,560 bytes |
| High Quality outer buffer ceiling | `NOT_RUN` | Exactly 2.5 GiB / 2,684,354,560 bytes |
| High Quality accessor-referenced ceiling | `NOT_RUN` | Exactly 2.5 GiB / 2,684,354,560 bytes |
| High Quality aggregate posture | `NOT_RUN` | 20x finite byte/count/geometry posture |
| High Quality image dimension posture | `NOT_RUN` | 4x finite image-dimension posture |
| Integrity, cancellation, checked arithmetic, JSON, and skin-layout guards | `NOT_RUN` | Remain enforced in High Quality |
| Above-envelope input | `NOT_RUN` | Rejects deterministically; High Quality is not unlimited |
| Runtime allocation failure below policy ceiling | `NOT_RUN` | Reported truthfully; no silent policy rewrite |

## Approximately 92 MB private model owner check

Use the owner’s approximately 92 MB VRM 1.0 model only as a private local
qualification input. Do not record its name, path, hash, image, or identifying
metadata.

| Check | Outcome | Required result |
| --- | --- | --- |
| Import with Lightweight selected | `NOT_RUN` | Deterministic Lightweight rejection, if it exceeds that mode |
| Import with High Quality selected | `NOT_RUN` | Admission result is truthful and bounded |
| Recorded mode after import | `NOT_RUN` | Profile records `high_quality`; no silent downgrade |
| Reopen/reload without reimport | `NOT_RUN` | Same model and recorded mode reload correctly |
| Retry after a controlled failure | `NOT_RUN` | Retry uses the recorded mode and remains truthful |
| Disable/re-enable Avatar | `NOT_RUN` | Profile and mode remain coherent |
| Switch profiles and return | `NOT_RUN` | Existing profile mode is not reclassified |
| Reduced Motion | `NOT_RUN` | Static valid pose; no malformed clipping or stale motion |
| One Live Voice session | `NOT_RUN` | Session and lip-sync policy remain functional |
| M1 measurements | `NOT_RUN` | Record bounded On/Off memory and responsiveness values |

## Result and release decision

Current result: `NOT_RUN_PENDING_FINAL_CANDIDATE`.

Final owner qualification may use only these outcome values:

- `PASS` — directly observed and all required behavior held.
- `FAIL` — directly observed failure, with a sanitized bounded failure code.
- `NOT_RUN` — candidate, owner action, or evidence was unavailable.

The combined Miller Avatar v0.1.1 lip-sync/High Quality gate passes only when
all required rows are `PASS`, no privacy or lifecycle row is `FAIL`, and the
M1 measurements show no material regression. A final report must continue to
say “responsive five-vowel approximation” and must never say “phoneme
accurate.”
