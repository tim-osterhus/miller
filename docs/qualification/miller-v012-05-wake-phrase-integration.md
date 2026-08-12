# Packet 5 wake-phrase integration qualification

Status: deterministic implementation complete; owner-visible microphone,
permission, and custom-phrase gate: `LIVE_NOT_RUN`.

## Product contract

- Wake Listening defaults off and stores its enabled flag, phrase, keyword
  score, and detection threshold in the existing SQLite preference repository.
  Keyword score defaults to 5.0 and detection threshold defaults to 0.05.
- The first valid phrase is Hey Miller. The owner may replace it with one
  bounded English phrase. Normalization, tokenization, and Sherpa keyword-file
  materialization are local; invalid input preserves the last working phrase
  and file with a visible error.
- Capture is system-default microphone only, 16 kHz mono Int16, owned by one
  AVAudioEngine adapter. Wake and Live use one process-local microphone lease.
- A match opens Miller. Empty wake timeout rearms without Live. Silence or the
  hard limit transfers the bounded post-keyword PCM to exactly one Live
  admission and one existing WebKit outbound track.
- Wake capture yields before Live and rearms only after provider, WebKit,
  transcript, and admission cleanup. Disable, shutdown, sleep, device loss,
  and permission failure release capture and publish state. Application focus
  changes and closing Settings leave enabled wake capture active.
- PCM is never persisted or logged. The private keyword file is owner-only:
  a `0700` directory and `0600` file, with symlink-safe temporary write,
  fsync, atomic replacement, and rollback.

## Build and package boundary

Only the explicit `scripts/bootstrap-wakeword-dependencies.sh` may download
the pinned archives. It forecasts the exact archive total
(`43,926,499` bytes), requires at least 1 GiB before bootstrap, and refuses to
cross the 6 GiB free-space floor. `scripts/verify-wakeword-dependencies.sh`
remains authoritative for hashes and the retained nine-file input allowlist.

Packaging verifies the retained root and ships only the five runtime
model/token files under `Contents/Resources/WakeWord/model` plus the linked
native code. It does not ship archives, headers, compiler inputs, extraction
roots, or private generated keyword files. Ordinary tests use
`--if-present` verification and never download.

## Deterministic evidence

The focused suites cover phrase bounds and unsupported input, materializer
permissions and rollback, missing model/input/permission/retry paths, one
microphone owner, lifecycle races and stale callbacks, one Live start and one
handoff, failure/interrupt cleanup, sleep/device loss/shutdown, focus
independence, persisted tuning defaults and rollback, and package
inventory/provenance/SBOM/notices/cleanup. The final run records exact
commands, test counts, storage measurements, package-size delta, and cleanup
in the parent handoff. The current full serial suite passed 990 tests.

The earlier route-fixture observation—three route fixtures returned status 79
and the Pi-provider fixture returned status 1 in that environment—is retained
as historical evidence and explicitly superseded for deterministic headless
evidence by the later exact v0.1.2 run
(`./scripts/run-headless-release-qualification.sh`) at release HEAD
`5dc99351d83027abdb9f9b1fe176b044444d0ed7`. Its committed
`v0.1.2-headless-report.md` records PASS for the three route checks and the
Pi-provider check. This supersession is headless evidence only; it does not
qualify a human wake run, and the owner-visible microphone, permission,
custom-phrase, audible handoff, Live, and recovery rows remain
`LIVE_NOT_RUN`.

## Measurements

- Wake bootstrap forecast: 43,926,499 archive bytes; measured archive:
  43,926,499 bytes.
- Measured extracted/peak generated root: 128,692,224 bytes; retained
  bootstrap inputs after cleanup: 113,893,376 bytes. Download and extraction
  roots were absent after verification.
- Lowest recorded free space during bootstrap: 12,379,004 KiB, above the
  6 GiB floor. Post-cleanup free space: 19,887,512 KiB.
- Final verified release app: 184,385,536 bytes. Pre-wake baseline:
  155,369,472 bytes. Delta: 29,016,064 bytes. The release inventory contains
  2,134 files and only the five pinned wake model/token files under the wake
  model directory.
- Clean release build duration: 167,870 ms.
- Deterministic idle launch samples at 0.5 seconds: cold 49,408 KiB RSS and
  38.8% CPU; warm 49,680 KiB RSS and 38.5% CPU. No Gateway child started.
- Persistent logical growth per isolated cold/warm launch: 258,048 bytes of
  SQLite database/sidecars and 0 bytes of cache growth. Measurement roots were
  removed.

## Human gate

Partial owner-visible evidence recorded on 2026-08-11 HST:

- background-focus wake listening remained active outside Miller Settings;
- two consecutive wake-triggered Live admissions became usable in
  approximately 10 seconds each, with no `voice_timeout`;
- the durable store records a matching completed wakeword session with a
  10.022-second start-to-completion interval; the second observed session was
  still open when the sanitized evidence was inspected.

This closes the prior startup-timeout regression, but it does not promote the
entire wake gate to PASS.

The following rows remain `LIVE_NOT_RUN` and are not inferred from tests:

- real microphone permission request and denial recovery;
- human speech detection for Hey Miller;
- owner custom-phrase save and relaunch;
- audible one-shot post-keyword command handoff;
- real Live provider admission, interruption, failure, cleanup, and rearm;
- observed sleep/device-loss recovery on the owner machine.
