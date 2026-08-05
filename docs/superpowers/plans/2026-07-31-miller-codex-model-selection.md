# Miller Codex Model Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gpt-5.6-terra` Miller's gateway-owned Codex default while offering packaged and advanced custom model selection in Settings.

**Architecture:** The local gateway owns Codex model descriptors and exposes a closed-schema catalog exchange. Swift obtains the default and choices through that exchange, persists only the selected ID in the existing profile, migrates only legacy `gpt-5`, and never touches the profile's Keychain credential when the model changes.

**Tech Stack:** Swift 6.1, SwiftUI/AppKit, SQLite, Node.js 22 ESM, Miller JSONL protocol, Pi A2 overlay.

**Execution constraint:** Work directly in the current repository on `main`. Do not create a worktree, branch, commit, stage, reset, or modify generated vendor artifacts. Use `apply_patch` for edits. The Luna worker must not delegate.

---

## File map

- `Gateway/src/codex-models.mjs`: Miller-owned packaged/default/custom Codex descriptor resolution.
- `Gateway/src/providers.mjs`: use the resolver for readiness and streaming.
- `Gateway/src/server.mjs`: serve the credential-free local model catalog.
- `Gateway/src/strict-json.mjs`: validate the new closed-schema records.
- `Gateway/src/fake-helper.mjs`: support the catalog exchange used by native tests.
- `Gateway/protocol/v1/records.schema.json`: normative protocol schema.
- `Gateway/tests/protocol.test.mjs`: record and sequence validation.
- `Gateway/tests/loopback.test.mjs`: production-helper catalog and custom-resolution behavior.
- `Sources/MillerGateway/GatewayRecord.swift`: Swift record schemas and catalog value types.
- `Sources/MillerGateway/GatewaySupervisor.swift`: idle-only catalog control request.
- `Tests/MillerGatewayTests/ProtocolFixtureTests.swift`: Swift protocol validation.
- `Tests/MillerGatewayTests/GatewaySupervisorTests.swift`: supervisor catalog exchange.
- `Sources/MillerApp/Security/GatewayCredentialHelper.swift`: app-facing catalog bridge.
- `Sources/MillerApp/AppCoordinator.swift`: snapshot data, profile creation/migration, and guarded model persistence.
- `Sources/MillerApp/Presentation/SettingsView.swift`: packaged picker and advanced custom field.
- `Tests/MillerAppTests/CodexProfileTests.swift`: new-profile and legacy-profile regression coverage.
- `Tests/MillerAppTests/PresentationTests.swift`: UI-model selection and active-turn guard coverage.
- `docs/qualification/provider-check.md`: model-selection expectations for the live gate.

### Task 1: Gateway model catalog and resolver

- [ ] **Step 1: Add failing gateway tests**

Add tests proving that the catalog default is `gpt-5.6-terra`, packaged IDs are exactly `gpt-5.6-terra` and `gpt-5.4`, both resolve to Codex descriptors, a valid custom ID resolves without changing the packaged catalog, and invalid IDs such as whitespace, `bad model`, and 201-character values are rejected as `configuration_invalid`.

Add protocol tests for:

```json
{"type":"provider.models","provider_kind":"codex_oauth"}
```

and a result with closed fields:

```json
{
  "type":"provider.models_result",
  "provider_kind":"codex_oauth",
  "default_model":"gpt-5.6-terra",
  "models":[
    {"id":"gpt-5.6-terra","name":"GPT-5.6 Terra"},
    {"id":"gpt-5.4","name":"GPT-5.4"}
  ]
}
```

- [ ] **Step 2: Run the gateway tests and verify RED**

Run:

```bash
node --test Gateway/tests/protocol.test.mjs Gateway/tests/loopback.test.mjs
```

Expected: failure because the new records and resolver do not exist.

- [ ] **Step 3: Implement the minimal gateway model authority**

Create `Gateway/src/codex-models.mjs` with:

```js
export const defaultCodexModelID = "gpt-5.6-terra";
const validModelID = /^[A-Za-z0-9._:/-]+$/;
const packaged = Object.freeze([
  Object.freeze({ id: defaultCodexModelID, name: "GPT-5.6 Terra" }),
  Object.freeze({ id: "gpt-5.4", name: "GPT-5.4" }),
]);

function normalize(rawID) {
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id || id.length > 200 || !validModelID.test(id)) {
    throw new Error("configuration_invalid");
  }
  return id;
}

export function codexModelCatalog() {
  return { defaultModel: defaultCodexModelID, models: packaged };
}

export function isPackagedCodexModel(rawID) {
  const id = normalize(rawID);
  return packaged.some((model) => model.id === id);
}

export function resolveCodexModel(provider, rawID) {
  const id = normalize(rawID);
  const upstream = provider.getModels().find((model) => model.id === id);
  if (upstream) return upstream;
  const template = provider.getModels().find((model) => model.id === "gpt-5.4");
  if (!template) throw new Error("provider_unavailable");
  const packagedName = packaged.find((model) => model.id === id)?.name;
  return {
    ...template,
    id,
    name: packagedName ?? id,
    input: ["text"],
    contextWindow: 128_000,
    maxTokens: 16_384,
  };
}
```

Validation must trim the input and accept at most 200 characters matching
`^[A-Za-z0-9._:/-]+$`. Reuse Pi's exact `gpt-5.4` descriptor. Build the
Miller-owned Terra descriptor from the same Codex API/base compatibility shape,
with its own ID/name and conservative text-only limits. For other valid IDs,
return a new descriptor without mutating either packaged descriptor.

Update `Gateway/src/providers.mjs` so Codex readiness accepts structurally
valid packaged or custom models, and `streamCodex` resolves through this module.
Update `Gateway/src/server.mjs` to return the catalog only while idle. Extend
the JS validator, JSON Schema, and fake helper with the two records.

- [ ] **Step 4: Run focused gateway tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass with no provider
request, OAuth interaction, or credential access.

### Task 2: Swift protocol and helper bridge

- [ ] **Step 1: Add failing Swift protocol/supervisor tests**

Define expected public values:

```swift
public struct GatewayModelChoice: Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct GatewayModelCatalog: Equatable, Sendable {
    public let providerKind: String
    public let defaultModel: String
    public let models: [GatewayModelChoice]
}
```

Tests must reject unknown fields and malformed model entries, and prove that
`GatewaySupervisor.codexModelCatalog()` decodes the fake helper's result.

- [ ] **Step 2: Run focused Swift tests and verify RED**

Run:

```bash
swift test --filter 'ProtocolFixtureTests|GatewaySupervisorTests'
```

Expected: failure because the record schemas and supervisor method are absent.

- [ ] **Step 3: Implement the bridge**

Add `provider.models` and `provider.models_result` to `GatewayRecord` using the
existing object-array field validation. Add a `models` control kind and an
idle-only supervisor method that sends `provider_kind: codex_oauth`, accepts
only one matching result, validates that the default appears exactly once in
the choices, and returns `GatewayModelCatalog`.

Add this app-facing method:

```swift
func codexModelCatalog() async throws -> GatewayModelCatalog {
    try await supervisor.codexModelCatalog()
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

### Task 3: Profile migration, persistence, and Settings

- [ ] **Step 1: Replace the current failing profile test with the approved default**

Keep the existing real `AppCoordinator` regression setup, but assert that a
new login attempt persists the gateway-reported `gpt-5.6-terra` default.

Add a legacy fixture using:

```swift
let legacy = try ProviderProfile(
    id: profileID,
    kind: .codexOAuth,
    label: "Codex OAuth",
    baseURL: nil,
    model: "gpt-5",
    credentialReference: credentialReference,
    isSelected: true,
    createdAt: createdAt
)
```

After login preparation, assert model `gpt-5.6-terra` and unchanged profile ID,
credential reference, label, selection, and creation date. Add another fixture
showing that an intentional custom ID is preserved.

Add presentation tests proving packaged/custom selection calls the dependency
with the exact model ID and that an active turn refuses the mutation.

- [ ] **Step 2: Run focused app tests and verify RED**

Run:

```bash
swift test --filter 'CodexProfileTests|PresentationTests'
```

Expected: failure because the app still hard-codes `gpt-5` and has no Codex
model mutation dependency.

- [ ] **Step 3: Implement profile and presentation behavior**

Extend the provider snapshot with packaged model choices and the default. Add a
single `saveCodexModel(String)` dependency and presentation method guarded by
`isActiveTurn`. The controller must rebuild only the selected Codex profile,
preserving identity fields and saving through the existing repository. It must
not call any `CredentialStore` method.

Before a new login, obtain the gateway catalog. Create a new profile using its
default. If an existing profile's model is exactly `gpt-5`, save the same
profile with only the gateway default substituted. Preserve every other model
as an intentional custom ID.

In `SettingsView`, show a Picker for packaged choices. Add a collapsed Advanced
disclosure containing a `TextField("Custom Codex model ID", ...)` and an
explicit `Button("Use custom model")`. Disable both during an active turn.
Display custom readiness wording without sending a provider request.

- [ ] **Step 4: Run focused app tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

### Task 4: Integrated verification and qualification preparation

- [ ] **Step 1: Update the human gate**

Amend `docs/qualification/provider-check.md` so the operator confirms the
default is `gpt-5.6-terra`, packaged/custom selection is visible, and the chosen
model survives relaunch. Do not mark the live result PASS.

- [ ] **Step 2: Run complete automated verification**

Run:

```bash
swift test
npm --prefix Gateway test
./scripts/verify-protocol.sh
./scripts/verify-provenance.sh
./scripts/verify-package.sh
./scripts/verify-runtime-inventory.sh
./scripts/run-codex-oauth-check.sh --validate
./scripts/run-codex-oauth-check.sh --dry-run
```

Expected: every command passes without live provider or OAuth activity.

- [ ] **Step 3: Inspect scope and cleanup**

Confirm the Pi-derived archive and generated vendor manifests are unchanged.
Inspect only the declared source/test/doc paths. Then run:

```bash
./scripts/clean.sh
./scripts/clean.sh --dependencies
```

Confirm `.build`, `.cache`, `.artifacts`, and `Gateway/node_modules` are absent
and no Miller/helper process remains. Do not commit or stage changes.

- [ ] **Step 4: Parent-only live gate**

The parent agent reruns `./scripts/run-codex-oauth-check.sh --interactive
--confirm-live`, coordinates Safari and the human-only conversation checks,
records only PASS/FAIL, updates the qualification record only from observed
evidence, and performs the supported cleanup again.
