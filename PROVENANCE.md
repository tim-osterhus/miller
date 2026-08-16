# Provenance policy

Miller starts as a clean repository. It does not inherit source code, tests,
assets, or Git history from Cortana Assistant, VoiceInk, or any prospective
donor project.

## Contributions and borrowed work

Before third-party source or assets enter Miller, record:

- the upstream project and canonical source URL;
- the exact version, tag, or commit;
- the license and copyright notices;
- which files or assets were incorporated;
- whether the material was copied, adapted, or used only as a reference;
- the modifications made in Miller;
- relevant transitive dependencies and distribution requirements.

Preserve all notices required by the upstream license in
`THIRD_PARTY_NOTICES.md` or the applicable distributed artifact.

## GitHub Actions workflow dependency

The CI workflow uses one workflow-only dependency:

- Action: `actions/checkout`
- Release: `v4.2.2`
- Reviewed commit:
  `11bd71901bbe5b1630ceea73d27597364c9af683`
- Source:
  `https://github.com/actions/checkout/commit/11bd71901bbe5b1630ceea73d27597364c9af683`
- License: MIT
- Scope: `.github/workflows/ci.yml` only. Miller does not bundle or use the
  action at application runtime.

The workflow references the full commit SHA rather than a mutable tag.
`scripts/verify-provenance.sh` enforces the exact reference and rejects any
non-SHA `uses:` entry.

## Dependency and asset review

Review source code, transitive packages, downloaded or bundled binaries, model
weights, tokenizers, phonemizers, voice packs, wake-word models, fonts, audio,
artwork, and other shipped assets separately. A permissive repository license
does not establish that every dependency or model asset is safe to redistribute.

Miller must not incorporate copyleft, noncommercial, source-available,
field-of-use-restricted, or unknown-license source code or assets. External
provider compatibility does not authorize Miller to copy, modify, bundle, or
redistribute a provider's implementation or assets.

## Clean-room boundary

Cortana Assistant and VoiceInk may inform public behavioral requirements, but
their implementation must not be copied into Miller. Any independently
authored Cortana material proposed for reuse requires a file-level authorship
and provenance review before incorporation.

## Miller v0.1.2 capability and wakeword inputs

### Model Context Protocol Swift SDK

- Upstream: `https://github.com/modelcontextprotocol/swift-sdk.git`
- Release: `0.12.1`
- Resolved revision: `a0ae212ebf6eab5f754c3129608bc5557637e605`
- License: upstream mixed Apache-2.0/MIT transition terms recorded in the
  revision's `LICENSE` file.
- Current scope: statically linked capability-bridge dependency in the v0.1.2
  application. The app SBOM and runtime inventory list this component only at
  its reviewed version; no SDK source tree is copied into the application.

`Package.swift` pins the release exactly and `Package.resolved` records the
official repository, revision, and complete SwiftPM resolution. The Swift
capability broker consumes the SDK through the Miller bridge.

### Application boundary

The shipped application contains the Miller executable with linked Sherpa-ONNX
and ONNX Runtime wake code, five verified wake model/token files under
`Contents/Resources/WakeWord/model`, the capability bridge and MCP SDK, the
reviewed Node.js 22.22.0 runtime, the Pi-derived gateway overlay, and the
existing openai and partial-json gateway packages. Packaging/Miller.spdx.json
and the generated runtime inventory enumerate those components exactly.

Codex is an external prerequisite for Live Voice and is not bundled. Wake
archives, headers, compiler inputs, extraction roots, private generated
keyword files, donor test inputs, and audio are excluded from the application
payload.
Task 18 tested official Codex CLI/App Server `0.146.0` on Apple Silicon; this is
the v0.1.2 minimum tested/support boundary. The `0.145.0` material below is
protocol reference/evidence only and is not a runtime support claim.

## Miller Avatar v0.1.0-alpha.2

Miller links the public Miller Avatar package from
`https://github.com/tim-osterhus/miller-avatar.git` at the immutable tag
`v0.1.0-alpha.2`, resolved to commit
`6b34f9ff35a94cdde9c7826bc67f2cfff02abd82`. The package is distributed under
Apache-2.0. MillerApp links only `MillerAvatarCore` and `MillerAvatarHost`;
the diagnostic `MillerAvatarApp` product is neither linked nor packaged.

The fixed SwiftPM resource bundle is
`Contents/Resources/MillerAvatar_MillerAvatarHost.bundle`. Its complete Web
inventory is exactly:

- `Web/app.js`
- `Web/bundle-manifest.json`
- `Web/bundle-metafile.json`
- `Web/index.html`
- `Web/styles.css`

The resource closure is checked at the source checkout, build output, release
inventory, and release verifier boundaries. It contains no VRM or VRMA character or motion assets, model bytes, motion bytes, user profile, or
private fixture. Linking this package does not construct a profile store,
load a model, or activate a renderer while Avatar is disabled; those runtime
surfaces are outside this C2 package-only change.

The real packaged-app Avatar-Off launch test is deferred for this remediation
because the protected retained release boundary is occupied by the owner-
qualified release processes. No app-launching behavior test was added. The
deterministic production source contract and exact package, link, Web-byte, and
legal-inventory checks remain the C2 evidence.

### Avatar Web runtime dependencies

- `three@0.180.0`, MIT, from `https://github.com/mrdoob/three.js` at immutable
  tag `r180`.
- `@pixiv/three-vrm@3.5.5` core family, MIT, from
  `https://github.com/pixiv/three-vrm` at immutable commit
  `ff42fae4fcee1fcbca2cd262c7f5f8cbddeaf5ab`.
- `@pixiv/three-vrm-animation@3.5.5`, MIT, from the same immutable Pixiv
  commit. This package supplies parsing and conversion code only; it does not
  supply motion bytes.
- `Mapbox Earcut 3.0.1`, ISC, Copyright © 2016 Mapbox. Its emitted geometry
  code is embedded in `Web/app.js`; the complete ISC notice is retained in the
  pinned Avatar runtime notice and no Earcut asset is shipped.

The generated Web payload and its normalized bundle manifests are the only
renderer bytes admitted to Miller. Character, model, motion, texture, and
other user-selected assets remain runtime inputs and are not copied into the
repository or release application.

### Cortana wakeword donor

- Canonical donor repository: owner-controlled Cortana repository, reviewed at
  the immutable commit below.
- Approved donor commit: `8f4af867c575c089f45a8df4768663a521f88203`
- Ownership: owner-authored Cortana material.
- Imported scope: the nine bridge, detector, coordinator, frame accumulator,
  production-controller, and settings-controller files enumerated in
  `docs/qualification/wakeword-donor-audit.md`.

Every donor file was read only with `git show <commit>:<path>` at the approved
immutable commit. Miller recreated those files with narrow naming and host
boundary adaptations. The Cortana settings view, tests, probes, installed app,
and current working tree were not source donors. VoiceInk was neither inspected
nor used.

### Fetched-and-verified wakeword build inputs

`scripts/bootstrap-wakeword-dependencies.sh` fetches the exact
official archives into a bounded generated directory, verifies each archive
before extraction, stages only the required arm64 inputs, deletes the archives
and extraction trees, and verifies the retained bytes again.

Packaging verifies that retained root and copies only the five model/token
files into the app. Headers, static archives, compiler inputs, transient
archives, extraction roots, and private generated keyword files are never
packaged or committed.

- Sherpa-ONNX 1.13.2 static macOS XCFramework archive:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-macos-xcframework-static.tar.bz2`
  - Archive SHA-256:
    `8756afb64ef7a1d612040c323e6f2cf707f90e703395413c79c572e37eddd65e`
  - Exact archive size: `8,941,262` bytes.
  - Retained C API header SHA-256:
    `437b1279047877167d8fadc74a60d47f3df514d703fdac1c1b6851da9bc2fdb4`
  - Retained C++ API header SHA-256:
    `431170d7c34bf154761f0d151984a3b8973342444d4f93c7037ea7405313aede`
  - Retained linked library SHA-256:
    `cd6f73e84bb78d5041a085fb388f43d6c66107e6f12e97a39cda6c7ce534b8a6`
  - License: Apache-2.0.
- ONNX Runtime 1.24.4 arm64 static library archive:
  `https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.24.4/onnxruntime-osx-arm64-static_lib-1.24.4.zip`
  - Archive SHA-256:
    `4752fa848d9d36143e3942537ff71736d2e581ce192a528482f7edd8d02c9ebf`
  - Exact archive size: `17,358,514` bytes.
  - Retained linked library SHA-256:
    `9f3e92dd112cd39aa495aec55352f9daaac756c3879bc1b4b3586105c1e85e34`
  - License: MIT.
- Sherpa-ONNX GigaSpeech 3.3M keyword model, dated 2024-01-01:
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2`
  - Archive SHA-256:
    `f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a`
  - Exact archive size: `17,626,723` bytes.
  - Packaged encoder SHA-256:
    `1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678`
  - Packaged decoder SHA-256:
    `f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3`
  - Packaged joiner SHA-256:
    `eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c`
  - Packaged BPE SHA-256:
    `c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24`
  - Packaged tokens SHA-256:
    `fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53`
  - License: Apache-2.0.

## Codex App Server protocol reference

The `MillerLive` spike was independently authored from public Apache-2.0
OpenAI Codex protocol source at tag `rust-v0.145.0`, commit
`25af12f7e61572b0bc18ddb1008be543b91519b0`. Reviewed upstream evidence
includes the experimental `thread/realtime/*` declarations, the required
`experimentalApi` capability, the unstable in-memory `chatgptAuthTokens`
login, and the host token-refresh request.

No OpenAI Codex executable or source file is copied into Miller. GPT-Live uses
an owner-installed official Codex CLI as an external prerequisite. Miller
validates the executable's OpenAI Developer ID identity and architecture, but
does not download, bundle, update, remove, or redistribute it. Earlier Cortana
helper evidence is superseded and is not a production dependency. Miller does
not copy Cortana or VoiceInk code.

`MillerLiveAudio` and `WebKitLivePeer` are independently authored Miller code.
The concrete peer uses macOS system WebKit for the experimental WebRTC media
plane; it adds no downloaded, bundled, or third-party WebRTC implementation.
App Server notifications remain a separate control and transcript sideband.
The earlier Foundation/AVFoundation PCM types are retained only as isolated,
non-default groundwork and are not qualified for this route. The development
app does not bundle a Codex or Cortana helper, test audio, or a third-party
audio library.

## OpenClaw GPT-Live wire reference

Miller directly adapts the bounded GPT-Live behavior described by OpenClaw PR
[#115226](https://github.com/openclaw/openclaw/pull/115226), using the exact
permissive donor revision `f78ba091207b33c3bb79f1bd9879d0e56be91a16` from
OpenClaw. The donor license is MIT and the donor copyright is OpenClaw
Foundation, 2026.

The reviewed donor files are:

- `extensions/openai/realtime-quicksilver-wire.ts`
- `extensions/openai/realtime-quicksilver-wire.test.ts`
- `extensions/openai/realtime-quicksilver-sideband.ts`
- `extensions/openai/realtime-quicksilver-session.ts` (broker/lifecycle portions)
- `extensions/openai/realtime-quicksilver-session.test.ts`
- `extensions/openai/realtime-quicksilver-delegation.test.ts`

Miller did not copy the OpenClaw Gateway, Talk catalog, provider registry,
camera, CORS route, browser reservation store, or transcript database. The
modified donor-derived Miller files are clearly marked in
`Sources/MillerLive/GPTLiveWire.swift`,
`Sources/MillerLive/GPTLiveSideband.swift`, and
`Sources/MillerLiveAudio/DirectGPTLiveSession.swift`. The adaptation keeps
only the direct `/v1/live` multipart SDP exchange, OAuth/account headers,
bounded response and event parsing, sideband startup retry and early-frame
buffering, session lifecycle, and injectable client-delegation seam. It uses
Foundation `URLSession` and `URLSessionWebSocketTask`, Miller's existing
`WebKitLivePeer`, Miller identity/generation fencing, and no transcript
database or second conversation owner.

The full required donor MIT notice is:

```text
MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Third-party notices for incorporated or adapted code are recorded in
THIRD_PARTY_NOTICES.md.
```

## Millrace menu-bar mark

`Branding/MillraceMarkSource.png` is an internal, Millrace ecosystem-owned
source asset, not third-party material. It originates from the workspace's
historical branding asset and has SHA-256
`d75978e42d26bd6c1ed96f4831c73c73f2bc54fb04e7c39992cbdc85af77b241`.

`scripts/generate-menu-bar-icon.swift` deterministically produces the 72-by-72
black template resource from a 64-pixel optical box. The generator preserves
the scaled source alpha values and applies no optical dilation. Its output,
`Sources/MillerApp/Resources/MillerStatusIcon.png`, has SHA-256
`34be9cf271b2d7a5bfb1f11c459902c0167add683baa006cabbafe4fa4f6c6db`.

## Pi-derived A3 gateway overlay

Miller retains one reviewed Pi-derived distribution:
`@miller/pi-mvp-overlay@0.82.0-a3`.

### Upstream and A1 baseline

- Upstream: `https://github.com/earendil-works/pi.git`
- Upstream package: `packages/ai`, published as
  `@earendil-works/pi-ai@0.82.0`
- Upstream revision: `083e61621276bff9f6faefab87ce07fcd98734e2`
- Upstream package integrity:
  `sha512-8MvW9+zno13sXDuT2kFMnWeTNUufUhPeZDRVO+igGoBRCDWgn7Xh2FkRQI1mRuet6QhF4ENQuLYdIAOyG6BhNw==`
- Reviewed baseline: `@miller/pi-a1-overlay@0.82.0-a1`
- A1 manifest SHA-256:
  `902e14ffaa2548173f644c5935b8b0afe6673db9f3f8a8d3a5e5f832830e7f2b`

The sanitized, immutable A1 equivalent is tracked at
`Gateway/vendor/a1-manifest.json` (SHA-256
`7a91e3cf445e500bc93d015b91356bf6ee9dad5db48e06648a6164b5ddcbea8e`, 2,404
bytes). It retains the pinned commit, approved 53-file inventory/source-map
hashes, license facts, bounded transformations, and explicit exclusions,
including VoiceInk. It contains no host name, private path, owner data, or
external checkout dependency. `scripts/verify-provenance.sh` binds both the
sanitized manifest hash and the A3 vendor manifest hash.

The A1 manifest binds each retained module to the exact npm tarball and pinned
Git source-map content. The A3 generator refuses any A1 manifest or retained
file whose hash, byte count, or mode differs.

### A3 transformation

`Gateway/scripts/build-overlay.mjs` has SHA-256
`57d4fbf2d54b1fb691dae7b5516b515e22f7f0b209a0978a0534d898a03866a5`.
It changes exactly three overlay files:

- `dist/api/openai-completions.js`: admits bounded OpenAI-compatible tool
  definitions; bounds provider events, fragment indices and counts, call
  identities, and partial argument assemblies before complete calls exist;
  rejects missing, duplicate, conflicting, or malformed calls; and replays
  bounded tool results without adding runtime network access.

- `dist/auth/oauth/openai-codex.js`: admits only GET requests to
  `/auth/callback`, requires matching state, rejects a second callback, sends
  `Cache-Control: no-store` and `Referrer-Policy: no-referrer`, binds the
  listener to `127.0.0.1`, settles cancellation and a five-minute callback
  deadline before awaited listener close, removes `PI_OAUTH_CALLBACK_HOST`,
  and removes manual authorization-code input.
- `package.json`: changes only the derived package name and version to
  `@miller/pi-mvp-overlay@0.82.0-a3`.

All other retained files are byte-identical to the reviewed A1 distribution.
The exact 53-file archive inventory is
`Gateway/vendor/overlay-files.json`; the per-file A1-to-A3 provenance record is
`Gateway/vendor/source-map.json`. These generated documents are authoritative
for every retained file rather than a summarized path list in this prose.

### Distribution and dependency closure

The exact generated vendor artifacts are:

| Artifact | SHA-256 |
| --- | --- |
| `Gateway/vendor/manifest.json` | `6bf546c476d229d347948b95e801c07879a9e379f78f5b45260108158bebd1f5` |
| `Gateway/vendor/a1-manifest.json` | `7a91e3cf445e500bc93d015b91356bf6ee9dad5db48e06648a6164b5ddcbea8e` |
| `Gateway/vendor/pi-mvp-overlay-0.82.0-a3.tgz` | `e2f9275e5fc32d8db0530d40347961525d785d0229d723fbe29a9438b6316ab9` |
| `Gateway/vendor/development-bundle-inventory.json` | `556718fafe736ee3efa0ab6cb61f593c7316f8c5b38521b29167239333af80a9` |
| `Gateway/vendor/overlay-files.json` | `29e5fd59d8864844665cb63ab51b06479c810e61f2f5f0e6d21c0c63511647cd` |
| `Gateway/vendor/source-map.json` | `317ec2c88880404b6765cf27054c7f3a845ff7de784885ca2c5007d9e03bdbbc` |
| `Gateway/vendor/sbom.spdx.json` | `c4f87d60394a0859cd5e234cd8eb536d4f9d08f4ec530ecfafe61314d748ebc7` |

The runtime dependency closure contains only:

- `openai@6.26.0`, Apache-2.0,
  `sha512-zd23dbWTjiJ6sSAX6s0HrCZi41JwTA1bQVs0wLQPZ2/5o2gxOJA5wh7yOAUgwYybfhDXyhwlpeQf7Mlgx8EOCA==`;
- `partial-json@0.1.7`, MIT,
  `sha512-Njv/59hHaokb/hRUjce3Hdv12wd60MtM9Z5Olmn+nehe0QDAsRtRbJPvJ0Z91TusF0SuZRIvnM+S4l6EIP8leA==`.

The exact package lock SHA-256 is
`4696145d899809e8de806b742a96f14fb6c81c67d7a09f2ce7486ca55eb89e1f`.
The overlay contains no Pi coding-agent package, unrelated provider package,
callable shell or filesystem dependency, AWS SDK, Google SDK, Bedrock SDK,
native add-on, or install script.

`Gateway/vendor/development-bundle-inventory.json` is the reviewed commitment
to the complete bundled gateway dependency closure: the three admitted
roots, all 2,109 relative file paths, each file's SHA-256 and byte count, are
canonically represented by its inventory SHA-256. The package script rebuilds
the scripts-disabled lockfile closure offline, validates that commitment before
copying, and validates the assembled bundle's dependency tree again. The
verifier rejects changed or unlisted bytes, symlinks, and unexpected assembled
dependency roots.

`scripts/verify-provenance.sh` recalculates every retained vendor hash, rejects
missing and unlisted files, validates the exact package graph and integrities,
checks complete SPDX 2.3 metadata and hexadecimal SHA-512 checksums, and checks
the required license bytes without making a network request.

## Node.js 22.22.0 bundled runtime

The development and source-release bundles contain only the official Apple Silicon Node
executable required to run Miller's reviewed helper and the consolidated Node
license/third-party notice file:

- Release: Node.js `v22.22.0`
- Official artifact:
  `https://nodejs.org/dist/v22.22.0/node-v22.22.0-darwin-arm64.tar.gz`
- Artifact SHA-256:
  `5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640`
- Bundled `bin/node` SHA-256:
  `913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4`
- Bundled `LICENSE.node-22.22.0` SHA-256:
  `e991d81497a85bb24fc6bffae0a3637a6accd6c6bc5ce1f2c5698bd555cf9d49`
- Architecture: Mach-O arm64
- Runtime linkage: macOS system CoreFoundation and Security frameworks,
  `libc++.1.dylib`, and `libSystem.B.dylib` only

`scripts/package-dev-app.sh` and its release wrapper download this exact archive into a bounded
repository artifact staging root, verifies the archive before extraction,
extracts only `bin/node` and `LICENSE`, verifies their final bytes, copies them
to `Miller.app/Contents/Resources/Gateway/runtime/`, and removes the archive
and extraction root on every exit. npm, Corepack, headers, manuals, and other
archive files are not copied.

The bundled Node file has a narrowly reviewed exact-hash Node exception: the
SHA-256 above is the only allowed Node runtime hash, and its known upstream
build-path strings are attributable only to that exact official binary. The
exception does not apply to Miller binaries, JavaScript, legal files, or any
other hash; the final inventory and verifier reject private/build paths in all
other shipped files.
