# Miller text-alpha architecture

This document describes the Miller v0.1.2 text and GPT-Live architecture,
including its external official Codex App Server WebRTC boundary. The completed
owner-visible Gate 4B result is recorded separately in
`docs/qualification/gate-4b-external-codex-human-report.md`.

Task 18 tested official Codex CLI/App Server `0.146.0` on Apple Silicon. This
is the v0.1.2 minimum tested/support boundary; `0.145.0` is protocol
reference/evidence only and is not a runtime support claim.

## Authority and process boundary

The native Swift application owns conversations, turns, context selection,
cancellation, visible state, provider-profile selection, credential
persistence, and durable storage. The Node helper is a supervised child
process. It owns provider authentication and streaming compatibility behind
Miller's closed JSONL protocol. It does not own conversation state or receive a
shell, filesystem, coding-agent, or model-callable tool.

Miller launches the helper directly, without a shell, using a fixed entry point,
a bounded environment, inherited standard input/output, and a Miller-managed
temporary directory. The app terminates and reaps the helper on shutdown,
restart, and reset. Protocol violations or unexpected exits cannot overwrite a
durable terminal turn.

## Storage and credentials

System SQLite stores conversation and provider-profile metadata at:

```text
~/Library/Application Support/ai.millrace.miller/miller.sqlite3
```

SQLite may also create `miller.sqlite3-wal` and `miller.sqlite3-shm`.
Conversation content is not encrypted by Miller at the application layer.
FileVault is the platform at-rest protection. APFS snapshots and backups may
retain prior bytes. Deletion is not a secure-erasure claim.

Credential material belongs only in the macOS Keychain generic-password
service `ai.millrace.miller.credentials`, keyed by a random credential-reference
UUID. SQLite stores that reference and non-secret provider metadata, never the
token or API key. The helper holds admitted credentials only in process memory.

## Provider context

For each request, Miller reconstructs bounded context from local SQLite
history. Miller sends the current user request and complete user/assistant
pairs from prior completed turns. The selection includes at most 20 turns and
32,000 Unicode scalar values. Failed and stopped turns are excluded. Provider
selection never grants tool authority.

## GPT-Live adapters

`MillerLive` is a separate Swift module. It does not depend on the Pi-derived
reasoning gateway, SQLite, AppKit, SwiftUI, WebKit, or an audio framework. It
owns the direct GPT-Live comparator and the external Codex App Server WebRTC
v3 boundary, each behind one bounded live-session lifecycle. Miller remains
authoritative for readiness, cancellation generations, visible lifecycle, and
durable typed history.

### Experimental direct GPT-Live comparator

The direct comparator uses the selected Miller Codex OAuth credential directly. It
POSTs the WebKit offer to `https://api.openai.com/v1/live` as bounded multipart
`sdp` and `session` fields, sends the donor-required OAuth/account/session
headers, validates a successful `2xx` SDP answer and call ID, then joins
`wss://api.openai.com/v1/live/<call-id>` with the same bounded headers. The
model defaults to `gpt-live-1-codex` and the voice defaults to the admitted
Miller voice configuration seam. The direct sideband projects only the MVP
startup/expiry, transcript, completion, error/close, and client-delegation
events; unknown events are bounded and ignored.

The existing `WebKitLivePeer` remains the browser-owned WebRTC media plane:
its local track is microphone input, its remote track is the sole audible
output, and its mute operation toggles the local track. Direct sideband text
never becomes AVFoundation audio. The direct route keeps Miller's session
identity, generation fencing, one-session admission, cancellation, cleanup,
interrupt/end, and fresh-peer protections. Client delegation has an injectable
consultation seam and a fixed spoken unsupported outcome when production
reasoning cannot be safely wired without a second conversation owner.

### Production Codex App Server WebRTC v3 route

The adapter resolves a separately installed official Codex CLI from an explicit
development override, an owner-saved choice, or bounded automatic discovery.
It resolves npm launchers to the platform-native executable and launches that
binary without a shell. It creates
private `HOME`, `CODEX_HOME`, and `TMPDIR` roots, writes only the fixed,
non-secret feature enablement and `[realtime] version = "v1"` compatibility
selection to a
mode-0600 task-private `CODEX_HOME/config.toml`, admits only the reviewed fixed
environment, fences responses and notifications to the active request, helper
thread, process/run, and generation, and terminates the helper process group on
terminal close, stop, timeout, cancellation, crash, or owner release. Process
group creation occurs atomically at spawn; per-event and cumulative transcript,
audio, retained-string, frame, and event limits apply before an event is
admitted. The helper output stream has a fixed eight-frame buffer; overflow is
a protocol/process failure that terminates the process group rather than
accumulating unbounded memory.
Session admission is atomic: a second concurrent start is refused without
mutating the admitted session, while a later sequential session may explicitly
acquire a fresh admission after the prior terminal state has remained visible.
A generation-matched stop anywhere in `starting`—including after helper thread
creation and while the realtime response or started notification is pending—
records one local closed outcome and cancels the helper immediately. Miller
sends `thread/realtime/stop` only after the matching started notification has
made the session active; stale stops cannot alter the admitted session.

The reviewed upstream protocol marks `thread/realtime/*` experimental and
requires `experimentalApi: true` at initialization. Its unstable
`chatgptAuthTokens` login accepts host-supplied access and account values in
memory and requests refresh from the host. Miller's bridge implements only
that exact protocol. It does not add another login store or place credentials
in process arguments, environment variables, diagnostics, or `CODEX_HOME`.
Refresh is host-mediated: Miller obtains a replacement credential from its
credential owner, verifies that the account remains fenced, and never replays
the rejected credential.

Before realtime start, the adapter creates one ephemeral App Server thread
with approvals disabled and a read-only sandbox. The returned helper thread ID
is transient and separate from Miller's durable conversation/thread identity;
only that returned ID is sent to and accepted from `thread/realtime/*`.
Miller explicitly requests WebRTC `version: "v3"` and sends
`realtimeSessionId: null`; Codex may return its own optional
continuation ID in `thread/realtime/started`, which Miller validates as nullable
and bounded but neither persists nor correlates with a local identity. Helper thread ID,
process instance, and run generation provide the fencing instead.
The isolated configuration retains upstream's V1 compatibility selection, but
the start request must explicitly select WebRTC v3. The helper's correlated
`thread/realtime/started` notification must confirm v3; other negotiated
versions are rejected.
The reviewed Codex protocol exposes no source-proven `clientManagedHandoffs`
field, so Miller
does not invent or send one. The spike sends no turn request and grants no
tools.

The decoder requires the complete reviewed experimental thread-start
response and nested thread shape. This includes `runtimeWorkspaceRoots`,
`multiAgentMode: explicitRequestOnly`, the nullable active permission profile
(exactly bounded `id` plus nullable `extends` when present),
and the thread's parent/recency plus experimental extra/history/direct-input
fields; the later `permissionProfile` field is rejected as unknown. Startup
waits correlate and retain one valid response while strictly consuming only
the exact legal `account/login/completed`, `account/updated`, and
`thread/started` notifications in their legal phases. A response may legally
precede its required notifications; duplicates and wrong correlations fail.
During realtime, `thread/realtime/itemAdded` is shape-checked and thread-fenced,
then its raw item is discarded. Transcript roles are limited to `user` and
`assistant`. No account-notification or item payload is retained or logged.

Complete input frames are serialized with input close and reaping under one
transport lock, including frames larger than `PIPE_BUF`. The pipe uses macOS
descriptor-local `F_SETNOSIGPIPE`; Miller does not change process-wide SIGPIPE
behavior.

## GPT-Live development harness

`MillerLiveAudio` owns a small transport-neutral peer boundary. The direct
Codex OAuth route creates a real audio-only WebRTC offer in a system WebKit
view, sends it as multipart `sdp` plus `session` to OpenAI `/v1/live`, joins
the call's sideband WebSocket, and reaches Listening only after WebKit reports
the peer connected and the direct session has started.

The App Server WebRTC v3 route normally uses the saved or automatically
discovered external Codex runtime. The
`--gpt-live-app-server <absolute-helper-path>` argument remains a development
override. The route sends the offer as
`transport: {"type":"webrtc","sdp":"<offer>"}` to Codex App Server and
receives its bounded SDP answer through
`thread/realtime/sdp`, and requires `thread/realtime/started`. Evidence from
that route does not prove the direct `/v1/live` route, and direct-route
behavior does not qualify App Server WebRTC v3.

The concrete `WebKitLivePeer` stays in `MillerApp`, not `MillerLive`. It loads
only Miller-authored HTML at `https://miller.invalid/` in an ephemeral WebKit
store. That page has one audio-only `RTCPeerConnection`, one microphone track,
one remote audio sink, and one `oai-events` data channel. It has no remote
scripts, subresources, navigation, forms, popup handling, or general script
message bridge. Its noninteractive view is attached to Miller's existing
overlay while a call connects or remains active; hiding that overlay first
would risk WebKit suspending media capture.

WebRTC is the sole primary media plane: the local track implements Mute and
the remote WebRTC track supplies audible output exactly once. Direct GPT-Live
sideband events are the authority for direct lifecycle, transcripts, errors,
and client delegation. The retained App Server sideband is the authority only
for the explicit AVAS fallback. Neither sideband may enqueue audio for
AVFoundation playback. End Live Voice, Interrupt, Escape, the status-item
toggle, and window close first close the WebRTC peer and whichever transport
was selected through the same bounded cleanup path, then may hide the overlay.

The earlier AVFoundation PCM capture, playback, and `appendAudio` code remains
isolated non-default groundwork. It is not activated, qualified, or represented
as a fallback by the Codex OAuth WebRTC route.

The app configures no media peer, opens no WebKit view, contacts no provider,
and requests no microphone access during launch. Ordinary launches
remain text-only until the user starts Live Voice; selected-profile readiness
may be refreshed, while the OAuth credential is loaded only during start. If
no compatible external Codex runtime is found, Live Voice is unavailable and
typed operation remains usable. The App Server is never started before the
user starts Live Voice.
Development packaging injects
`MillerGPTLiveHarnessCapability = miller-gpt-live-webrtc-harness-v1` into the
packaged app only. The development bundle contains the reviewed pinned Node
runtime, but no Codex, Cortana, or third-party WebRTC binary.

Before the live controller can assess readiness or load a credential, the app
verifies an arm64-only Mach-O executable with identifier `codex`, OpenAI team
identifier `2DC432GLL2`, and a valid Developer ID chain. External updates may
change the version and CDHash, so neither is pinned. Static verification is
repeated against the actual child PID directly after spawn and bound to the
exact selected canonical executable before any state publication or
JSON-RPC/credential write. A bounded retry is limited to an initially
unavailable kernel guest; identity or path mismatch
fails closed immediately, killing/reaping the child and removing its private
root. The external qualification script repeats the publisher, architecture,
and signing checks as a separate operator preflight; it does not replace
application enforcement.

### External Codex readiness lifecycle

Typed settings uses a local readiness operation separate from the optional
remote provider probe. The local operation starts a task-private App Server
child, sends `initialize`, completes the in-memory OAuth handshake, and then
terminates and reaps that child. It never starts a model turn merely to load
settings. Its typed result preserves executable verification,
initialization, and authentication evidence alongside a fixed state: missing
executable, rejected executable, unavailable local credential,
authentication required, App Server unavailable, unsupported protocol, remote
probe timeout, provider unavailable, cleanup pending, or ready. Cleanup has a
hard deadline. If the task-private root cannot be removed by that deadline,
readiness remains non-ready and Miller rejects reuse of that root until a later
cleanup retry succeeds.

The optional remote operation has a separate 30-second ceiling. It may run a
real typed turn and capability checks, but a timeout is reported as the fixed
owner-facing message `Readiness probe timed out` and retains all local facts
already established. Cancellation and timeout terminate only a child started
by that probe and remove its temporary root. A client that was already sharing
an external runtime is not stopped by an optional probe failure. Cleanup
notification is best-effort and cannot extend the hard deadline. Subsequent
ordinary typed use can start normally after probe cleanup.

Settings caches the cheap local result for the selected profile. Ordinary
Settings loads never run the remote operation. `Refresh Codex` and `Retry
helper readiness` each run one bounded remote/provider probe and cache its
result; credential mutations, login, refresh, logout, profile edits,
selection, deletion, and reset invalidate both caches. Provider failures and
remote timeouts therefore do not get projected as executable absence or
protocol incompatibility. The first ordinary typed use may still establish
model availability without erasing the local readiness evidence.

Live transcripts are bounded presentation state. Miller does not automatically
write them, audio, App Server identifiers, or provider payloads to SQLite. An
explicit owner save may persist transcript text and metadata in the selected
conversation; audio and provider/session payloads remain transient. Typed and
live operations are mutually exclusive. Typed interaction resumes after live
termination.

## Remaining Gate 4B exclusions

The deterministic GPT-Live harness does not establish owner-visible voice
behavior. Local speech and public distribution remain outside this packet.
Miller Avatar ships separately after v0.1 and is not a Miller package
dependency. Raw audio is not retained.

Later work retains:

- Local speech-to-text, local-neural text-to-speech, and macOS speech fallback.

- Device selection, additional echo cancellation, non-default routing, and
  audible-tail qualification.

- M1 startup, latency, memory, cache, and disk measurements.

- Final dependency, Node, model, voice, tokenizer, phonemizer, and bundled-asset
  provenance. Miller v0.1 distributes no avatar artwork or VRM asset.

- Stable release signing, notarization, and Keychain identity across upgrades.

- Clean-machine installation, upgrade, removal, and offline-capability tests.

- The release installer, post-v0.1 updater, and public distribution.

The final local-neural voice and numerical qualification profiles remain
unresolved. Miller Avatar, post-MVP providers, tools, channels, and Millrace
integrations remain outside Miller v0.1.

## Capability broker and trust

Miller has one native capability broker and one SQLite owner. An MCP server is
added through an explicit setup flow that displays its identity, endpoint
class, and declared tools before the owner enables it. The owner selects one
of three policies: read-only automatic, ask before changes, or fully trusted.
The broker classifies each call from the reviewed tool declaration and current
policy; unknown or changing calls are never silently upgraded. Policy
decisions, approvals, denials, and bounded results are audit events owned by
the broker.

The same broker is used by Codex typed turns, Codex Live sideband delegation,
and the Pi gateway. No provider may install or remove an account app. The
account-backed app surface is Codex-only, while provider adapters keep typed
reasoning portable across the supported Codex and OpenAI-compatible paths.

## Live Voice and history presentation

Live Voice is an explicit user action. Before Start Live Voice, Miller does
not request microphone access, create a media peer, or start the external
Codex runtime. After start, system WebKit owns one microphone track and one
remote WebRTC audio track. Stop, interrupt, mute, session failure, or external
runtime loss closes that bounded media session; typed operation remains
available when the live route is unavailable. Miller does not save microphone
or remote audio.

Live transcript text is presentation state and can be selected and copied by
the owner from the conversation surface. Selecting text does not export audio.
Saving a text turn stores text only. History review is explicit: Miller shows
the selected conversation and its saved turns only after the owner opens the
history surface; Live Voice does not silently append a second history model.

## External prerequisite and failure modes

Codex Live Voice requires an owner-installed official Codex App Server. Miller
does not download, bundle, update, or remove it. Missing or incompatible
external Codex, unavailable credentials, denied microphone permission,
unsupported model, network failure, provider refusal, malformed sideband data,
timeout, or helper exit produce a bounded unavailable or failed state. The
typed conversation, local history, and non-live provider routes remain
independent of those failures.

## Wake Listening

Wake Listening is composed through the MillerWake coordinator and the existing
HostDependencies.admitLive authority. It is disabled by default and uses the
system-default microphone through one AVAudioEngine owner at 16 kHz mono
Int16. The first valid phrase is Hey Miller; the owner may save one bounded
English phrase. SQLite wake preferences are the sole preference authority. The
custom-phrase and microphone observation gate is explicitly `LIVE_NOT_RUN` in
the v0.1.2 release closure.

After a match, the coordinator owns a bounded post-keyword PCM buffer. An empty
timeout rearms without opening Live. Silence or the hard limit transfers that
buffer once to the existing WebKit Live peer, then wake capture remains
suspended until provider, WebKit, transcript, and admission cleanup completes.
Manual Live suspends wake first. Disable, shutdown, sleep, inactive state,
device loss, and permission failure release capture and publish a truthful
state. No audio is persisted or logged.
