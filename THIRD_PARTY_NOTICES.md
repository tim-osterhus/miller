# Third-party notices

## Model Context Protocol Swift SDK 0.12.1

Miller locks the official Model Context Protocol Swift SDK from
`https://github.com/modelcontextprotocol/swift-sdk.git` at release `0.12.1`,
revision `a0ae212ebf6eab5f754c3129608bc5557637e605`.

The upstream project is transitioning from MIT to Apache-2.0. Contributions
are licensed under the applicable Apache-2.0 or MIT terms identified by the
upstream `LICENSE` file. In v0.1.1 the SDK is statically linked through the
Miller capability bridge; no SDK source tree is bundled. The exact reviewed
license text is packaged at
`Contents/Resources/Legal/mcp-swift-sdk-LICENSE.txt`.

## v0.1.1 application inventory

The application ships only the Miller executable, the statically linked MCP
Swift SDK and capability bridge, Node.js 22.22.0, the Pi overlay
`@miller/pi-mvp-overlay@0.82.0-a3`, `openai@6.26.0`, and
`partial-json@0.1.7`. The SPDX document and generated runtime inventory are
the authoritative v0.1.1 list.

Task 18 tested official Codex CLI/App Server `0.146.0` on Apple Silicon; that
is the v0.1.1 minimum tested/support boundary. `0.145.0` is protocol
reference/evidence only and is not a runtime support claim. Codex remains an
external prerequisite and is not included in this inventory.

From a clean checkout, packaging requires the explicit online
`./scripts/bootstrap-gateway-dependencies.sh` lockfile-integrity bootstrap.
It uses bounded npm timeouts and an isolated cache; packaging and headless
qualification do not invoke it implicitly.

## Optional wakeword build inputs (v0.1.2 source-only)

Miller's optional wakeword bootstrap fetches and verifies Sherpa-ONNX 1.13.2
and the Apache-2.0 GigaSpeech keyword model from the official releases, plus
ONNX Runtime 1.24.4 static libraries licensed under MIT. Exact source URLs and
approved hashes are recorded in `PROVENANCE.md`. These inputs are not
downloaded, compiled, packaged, or listed in the v0.1.1 application SBOM or
runtime inventory.

The archives, binaries, and model files are generated build inputs and are not
committed. The bootstrap deletes archives and extraction trees after retaining
the minimum verified arm64 inputs. Required upstream license files and notices
must accompany any distribution that includes those retained inputs.

The owner-authored Cortana donor commit is not third-party material. Its
file-level scope and immutable-source review are recorded in
`docs/qualification/wakeword-donor-audit.md` and `PROVENANCE.md`.

## Pi AI 0.82.0

Portions of `@miller/pi-mvp-overlay@0.82.0-a3` derive from
`@earendil-works/pi-ai@0.82.0` at commit
`083e61621276bff9f6faefab87ce07fcd98734e2`.

Copyright (c) 2025 Mario Zechner

Licensed under the MIT License. The exact license text is distributed at
`Gateway/vendor/LICENSES/pi-ai-0.82.0-MIT.txt`.

Miller changed the reviewed A1 distribution to harden the OpenAI Codex OAuth
callback, add bounded OpenAI-compatible tool-call conversion, and assign the
A3 derived-package identity. Streamed provider events, fragments, identities,
and partial argument assemblies are bounded before complete calls exist. The
exact changes and retained files are recorded
in `Gateway/vendor/source-map.json`.

## OpenAI JavaScript 6.26.0

The overlay depends on `openai@6.26.0`, licensed under the Apache License,
Version 2.0. The exact license text is distributed at
`Gateway/vendor/LICENSES/openai-6.26.0-Apache-2.0.txt`.

## partial-json 0.1.7

The overlay depends on `partial-json@0.1.7`.

Copyright (c) 2023 Promplate Dev Team

Licensed under the MIT License. The exact license text is distributed at
`Gateway/vendor/LICENSES/partial-json-0.1.7-MIT.txt`.

## Node.js 22.22.0

The Miller development and source-release application bundles include the
official Node.js 22.22.0 macOS arm64 executable.

Copyright Node.js contributors. All rights reserved.

Node.js is primarily licensed under the MIT License and incorporates
externally maintained libraries under the licenses reproduced in its
consolidated distribution license. The exact upstream file is distributed in
the application bundle at
`Contents/Resources/Gateway/runtime/LICENSE.node-22.22.0`.

## External OpenAI Codex prerequisite

Miller can use a separately installed official Codex CLI as its GPT-Live App
Server. Codex is not part of the Miller distribution: Miller does not copy,
bundle, build, download, update, remove, or redistribute that installation.
Its license and notices remain with the owner-installed Codex distribution.

## OpenClaw GPT-Live wire adaptation

Miller contains a modified adaptation of the bounded GPT-Live behavior from
OpenClaw PR [#115226](https://github.com/openclaw/openclaw/pull/115226), exact
donor commit `f78ba091207b33c3bb79f1bd9879d0e56be91a16`.

Reviewed donor files:

- `extensions/openai/realtime-quicksilver-wire.ts`
- `extensions/openai/realtime-quicksilver-wire.test.ts`
- `extensions/openai/realtime-quicksilver-sideband.ts`
- `extensions/openai/realtime-quicksilver-session.ts` (broker/lifecycle portions)
- `extensions/openai/realtime-quicksilver-session.test.ts`
- `extensions/openai/realtime-quicksilver-delegation.test.ts`

Copyright (c) 2026 OpenClaw Foundation

Miller's modified donor-derived files are marked in
`Sources/MillerLive/GPTLiveWire.swift`,
`Sources/MillerLive/GPTLiveSideband.swift`, and
`Sources/MillerLiveAudio/DirectGPTLiveSession.swift`. Miller adapted only the
direct `/v1/live` SDP multipart request, OAuth/account headers, bounded SDP and
event validation, sideband retry/buffering/teardown, lifecycle projection, and
injectable delegation seam. OpenClaw Gateway, Talk catalog, provider registry,
camera, CORS route, browser reservation store, and transcript database were not
copied. The implementation uses Miller's existing `WebKitLivePeer` and
Foundation system networking.

The full required MIT notice is:

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
