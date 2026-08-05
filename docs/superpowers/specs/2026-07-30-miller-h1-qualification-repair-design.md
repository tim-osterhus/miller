# Miller H1 Qualification Repair Design

## Purpose

Repair only the development H1 qualification path so Miller's real visible
streaming and Stop behavior can be observed. Do not change the production
gateway, provider contracts, conversation ownership, or normal fake-helper
behavior.

## Confirmed Causes

The existing fake helper emits `reasoning.accepted`, one
`reasoning.text_delta`, and `reasoning.completed` synchronously. The native UI
therefore has no observable active interval in which Stop can be qualified.

The automated Tab result is inconclusive. Computer Use delivered ordinary Tab
between the conversation list and input, but its Escape and modifier-key
support was independently shown to be incomplete. Keyboard reachability must
return to `NOT_RUN` until a physical keyboard check resolves it.

## Selected Design

Add one explicit `qualification` mode to `Gateway/src/fake-helper.mjs`.

For each reasoning request, this mode:

1. emits `reasoning.accepted`;
2. emits ordinal-zero partial text immediately;
3. keeps the operation active for a bounded interval;
4. emits one later delta and then `reasoning.completed` if left alone;
5. cancels all pending timers and emits exactly one `reasoning.stopped` when
   Miller sends `reasoning.cancel`; and
6. admits no completion or late delta after cancellation.

`AppCoordinator` may append a fake-helper mode argument only when
`MILLER_FAKE_HELPER_MODE` is present. `run-host-check.sh` sets the value to
`qualification` for its disposable development launches. Ordinary launches
continue to invoke the helper with no mode argument and retain immediate
completion.

## Alternatives Not Selected

- Slowing every fake-helper turn would change ordinary development and test
  behavior merely to serve one manual gate.
- Mutating the packaged helper after assembly would make the tested bundle
  differ opaquely from the packaged source.
- Reusing `hang-on-cancel` would test the supervisor's timeout/restart path,
  not the normal Stop terminal outcome required by H1.

## Testing

Automated tests must prove:

- qualification mode exposes an active turn after its first delta;
- cancellation produces `reasoning.stopped`;
- no completion or late delta follows cancellation;
- an uncancelled qualification turn completes within a bounded time;
- the H1 runner passes only the qualification mode to its app launches; and
- normal mode remains unchanged.

Manual H1 then verifies the actual visible Stop control, partial-text
retention, relaunch persistence, physical keyboard traversal, VoiceOver,
menu-bar commands, the persisted configurable shortcut with
Command-Shift-Space as its default, and the synthetic Keychain probe.

## Boundaries

No real credential, provider request, browser flow, microphone, speech engine,
avatar, production packaging decision, or source-control operation enters this
repair.
