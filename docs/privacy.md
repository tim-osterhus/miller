# Miller privacy boundary

The v0.1.1 external Codex boundary tested by Task 18 is official Codex CLI/App
Server `0.146.0` on Apple Silicon. `0.145.0` is protocol reference/evidence
only, not a runtime support claim. Codex remains an external prerequisite.

Miller keeps durable conversation content and provider-profile metadata in
local SQLite:

```text
~/Library/Application Support/ai.millrace.miller/miller.sqlite3
```

The database is not encrypted by Miller at the application layer. FileVault
may protect the volume, while backups, snapshots, and storage hardware may
retain prior bytes. Deleting a conversation or resetting Miller is not a
secure-erasure claim.

Provider secrets are not stored in SQLite. Tokens and API keys belong to the
macOS Keychain service `ai.millrace.miller.credentials`. The helper receives
them only through its inherited pipe and keeps them in process memory.

Before a remote provider request, Miller selects the current request and
bounded context from local history. The context contains complete pairs from
at most 20 completed turns and 32,000 Unicode scalar values. Miller sends that
text to the selected provider. Stopped and failed turns are not included.

Ordinary Miller launches have no active microphone or audio path. The qualified
Codex App Server WebRTC v3 route requests microphone permission only after
`Start Live Voice`, supplies the selected Codex OAuth credential to the
validated external Codex App Server in memory, and sends microphone and remote
audio through a system WebKit
WebRTC peer. It does not retain audio, write a content log, or duplicate
sideband audio into AVFoundation playback. Miller maps provider failures to
Miller-authored codes. The direct `/v1/live` route remains an experimental
comparator.

The deterministic GPT-Live adapter accepts an already-admitted Codex OAuth
credential in memory. For the direct route, the access token and account ID
enter only the bounded `/v1/live` request and sideband headers; for the
production App Server route, they enter only the child process's in-memory
pipe. Neither
may enter arguments, environment, SQLite, logs, diagnostics, or retained
qualification evidence. Synthetic transcripts and synthetic SDP values exist
only inside deterministic tests and are removed during cleanup. Live
transcripts remain bounded presentation state and do not enter SQLite. SDP,
audio, credentials, account identifiers, and provider payloads are neither
logged nor retained. No real credential, transcript, microphone, audio device,
or provider network is used for headless qualification.

Account lifecycle notifications are validated only to advance the
bounded startup phase; Miller retains or logs none of their account, plan, or
login fields. Raw `thread/realtime/itemAdded` values are validated for their
exact envelope and helper thread, then discarded immediately. Only admitted,
bounded live-session events can enter the returned result.

See `removal.md` before deleting the app when local-data removal is desired.

## Voice, selection, and history review

Live Voice is opt-in and begins only after the owner chooses Start Live Voice.
The microphone track and remote WebRTC track are session media; Miller does
not save either audio stream. Live transcript text is selectable presentation
text. Copying or selecting text does not copy or retain audio.

Saving a typed or reviewed transcript turn saves text and metadata only. It
does not imply that audio was saved. History is reviewed explicitly by opening
the history surface and selecting a conversation; a live session does not
silently create a second durable history. Export is an explicit owner action,
and exported text should be handled as user data.

Headless qualification uses synthetic fixtures and reports only pass/fail
status and bounded measurements. It does not use a real provider, microphone,
audio device, browser, clipboard, or owner account.
