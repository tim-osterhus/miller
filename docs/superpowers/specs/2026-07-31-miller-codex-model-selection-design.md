# Miller Codex Model Selection Design

## Objective

Make Codex model selection explicit and configurable without moving provider
authority, credentials, or conversations out of Miller's existing boundaries.
`gpt-5.6-terra` is the initial default. Settings offers packaged models and an
advanced custom model ID. The obsolete pre-release `gpt-5` profile is migrated
without replacing its credential reference.

## Scope

This change covers Codex OAuth profiles only. It does not add thinking-level
controls, model discovery from the network, automatic provider requests during
readiness, or a general redesign of OpenAI-compatible profiles.

## Model authority

The gateway is the only authority for Codex model descriptors. A new bounded
model-catalog protocol exchange returns:

- the default model ID, `gpt-5.6-terra`;
- packaged model choices, initially `gpt-5.6-terra` and `gpt-5.4`; and
- the display metadata required by Settings.

Swift does not maintain a duplicate model list. Creating a Codex profile asks
the gateway for its default. Settings obtains its dropdown choices from the
same response. An automated contract test must prove that the returned default
resolves to a packaged gateway descriptor.

The Pi-derived vendor archive remains unchanged. Miller owns a small gateway
model resolver around the pinned Pi provider. It reuses the packaged Pi
descriptor when the selected ID exists upstream and provides a reviewed Codex
descriptor for Miller's additional packaged default. This avoids pulling in
Pi's coding-agent configuration subsystem or reopening the A2 provenance
closure.

## Custom models

Settings contains a normal packaged-model picker and an **Advanced custom model
ID** control. A custom value is trimmed and must be a nonempty model identifier
of at most 200 characters using letters, digits, `.`, `_`, `-`, `/`, or `:`.
It is stored in the existing SQLite provider profile and never in Keychain.

The gateway resolves a structurally valid custom ID with conservative Codex
metadata based on its reviewed text-only Codex descriptor. Local readiness can
validate authentication and configuration, but cannot prove that the user's
account is entitled to an arbitrary ID without spending a provider request.
Settings therefore reports:

- `Ready` for a packaged model;
- `Ready — custom model availability will be confirmed on first use` for a
  custom model; and
- `Selected model is unavailable for this account` if the provider rejects the
  model on an actual turn.

No prompt is sent merely to validate a custom model.

## Persistence and migration

Changing the Codex model preserves the profile ID, credential reference,
label, selection state, and creation time. It does not read, rewrite, refresh,
or delete the Keychain credential. Model changes are refused while a turn is
active, matching other provider mutations.

When Miller encounters the exact obsolete Codex model ID `gpt-5`, it replaces
only that value with the gateway-reported default. Other non-packaged IDs are
treated as intentional custom selections and are never silently migrated.

New Codex profiles use the gateway-reported default before OAuth begins. The
current live credential may remain in Keychain while the failed qualification
bundle is replaced; rerunning login may refresh or replace it through the
existing explicit OAuth flow.

## UI behavior

The Reasoning Provider section shows the selected Codex model beneath the
Codex profile. Selecting a packaged choice persists it immediately after the
standard active-turn guard. Advanced mode reveals a text field and an explicit
**Use custom model** action. Selecting a packaged choice again exits custom
mode without deleting or changing credentials.

The existing OpenAI-compatible profile editor remains unchanged.

## Protocol and failure handling

The gateway protocol adds a request/result pair for the Codex catalog. The
exchange is local, credential-free, and allowed only while the helper is idle.
Records remain closed-schema JSONL records and return no account or provider
data.

Reasoning resolves the selected ID immediately before streaming. Invalid IDs
are rejected as configuration errors. Provider model-not-found responses retain
the existing sanitized `unsupported_model` outcome; raw provider text and
identifiers remain forbidden from retained evidence.

## Verification

Automated coverage must prove:

- the gateway catalog contains and defaults to `gpt-5.6-terra`;
- every packaged choice resolves to a streamable Codex descriptor;
- custom IDs resolve without mutating the packaged catalog;
- invalid custom IDs are rejected locally;
- a new Codex profile uses the gateway default;
- the exact legacy `gpt-5` value migrates while identity and credential
  reference remain unchanged;
- intentional custom IDs are preserved;
- Settings can select packaged and custom models and refuses changes during an
  active turn;
- the Keychain credential is not rewritten by model selection; and
- the full Swift, gateway, packaging, provenance, inventory, and cleanup checks
  remain green.

After automated verification, rerun the live Codex OAuth qualification. The
human operator records only PASS or FAIL and must exercise readiness, refresh,
relaunch restore, a turn, a contextual follow-up, cancellation, and local
logout. Generated build, dependency, cache, and app artifacts are removed after
the gate.
