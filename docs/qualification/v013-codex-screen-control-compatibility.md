# Miller v0.1.3 Codex screen-control compatibility

Date: 2026-08-20

Status: `DONE_WITH_CONCERNS`

Computer Use result: `COMPUTER_USE_UNAVAILABLE_FOR_V013`

Image-input result: `QUALIFIED_LOCAL_IMAGE_INPUT`

## Qualification boundary

This record qualifies the external Codex App Server contract without starting
an ordinary Codex conversation, invoking Computer Use, controlling the
desktop, launching Miller, or retaining provider data. The bounded worker had
no supported live App Server schema/capability connector exposed in its tool
surface, so installed/enabled/admitted runtime state is recorded as
`not_proven`, not inferred.

The repository's recorded external runtime target is Codex CLI/App Server
`0.146.0`. App Server schemas are release-specific; the pinned public
v0.146.0 sources used for this qualification are the
[App Server README](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server/README.md),
[App Server JSON schema](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server-protocol/schema/json/v2/ThreadStartResponse.json),
[typed user-input source](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/protocol/src/user_input.rs),
and [image handling source](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/utils/image/src/lib.rs).

The official [Computer Use documentation](https://learn.chatgpt.com/docs/computer-use)
describes a desktop plugin, a Computer-use MCP server, a Computer Use skill,
and platform permission/settings surfaces. It does not define a bounded
Computer Use invocation or typed six-phase App Server contract.

## Discovery contract

The pinned Miller capability probes expose the generic provider-managed
surfaces below:

| Surface | Request fields pinned by Miller | Computer Use conclusion |
| --- | --- | --- |
| `app/list` | `cursor`, `forceRefetch`, `limit`, `threadId` | Generic account-app discovery only |
| `app/read` | `appIds`, `includeTools` | Generic account-app tool details only |
| `app/installed` | `forceRefresh`, `threadId` | Generic installed-app state only |
| `mcpServerStatus/list` | `cursor`, `detail=toolsAndAuthOnly`, `limit`, `threadId` | Generic MCP state only |
| `skills/list` | `cwds`, `forceReload` | Generic skill discovery only |

No pinned App Server schema surface defines a first-party
`computerUse/*`, screen-control, action-invocation, or bounded Computer Use
request. The public desktop plugin surface cannot be promoted to an App
Server contract. The exact runtime fields `installed`, `enabled`, and
`admitted` therefore remain `not_proven` in the sanitized inventory fixture.

No ordinary turn was used as a substitute probe, and no second reasoning loop
was added.

## Invocation and phase result

The generic App Server lifecycle has `item/started` and `item/completed`
events, with generic item/turn statuses. Those events do not identify a
Computer Use action or distinguish the required vocabulary:

| Required phase | v0.146.0 bounded Computer Use event | Qualification result |
| --- | --- | --- |
| `notStarted` | No Computer Use event | Not observed |
| `started` | Generic `item/started` only | Not Computer Use-specific |
| `partial` | No Computer Use event | Not observed |
| `completed` | Generic `item/completed` only | Not Computer Use-specific |
| `timedOut` | No Computer Use event | Not observed |
| `uncertain` | No Computer Use event | Local unavailable fallback only |

`CodexComputerUsePhaseEvidence` accepts only the six pinned phase strings and
rejects unknown phases and unsupported fields. Every accepted record carries
`CodexComputerUseAvailability.unavailableForV013`, whose wire value is
`COMPUTER_USE_UNAVAILABLE_FOR_V013`. This is a sanitized qualification
representation; it is not a Computer Use invocation or an assertion that a
provider emitted those phases.

The resulting v0.1.3 decision is:

```text
COMPUTER_USE_UNAVAILABLE_FOR_V013
```

Miller must not claim bounded screen control, synthesize a Computer Use
request, or call an ordinary Codex turn to reach a desktop plugin.

## Image-input contract

The pinned App Server `turn/start` input union supports this exact local-image
shape for one synthetic fixture image:

```json
{
  "type": "localImage",
  "path": "/fixture/v013/synthetic-image.png",
  "detail": "high"
}
```

The `detail` field is optional and the supported values are `auto`, `low`,
`high`, and `original`. The `localImage` path is serialized by the upstream
user-input layer into the prompt's image media route. Inline `image` data URLs
are also part of the upstream union; remote HTTP(S) image URLs are rejected.
Miller emits the bounded local-image form only and admits one image in this
Task 1 contract.

The upstream image loader pins a decoded-input sanity guard of
`1,073,741,824` bytes and a `2,048` pixel maximum dimension before image
processing. The byte value is explicitly an upstream high sanity guard, not a
Miller upload quota or a claim that a local file was read. It is retained in
`CodexTypedProtocol.upstreamImageInputSanityLimitBytes` and in the sanitized
fixture so the external contract cannot silently drift.

The image route is qualified from the release-pinned schema/source evidence
and the local encoder test. No actual image file, screenshot, provider request,
or model response was created or retained.

## TDD evidence

The required one-test-at-a-time cycle was used for the two new contract
surfaces:

1. `CodexCapabilityProtocolTests.decodesPinnedComputerUsePhaseVocabularyAsUnavailableEvidence`
   first produced RED at compile time because
   `decodeComputerUsePhaseEvidence` and the unavailable phase contract did not
   exist. The minimum phase vocabulary, strict decoder, and explicit
   unavailable representation were then added. The focused suite finished
   GREEN with 12 tests.
2. `CodexTypedProtocolTests.encodesPinnedLocalImageInputRouteAndBound` first
   produced RED at compile time for the missing `images` argument, image input
   type, and upstream bound. The minimum `localImage` request encoding and
   one-image bound were then added. The focused suite finished GREEN with 12
   tests.

The phase test rejects an unknown phase (`providerFuturePhase`) and an
unsupported field. Existing typed protocol bounds continue to reject invalid
paths and oversized protocol content. No decoder accepts opaque provider
bodies, credentials, transcripts, screenshots, or private paths.

## Sanitized artifacts

The stable JSONL evidence is in:

- `Tests/MillerLiveTests/Fixtures/v013-computer-use-inventory.jsonl`
- `Tests/MillerLiveTests/Fixtures/v013-computer-use-phases.jsonl`
- `Tests/MillerLiveTests/Fixtures/v013-image-input.jsonl`

The artifacts contain only generic fixture placeholders, protocol method and
field names, synthetic statuses, and explicit qualification outcomes. They do
not contain OAuth tokens, credentials, account identity, actual file paths,
transcripts, screenshots, audio, provider payloads, or private logs.

## Remaining risk

The Computer Use desktop plugin may expose capabilities through a future
release or a separately documented App Server surface. Any future enablement
requires a fresh version-pinned schema qualification for discovery,
admission, bounded invocation, and all six phases. The v0.1.3 implementation
does not infer or enable that surface.
