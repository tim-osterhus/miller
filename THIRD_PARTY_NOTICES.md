# Third-party notices

## Model Context Protocol Swift SDK 0.12.1

Miller locks the official Model Context Protocol Swift SDK from
`https://github.com/modelcontextprotocol/swift-sdk.git` at release `0.12.1`,
revision `a0ae212ebf6eab5f754c3129608bc5557637e605`.

The upstream project is transitioning from MIT to Apache-2.0. Contributions
are licensed under the applicable Apache-2.0 or MIT terms identified by the
upstream `LICENSE` file. In v0.1.2 the SDK is statically linked through the
Miller capability bridge; no SDK source tree is bundled. The exact reviewed
license text is packaged at
`Contents/Resources/Legal/mcp-swift-sdk-LICENSE.txt`.

## Miller Avatar v0.1.2 — Apache License 2.0

Miller links `MillerAvatarCore` and `MillerAvatarHost` from
`https://github.com/tim-osterhus/miller-avatar.git` at immutable commit
`932c66cc2e361f6132aba4ea1abc54ec1a57aa43`, published as version
`v0.1.2`. The package is
licensed under Apache-2.0. `MillerAvatarApp` is a diagnostic product and is
not linked or packaged by Miller.

Only the following fixed host resource files are distributed under
`Contents/Resources/MillerAvatar_MillerAvatarHost.bundle/Web/`:
`app.js`, `bundle-manifest.json`, `bundle-metafile.json`, `index.html`, and
`styles.css`. No VRM or VRMA character or motion assets are distributed.

Miller's optional Live Voice lip-sync classifier is an adapted, not copied,
pure behavioral core reviewed from the owner-controlled local VRM Studio donor
at commit `dc077143a2bc279f384cc4e2acaa86c459efb489`. The reviewed donor files
were `src/js/lip_sync_analysis.js`, `tests/lip_sync_analysis.test.js`, and
smoothing behavior from `src/js/vrm_audio.js`. The donor root source license is
MIT, copyright `(c) 2026 ZaberKo`. Its `package.json` declares ISC; that
metadata discrepancy is recorded in `PROVENANCE.md` and does not change the
source-code license. The exact reviewed MIT text is packaged at
`Contents/Resources/Legal/vrm-studio-2-LICENSE.txt`.

Only the pure played-output classifier behavior was adapted. Microphone
acquisition, runtime audio ownership, UI, providers, models, motions, and
media were excluded. Lip sync is Live Voice only, default On, uses bounded
five-vowel approximation with scalar/partial-model fallback, and does not
claim phoneme accuracy. Miller never sends raw audio or spectral data across
the Avatar bridge and never derives lip sync from the microphone.

Miller Avatar v0.1.2 also exposes an explicit per-import/per-profile High
Quality admission mode. Lightweight remains the default. High Quality uses
finite 2.5 GiB captured-file, buffer, and accessor ceilings, expanded finite
structural budgets, retained integrity/cancellation checks, and truthful
runtime allocation failures; it does not ship any model or motion asset.

## Three.js 0.180.0 — MIT License

Source: `https://github.com/mrdoob/three.js`, immutable tag `r180`.

Copyright © 2010-2025 three.js authors

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

## @pixiv/three-vrm core family 3.5.5 — MIT License

Package family anchor: `@pixiv/three-vrm 3.5.5`.

Source: `https://github.com/pixiv/three-vrm`, immutable commit
`ff42fae4fcee1fcbca2cd262c7f5f8cbddeaf5ab`.

The core family is licensed under MIT. It includes the emitted VRM 1.0,
MToon, expression, look-at, spring-bone, and node-constraint code. It does not
include any character or model asset.

Copyright © 2019-2026 pixiv Inc.

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

## @pixiv/three-vrm-animation 3.5.5 — MIT License

Source: `https://github.com/pixiv/three-vrm`, immutable commit
`ff42fae4fcee1fcbca2cd262c7f5f8cbddeaf5ab`. This package supplies VRMA 1.0
parsing and conversion code only; it does not supply motion bytes. Its
embedded core code is covered by the pixiv MIT notice above.

## Embedded Miller Avatar runtime notice

The following block is the exact tagged Miller Avatar runtime notice. It is
retained unchanged so the packaged standard notice contains the upstream
runtime license text at the path named by the upstream `NOTICE`.

# Third-party notices

The runtime bundle contains portions of Three.js, pixiv three-vrm, and
@pixiv/three-vrm-animation@3.5.5. Build tools are listed after the runtime
notices and are not distributed in the app.

## Three.js 0.180.0 — MIT License

Copyright © 2010-2025 three.js authors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## pixiv three-vrm 3.5.5 and @pixiv/three-vrm-animation 3.5.5 package families — MIT License

Copyright © 2019-2026 pixiv Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Mapbox Earcut 3.0.1 — ISC License

Copyright © 2016 Mapbox

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.

## Build-only tools

TypeScript 7.0.2 and its platform packages use the Apache License 2.0,
Copyright Microsoft Corporation. The package-supplied
`NOTICE.txt` governs the tool installation; neither TypeScript nor its notice
payload is emitted into Miller Avatar.

esbuild 0.28.1 and its platform packages are licensed under the MIT License,
Copyright © 2020 Evan Wallace. Neither esbuild nor its native executable is
emitted into Miller Avatar.

## v0.1.2 application inventory

The application ships the Miller executable with statically linked MCP and
wake native code, the verified wake model/token files under
`Contents/Resources/WakeWord/model`, the capability bridge, Node.js 22.22.0,
the Pi overlay `@miller/pi-mvp-overlay@0.82.0-a3`, `openai@6.26.0`, and
`partial-json@0.1.7`. The SPDX document and generated runtime inventory are
authoritative for the exact packaged files.

Task 18 tested official Codex CLI/App Server `0.146.0` on Apple Silicon; that
is the v0.1.2 minimum tested/support boundary. `0.145.0` is protocol
reference/evidence only and is not a runtime support claim. Codex remains an
external prerequisite and is not included in this inventory.

From a clean checkout, packaging requires the explicit online
`./scripts/bootstrap-gateway-dependencies.sh` lockfile-integrity bootstrap.
It uses bounded npm timeouts and an isolated cache; packaging and headless
qualification do not invoke it implicitly.

## Wakeword runtime

Miller's explicit wakeword bootstrap fetches and verifies Sherpa-ONNX 1.13.2
and its Apache-2.0 keyword model from the official releases, plus ONNX Runtime
1.24.4 static libraries licensed under MIT. Exact source URLs, sizes, and
approved hashes are recorded in `PROVENANCE.md`. Packaging verifies the
retained inputs and ships only the five required model/token files and linked
native code.

Archives, extraction trees, headers, compiler inputs, and private generated
keyword files are never shipped. The bootstrap deletes archives and extraction
trees after retaining the minimum verified arm64 inputs. The app materializes
one owner-only keyword file under Application Support only when wake listening
is enabled or a phrase is changed; it is not part of the package.

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
