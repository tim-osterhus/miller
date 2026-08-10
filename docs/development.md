# Miller development and qualification

## Toolchain

Miller targets Apple Silicon macOS 15 with Swift 6.1 and exact Node
`v22.22.0` at `/opt/homebrew/opt/node@22/bin/`. The capability bridge uses
the lockfile-pinned MCP Swift SDK. Gateway dependencies are lockfile-pinned and
must be prepared by the explicit online bootstrap:

```bash
./scripts/bootstrap-gateway-dependencies.sh
```

The bootstrap verifies the lockfile SHA-256, uses an isolated cache with bounded
network timeouts, and removes partial roots on failure. Packaging consumes the
verified closure already present in `Gateway/node_modules`; it does not install
from a private npm cache or invoke the bootstrap implicitly. The tests use local
fixtures and loopback servers. They do not call a live provider.

Task 18 tested official Codex CLI/App Server `0.146.0` on Apple Silicon. That is
the minimum tested/support boundary for v0.1.2. The protocol reference/evidence
is the `0.145.0` wire shape and fixture metadata, not a claim that `0.145.0`
is supported at runtime.
Protocol reference: `0.145.0`; tested runtime: `0.146.0`.

## Commands

Run the complete headless suite from the repository root:

```bash
./scripts/test.sh
/opt/homebrew/opt/node@22/bin/npm --prefix Gateway test
./scripts/build.sh
./scripts/package-dev-app.sh
./scripts/package-release-app.sh
./scripts/verify-release-package.sh
./scripts/verify-provenance.sh
./scripts/clean.sh
./scripts/clean.sh --dependencies
./scripts/clean.sh --preserve-release
```

`test.sh` runs the Swift suite and the protocol-fixture Node suite. The separate
Gateway command runs all Node tests. `package-dev-app.sh` creates an ad-hoc
signed development bundle under `.artifacts/`. It is not a release package.
`package-release-app.sh` compiles with release settings, removes development
harness metadata, assembles the production gateway closure, ad-hoc signs it
only for structural verification, and writes a sanitized inventory under
`.artifacts/release/`. It remains unsigned by a Developer ID and unnotarized.

The default cleanup removes `.build/`, `.artifacts/`, and `.cache/`.
`--dependencies` removes `Gateway/node_modules/` and the bounded dependency
staging/cache roots. Run both after a full qualification pass.
`--preserve-release` removes build caches, installed Gateway dependencies, the
development app, and known qualification roots while retaining only
`.artifacts/release/` for source-release inspection.

## CI boundary

CI runs on `macos-15`. Every action is pinned to a reviewed full commit SHA.
The job runs deterministic Swift, Node, packaging, provenance, and cleanup
checks. It never runs a browser, live provider, real credential, interactive
Keychain, microphone, audio, signing-identity, notarization, or visual test.
The package command performs only ad-hoc development signing.

Human checks remain in `docs/qualification/text-alpha-host-check.md` and
`docs/qualification/provider-check.md`. Do not infer those results from CI.

## v0.1.2 qualification contract

The bounded release-candidate sequence is run from a clean source tree:

```bash
./scripts/clean.sh
./scripts/bootstrap-gateway-dependencies.sh  # only when Gateway/node_modules is absent
./scripts/test.sh
./scripts/build.sh
./scripts/verify-provenance.sh
./scripts/bootstrap-wakeword-dependencies.sh  # explicit pinned-input bootstrap
./scripts/verify-wakeword-dependencies.sh
./scripts/test.sh --with-wakeword
./scripts/package-release-app.sh
./scripts/verify-release-package.sh .artifacts/release/Miller.app
./scripts/run-headless-release-qualification.sh
zsh -n scripts/*.sh
git diff --check
du -sk .build .cache .artifacts Gateway/node_modules 2>/dev/null
```

Before Swift, Node, or package work, the scripts print available space and a
bounded expected peak. They stop before a step whose expected peak would
consume the available headroom. The release qualification removes build
caches, installed Gateway dependencies, sockets, wake inputs, and helper/test
processes with `./scripts/clean.sh --preserve-release`, retaining only the
release app and sanitized qualification evidence.

Wake Listening is an explicit Packet 5 integration. Ordinary tests run
`./scripts/verify-wakeword-dependencies.sh --if-present` and never download.
Only the explicit `./scripts/bootstrap-wakeword-dependencies.sh` may fetch the
pinned archives; it forecasts archive bytes, checks 1 GiB bootstrap headroom,
and refuses to continue below the 6 GiB free-space floor. Packaging verifies
the retained root and copies only the required model/token files and linked
native code.

The deterministic wake suite covers phrase bounds, atomic file replacement and
rollback, permission/device failure, one microphone owner, lifecycle races,
stale callbacks, one Live admission, one handoff, cleanup, and rearm. Human
microphone, permission, custom-phrase, and audible-audio checks remain
`LIVE_NOT_RUN`; no deterministic result implies those observations.

## GPT-Live deterministic check

Run the `MillerLiveTests` filter before the complete suite. The fake direct
wire/sideband and retained App Server tests exercise initialization, in-memory
credential admission, realtime lifecycle, failure fencing, process-group
termination, and cleanup without contacting a provider or touching Keychain,
browser, microphone, or audio devices.

```bash
./scripts/test.sh --filter MillerLiveTests
./scripts/test.sh --filter MillerLiveAudioTests
./scripts/test.sh --filter MillerAppTests
./scripts/run-gpt-live-app-server-check.sh --help
./scripts/package-dev-app.sh
./scripts/run-gpt-live-app-server-check.sh --harness-smoke \
  --harness "$PWD/.artifacts/Miller.app/Contents/MacOS/Miller"
./scripts/run-gpt-live-app-server-check.sh --synthetic-webrtc
./scripts/run-gpt-live-app-server-check.sh --dry-run \
  --helper "$HOME/.npm-global/bin/codex" \
  --harness "$PWD/.artifacts/Miller.app/Contents/MacOS/Miller"
```

Dry-run resolves the supplied launcher to its native executable, verifies the
arm64 architecture and OpenAI Developer ID identity, checks the recognized
development harness and free-space prerequisite, and runs only the local
`codex --version` command. It makes no model request and reads no credential.
A compatible harness must advertise the exact
`MillerGPTLiveHarnessCapability` value `miller-gpt-live-webrtc-harness-v1` in its
Info.plist. `package-dev-app.sh` injects this marker only into its ad-hoc signed
development app. The source plist remains an ordinary text-only app plist.

`run-gpt-live-app-server-check.sh` prepares an owner-installed official Codex
App Server WebRTC v3 route for qualification. Miller does not install, update,
or remove that external runtime. The direct comparator is exercised by the
deterministic `MillerLiveTests`, `MillerLiveAudioTests`, and `MillerAppTests`
fakes; no non-live script mode contacts the provider or runs the human gate.

`--harness-smoke` launches the packaged app without a helper path. The app exits
before credential, helper, microphone, or audio initialization. `--test-cleanup`
exercises the same early-exit cleanup boundary. `--synthetic-webrtc` runs the
deterministic live-audio and app tests with fakes only; it does not create a
WebKit view, use a network, request a permission, or touch media hardware.
The external-runtime dry run reports
`EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN`; the other successful non-live
modes report `WEBRTC_HARNESS_READY_LIVE_NOT_RUN`.
Delegated checks must not run `--live`. The final headless result is
`HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN`; it is not publication approval.
