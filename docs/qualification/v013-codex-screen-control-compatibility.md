# Miller v0.1.3 Codex screen-control compatibility

Date: 2026-08-20

Status: `DONE_WITH_CONCERNS`

Computer Use result: `COMPUTER_USE_UNAVAILABLE_FOR_V013`

Image-input result: `QUALIFIED_LOCAL_IMAGE_INPUT`

## Qualification boundary

This record qualifies the external Codex App Server contract without starting
an ordinary Codex conversation, invoking Computer Use, controlling the
desktop, launching Miller, or retaining provider data. Installed, enabled, and
admitted runtime state was not probed and is recorded as `not_proven` rather
than inferred.

The recorded external runtime target is Codex CLI/App Server `0.146.0`.
App Server schemas are release-specific. The pinned v0.146.0 sources used for
this qualification are the [App Server v2 schema](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server-protocol/schema/json/codex_app_server_protocol.v2.schemas.json),
the [TurnStartParams schema](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server-protocol/schema/json/v2/TurnStartParams.json),
the [feature registry](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/features/src/lib.rs),
the [config protocol source](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server-protocol/src/protocol/v2/config.rs),
the [typed user-input source](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/protocol/src/user_input.rs),
and the [image handling source](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/utils/image/src/lib.rs).

The [Computer Use documentation](https://learn.chatgpt.com/docs/computer-use)
is unpinned contextual corroboration only. It is not authority for the v0.1.3
App Server contract; the pinned schema and source files are authoritative.

## Discovery and admission evidence

The pinned App Server does expose Computer Use-related configuration and
admission surfaces. Those signals are distinct from an actionable, bounded
Computer Use invocation API:

| Pinned surface | Evidence | What it proves | What it does not prove |
| --- | --- | --- | --- |
| `experimentalFeature/list` | Feature registry entry `computer_use` | A named feature exists in the provider registry | Account enablement, admission, action invocation, or action results |
| `configRequirements/read` | `requirements.computerUse` and `featureRequirements` fields | Configuration or policy requirements can describe admission | That the current runtime is admitted or exposes a bounded action method |
| `app/list`, `app/read`, `app/installed` | Generic account-app discovery and installed-app fields | Provider-managed app inventory surfaces | A first-party screen-control contract |
| `mcpServerStatus/list` | Generic MCP server, auth, and tool status | Generic MCP discovery | A Computer Use action route |
| `skills/list` | Generic skill discovery | Provider-managed skill inventory | A bounded desktop-control route |

The sanitized inventory fixture records the feature registry and
`configRequirements/read` surfaces, while keeping `enabled`, `admitted`, and
bounded invocation `not_proven`. Configuration or admission signals are not
promoted into a callable capability. The documented desktop-plugin surface is
contextual only and cannot substitute for a pinned App Server invocation
contract.

No ordinary turn was used as a substitute probe, and no second reasoning loop
was added.

## Computer Use invocation result

The pinned v0.146.0 App Server material did not prove a bounded Computer Use
action invocation or Computer Use-specific terminal reporting. Generic
`item/started`, `item/completed`, and turn status events do not identify a
Computer Use action and are not mapped to a synthetic phase vocabulary.

Miller therefore has no Computer Use phase protocol, decoder, or evidence
model. The sanitized finding is only:

```text
COMPUTER_USE_UNAVAILABLE_FOR_V013
```

Miller must not claim bounded screen control, synthesize a Computer Use
request, or call an ordinary Codex turn to reach a desktop plugin. A future
enablement requires fresh version-pinned evidence for discovery, admission,
bounded invocation, and terminal reporting.

## Image-input contract

The pinned [TurnStartParams schema](https://raw.githubusercontent.com/openai/codex/rust-v0.146.0/codex-rs/app-server-protocol/schema/json/v2/TurnStartParams.json)
defines `input` as a `UserInput` array. Its `localImage` variant requires a
string `path` and accepts optional `detail` values `auto`, `low`, `high`, and
`original`. The typed user-input source says that `LocalImage` is converted
to an image data URL during prompt serialization.

Miller emits this bounded local-image shape for one synthetic fixture image:

```json
{
  "type": "localImage",
  "path": "/fixture/v013/synthetic-image.png",
  "detail": "high"
}
```

The executable fixture test validates the pinned input shape and the exact
`turn/start` request produced by `CodexTypedProtocol`; it does not start an
ordinary turn or read an image file. The Miller Task 1 contract accepts exactly
one image and rejects two images with `tooManyItems`. That is a Miller bound,
not an upstream App Server limit.

The production encoder requires an absolute local path and rejects a relative
path. It does not currently identify or reject private paths, check file
existence, or impose a local-image file-size guarantee.

The upstream image source's 1 GiB guard applies to encoded and decoded
data-URL input handled by `load_data_url_for_prompt`; it is a decoded-input
sanity guard, not a `localImage` file-size guarantee. The 2048 dimension value
is used by the specific `ResizeToFit` mode. `Original` does not resize, and
`ResizeWithLimits` uses caller-provided limits. Neither value is a universal
App Server or local-file limit.

No actual image file, screenshot, provider request, or model response was
created or retained.

## Executable evidence and TDD record

The strict tests consume the three sanitized JSONL artifacts directly:

- `Tests/MillerLiveTests/Fixtures/v013-computer-use-inventory.jsonl` records the
  generic discovery, `computer_use` feature registry, and
  `configRequirements/read` admission signals.
- `Tests/MillerLiveTests/Fixtures/v013-computer-use-phases.jsonl` contains only
  the unavailable bounded-invocation finding; it contains no synthetic phase
  vocabulary.
- `Tests/MillerLiveTests/Fixtures/v013-image-input.jsonl` is validated against
  the pinned local-image request shape and corrected image-loader scope.

The focused suites finish GREEN with 13 capability tests and 14 typed protocol
tests. The recorded RED/GREEN repairs were:

1. The inventory test first failed because the feature registry and
   `configRequirements/read` records were absent, then passed after the
   sanitized fixture was corrected.
2. The phase-fixture test first failed on the ten synthetic phase records, then
   passed after the fixture was reduced to the single unavailable finding and
   the production phase protocol was removed.
3. The image fixture test first failed on the unqualified 1 GiB/2048 fields,
   then passed after the fixture and upstream-scope qualification were
   corrected.
4. The two-image test first failed to compile because the explicit Miller
   image-count contract was absent, then passed after the helper bound was
   named and used.

The artifacts contain only synthetic placeholders, pinned method and field
names, sanitized statuses, and explicit qualification outcomes. They do not
contain credentials, account identity, actual file contents, transcripts,
screenshots, provider payloads, or runtime logs.

## Remaining risk

The Computer Use desktop plugin may expose a future or separately documented
App Server route. The v0.1.3 implementation does not infer, enable, invoke, or
phase-map that surface.
