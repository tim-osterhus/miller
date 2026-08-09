# Troubleshoot Miller

## Live Voice is unavailable

Open Settings and confirm that a Codex OAuth profile is selected and reports
ready. The readiness message is specific: `Codex executable not found` means
discovery found no executable, `Codex executable rejected` means identity or
signature verification failed, `Local credential unavailable` means the local
credential is missing or invalidated, and `Authentication required` means the
App Server rejected the OAuth handshake. `Codex App Server unavailable` and
`Unsupported Codex App Server protocol` describe failures after an executable
was selected. Confirm that an official Apple Silicon Codex CLI is installed,
then use Miller's runtime chooser. Miller refuses unsigned, incorrectly
signed, non-arm64, or identity-mismatched executables.

If the message is `Readiness probe timed out`, the executable, App Server, and
authentication facts already established remain valid. The optional remote
provider/capability probe reached its 30-second ceiling; it is not evidence
that Codex is absent or protocol-incompatible. Retry the probe when the
provider or network is available. A provider error after successful local
initialization is shown as `Provider unavailable`, and ordinary typed use is
not poisoned by that optional probe.

If an external Codex update becomes protocol-incompatible, typed Miller remains
available. Do not replace Miller's identity checks or point it at an arbitrary
helper.

## Microphone access is denied

Allow Miller under **System Settings → Privacy & Security → Microphone**, then
start a new Live Voice session. Miller must not request camera access.

## A reasoning request fails

Check the selected profile, model identifier, endpoint, network, and provider
readiness. Retry only after the visible state becomes terminal. Stopping a turn
preserves visible partial text without adding it to future completed context.

## Storage or helper startup fails

Quit and reopen Miller. If the issue persists, use **Reset Miller** only after
reviewing `removal.md`; reset removes Miller-managed conversations and
credentials but never removes the external Codex installation.
