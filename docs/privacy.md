# Miller privacy boundary

The v0.1.2 external Codex boundary tested by Task 18 is official Codex CLI/App
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
transcripts remain bounded presentation state until the owner explicitly saves
text to the selected conversation. Saved transcript text and metadata may enter
SQLite; SDP, audio, credentials, account identifiers, and provider payloads are neither
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
text. The owner may explicitly save a text turn to local history; copying or
selecting text does not copy or retain audio.

Saving a typed or reviewed transcript turn saves text and metadata only. It
does not imply that audio was saved. History is reviewed explicitly by opening
the history surface and selecting a conversation; a live session does not
silently create a second durable history. Export is an explicit owner action,
and exported text should be handled as user data.

Headless qualification uses synthetic fixtures and reports only pass/fail
status and bounded measurements. It does not use a real provider, microphone,
audio device, browser, clipboard, or owner account.

## Optional Avatar presentation

Avatar is off by default. When enabled, Miller stores owner-only profile
metadata under
`~/Library/Application Support/ai.millrace.miller/avatar/profiles-v2.json`.
The profile contains security-scoped bookmarks, SHA-256 digests, bounded
labels, bindings, and failure counters. Miller Avatar does not copy a selected
VRM or VRMA file into Application Support, the app bundle, a cache, or either
source repository. The original file remains user-owned.

Admitted model and motion bytes are served only to the local, ephemeral WebKit
renderer through a session-bound custom scheme. Its content-security policy is
network closed. No prompt, transcript, provider payload, tool result, account
secret, microphone sample, or remote audio enters Miller Avatar. Miller sends
only closed semantic phases, caller-owned identity values, presentation policy,
and a bounded scalar derived from audible remote output. The scalar is not an
audio recording.

The user is responsible for the rights to supplied model and motion files.
Removing a profile or motion removes Miller's bookmark and metadata but leaves
the original file untouched. See `removal.md` for complete local removal.

## Wake Listening

Wake Listening is off until the owner enables it. It reads the system-default
microphone only while enabled, performs detection locally with the verified
bundled model, and keeps PCM in a bounded in-process buffer. The buffer is
transferred once to the existing Live interaction after a match and is never
written to SQLite, Application Support, logs, diagnostics, or package
artifacts. The generated keyword file contains token IDs only, is owner-only
(`0700` directory and `0600` file), and is removed with wake preferences.
SQLite is the sole authority for the enabled flag and phrase.
