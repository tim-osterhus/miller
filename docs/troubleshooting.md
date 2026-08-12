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
that Codex is absent or protocol-incompatible. Ordinary Settings loads do not
run this probe. `Refresh Codex` or `Retry helper readiness` runs one bounded
probe and caches that result until the next credential or profile mutation.
A provider error after successful local
initialization is shown as `Provider unavailable`, and ordinary typed use is
not poisoned by that optional probe.

If the message is `Codex cleanup pending`, Miller stopped the child but could
not remove its task-private root before the cleanup deadline. Do not retry the
same helper immediately; Miller rejects unsafe root reuse. Restore access to
the parent directory and retry readiness so the pending cleanup can complete.

If an external Codex update becomes protocol-incompatible, typed Miller remains
available. Do not replace Miller's identity checks or point it at an arbitrary
helper.

## Microphone access is denied

Allow Miller under **System Settings → Privacy & Security → Microphone**, then
start a new Live Voice session. Miller must not request camera access.

## Wake Listening is unavailable

Wake Listening is off by default and uses the system-default microphone only.
In Settings → Voice → Wake Listening, enable it or choose Retry after fixing
the displayed state. `Waiting for microphone permission` requires allowing
Miller in System Settings. `Input device unavailable` means the system-default
input disappeared; reconnect it and retry. `Wake model unavailable` means the
verified local model is absent, so reinstall a package built after the explicit
wake bootstrap.

An invalid custom phrase does not replace the working phrase or keyword file.
Enter one bounded English phrase and save it again. Wake capture stops while
manual Live Voice is active and rearms only after provider, WebKit, transcript,
and admission cleanup. A sleep, device loss, or shutdown therefore shows a
paused/unavailable state instead of pretending that capture continues. Moving
focus away from Miller or closing Settings does not pause enabled wake
listening. The owner-visible microphone and custom-phrase check is
`LIVE_NOT_RUN` in the v0.1.2 release closure; deterministic tests do not prove
speech detection or the wake-only audible acknowledgement.

## A reasoning request fails

Check the selected profile, model identifier, endpoint, network, and provider
readiness. Retry only after the visible state becomes terminal. Stopping a turn
preserves visible partial text without adding it to future completed context.

## Storage or helper startup fails

Quit and reopen Miller. If the issue persists, use **Reset Miller** only after
reviewing `removal.md`; reset removes Miller-managed conversations and
credentials but never removes the external Codex installation.
