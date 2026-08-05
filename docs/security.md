# Miller security boundary

## Credentials

Miller owns persistence. It stores versioned, bounded credential payloads as
generic-password items under Keychain service
`ai.millrace.miller.credentials`. Items use credential-reference UUID accounts,
`AfterFirstUnlockThisDeviceOnly` accessibility, no synchronization, and the
application's default access group. SQLite stores provider labels, endpoints,
models, and credential references. SQLite does not store secrets.

Ad-hoc development bundles are qualified only with synthetic Keychain items.
Stable signed-identity access across upgrades remains a Gate 4B requirement.
Local logout removes local helper and Keychain state. It does not claim remote
provider revocation.

## Helper boundary

The Node helper is part of the trusted computing base, not a sandbox. Miller
starts it without a shell, passes only `LANG`, `LC_ALL`, `TMPDIR`, and `TZ`,
and communicates through a strict, size-bounded JSONL protocol. Standard error
admits only bounded, non-content diagnostics. Raw exceptions, provider bodies,
URLs, headers, prompts, responses, tokens, and stack traces are not retained.

Reasoning requests require an empty `tools` array. The helper contains no
model-callable shell, filesystem, coding-agent, or arbitrary tool surface.

## Network and endpoints

Remote OpenAI-compatible endpoints must be HTTPS and may not contain user
information, queries, or fragments. Authenticated redirects are refused.
Loopback HTTP is admitted only for controlled local fixtures. OAuth binds to
`127.0.0.1`, requires PKCE and matching state, admits one callback, and uses a
bounded lifetime.

Signing, notarization, clean-machine distribution, upgrade identity, live
microphone/audio observation, and public-release security qualification remain
open release gates. Miller v0.1 has no avatar runtime or asset dependency.

## Experimental direct GPT-Live comparator security boundary

The direct comparator admits only the selected `codex_oauth` profile. The bounded
access token and account ID loaded by `GPTLiveCredentialLoader` remain in
memory, are sent only in the direct `/v1/live` HTTP and sideband WebSocket
headers, and are never logged, persisted, stringified, or included in fixed
error codes. API-key authentication is refused by the direct route. The
multipart SDP/session body, SDP answer, call ID, and sideband frames have
explicit size and content bounds; provider response bodies and event error
messages are not retained.

The direct route uses Foundation `URLSession` and
`URLSessionWebSocketTask`. It validates the successful `2xx` answer and supported call-ID
headers, maps HTTP and protocol failures to fixed Miller codes, retries only
sideband startup within a small bound, buffers only a fixed number of early
frames, and closes on cancellation, expiry, unexpected closure, malformed or
binary frames, and teardown. Unknown valid event types are bounded and
ignored. Transcript state is bounded presentation state and never becomes a
second persistence model. Client delegation is injectable, superseded by a
newer delegation, and returns a fixed unsupported spoken outcome when no safe
Miller reasoning consultation is supplied.

## Codex App Server WebRTC v3 qualification boundary

The `MillerLive` process supervisor accepts only an absolute executable path,
uses no shell, creates isolated task-private process roots, and signals the
helper process group on timeout, cancellation, failure, and parent shutdown.
The only persistent-looking helper input is a task-private mode-0600
`CODEX_HOME/config.toml` containing the non-secret `realtime_conversation`
feature enablement and exact V1 realtime selection; it is removed before
termination is published. The helper receives the exact reviewed PATH and
locale values.
Its strict decoder bounds frames, transcripts, audio chunks, and event counts;
rejects unknown fields and methods; and fences request, thread, generation, and
terminal state.
Output buffering is fixed at eight frames and fail-closes on overflow. All
retained event strings, including roles, thread identifiers, terminal reasons,
and transcript text, share a cumulative bound. Account lifecycle notifications
are validated against their exact enums and discarded without logging their
contents; raw realtime items are likewise shape-checked and discarded.
Input writes, close, and reaping share one transport lock, and the input pipe
uses descriptor-local `F_SETNOSIGPIPE` instead of modifying global signal
disposition.
Exact 0.145.0 startup responses and notifications are independently correlated,
so either legal delivery order is bounded without accepting duplicates. A stop
during any `starting` phase cancels supervision locally; a protocol stop is sent
only for a matching session that has reached `active`.

The WebRTC v3 route uses an owner-installed official Codex CLI as an external
runtime. Miller does not bundle, build, download, update, or remove it. Before
readiness, credential access, WebKit peer creation, or launch, Miller resolves
the selected launcher to a native executable and requires an arm64-only Mach-O
with identifier `codex`, OpenAI team identifier `2DC432GLL2`, and a valid
Developer ID chain. External updates may change the version and CodeDirectory
hash, so neither is pinned. Compatibility remains fail-closed at the App Server
protocol and WebRTC capability handshake.

Static preflight is not process identity. Immediately after `posix_spawn`, the
supervisor closes its copies of child-side pipe ends and asks the kernel for the
actual guest by PID. A short retry is permitted only while that guest is not
yet observable. The kernel-identified guest then undergoes strict
execution-requirement validation and is bound to the exact selected canonical
executable; its signing identity and architecture are compared again. This
occurs before
Miller publishes process state, starts pumps, or sends a protocol or credential
byte. Any failure kills and reaps the process group, closes parent descriptors,
and removes the private root. The shell qualification script is therefore
defense in depth, not the authority that permits OAuth credential delivery.

The packaged development app links `MillerLive` and `MillerLiveAudio`, supports
saved or automatic runtime selection plus an explicit development override,
and advertises the capability marker. It includes
the reviewed, hash-verified Node runtime but packages no Codex, Cortana, or
third-party WebRTC executable. The source plist does not contain the marker.
Ordinary launches configure no child process and construct no peer or WebKit
media session. They do not contact the provider, request microphone access, or
load the OAuth credential until Live Voice starts. Missing or incompatible
Codex makes Live Voice unavailable without disabling typed operation.

The live credential loader reads only the selected `codex_oauth` profile's
generated Keychain reference when Live Voice starts. It requires the exact
version-1 envelope and closed OAuth field set. The direct route uses the
admitted access token and account ID without a refresh or second auth store;
the retained App Server client uses the existing Miller/Pi refresh path and
rejects account changes and reused access tokens.

The qualified live route uses system WebKit WebRTC. The only allowed capture
permission is microphone access for the initial main frame at
`https://miller.invalid/`, after native authorization and the explicit Start
Live Voice action. Camera, subframe, foreign-origin, navigation, popup,
download, and unrelated permission requests are denied. The peer is local HTML
in an ephemeral data store, uses typed main-frame JavaScript calls rather than a
general message bridge, and is removed during cleanup. SDP is bounded in memory
for negotiation only and is not logged or persisted.

WebRTC tracks are the only primary media input and output. Direct GPT-Live's
sideband supplies bounded lifecycle and transcript state; the retained App
Server sideband does so only for the explicit fallback. Either may influence
the speaking indicator but cannot enqueue audio for AVFoundation playback. The
older AVFoundation PCM implementation remains isolated, non-default,
unqualified groundwork.
