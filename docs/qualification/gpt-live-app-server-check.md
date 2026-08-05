# GPT-Live qualification: external Codex App Server WebRTC v3

## Runtime boundary

Miller v0.1 uses the App Server in a separately installed official Codex CLI.
Miller does not bundle, build, fetch, update, or remove Codex. At launch it
uses, in order:

1. the explicit `--gpt-live-app-server PATH` development override;
2. the owner-selected path saved by Miller Settings;
3. bounded discovery in common installation locations and the inherited
   `PATH`.

An npm launcher is resolved to its platform-native executable. Miller launches
that executable directly without a shell or Node intermediary. Missing or
incompatible Codex makes Live Voice unavailable while typed conversation
remains usable.

Before credential or protocol bytes are sent, Miller requires a thin arm64
Mach-O with identifier `codex`, OpenAI team identifier `2DC432GLL2`, and a valid
Developer ID chain. After spawn it validates the kernel guest again and binds
the PID to the exact selected canonical executable. External updates may change
the version and CDHash, so neither is pinned. Protocol initialization and the
`thread/realtime/*` WebRTC v3 handshake remain the compatibility gate.

## Deterministic check

The required non-live terminal marker is:

```text
EXTERNAL_CODEX_RUNTIME_READY_LIVE_NOT_RUN
```

This marker establishes only local build, packaging, identity, architecture,
harness, and cleanup prerequisites. It does not establish account entitlement,
network access, microphone permission, WebRTC connectivity, transcript
behavior, or audible output.

Run:

```bash
./scripts/test.sh --filter MillerLiveTests
./scripts/test.sh --filter MillerLiveAudioTests
./scripts/test.sh --filter MillerAppTests
./scripts/package-dev-app.sh
./scripts/run-gpt-live-app-server-check.sh --harness-smoke \
  --harness "$PWD/.artifacts/Miller.app/Contents/MacOS/Miller"
./scripts/run-gpt-live-app-server-check.sh --test-cleanup \
  --harness "$PWD/.artifacts/Miller.app/Contents/MacOS/Miller"
./scripts/run-gpt-live-app-server-check.sh --synthetic-webrtc
./scripts/run-gpt-live-app-server-check.sh --dry-run \
  --helper "$HOME/.npm-global/bin/codex" \
  --harness "$PWD/.artifacts/Miller.app/Contents/MacOS/Miller"
```

The dry run resolves and verifies the external executable and invokes only its
local `--version` command. It makes no provider request, accesses no Keychain
credential, creates no WebKit peer, and requests no microphone or audio access.
The output omits local paths, credentials, provider content, SDP, transcripts,
and private runtime logs.

The development app advertises
`MillerGPTLiveHarnessCapability = miller-gpt-live-webrtc-harness-v1` only in the
generated bundle. Packaging must prove that `Miller.app` contains no Codex or
Cortana executable, Rust/Cargo payload, source checkout, or third-party WebRTC
binary.

## Human gate

After the deterministic marker is recorded, launch Miller normally with the
validated external Codex installation. On the M1 qualification Mac, retain only
sanitized pass/fail, timing, version, process, and cleanup facts while checking:

1. Codex is detected or selected in Settings, and Live Voice is available for
   the selected Codex OAuth profile.
2. Start Live Voice requests microphone access only when needed and reaches
   Listening without duplicate capture or output.
3. Spoken input and audible output work, and local date/time context is correct.
4. Transcripts remain chronological, role-separated, bounded, and
   nonduplicated across a follow-up after at least thirty seconds.
5. Mute/unmute stops and restores outbound microphone media without ending the
   session.
6. Interrupt immediately silences remote audio and closes the session.
7. A second session negotiates with a fresh peer after cleanup.
8. Provider, protocol, permission, app-exit, and reset failures remain truthful;
   typed operation remains available; the child is reaped and Miller-owned
   private roots are removed.

Do not retain SDP, transcripts, audio, credentials, account identifiers,
callback URLs, or provider payloads. This gate does not authorize modifying or
removing the external Codex installation.

Only this owner-visible pass may record
`GATE_4B_EXTERNAL_RUNTIME_CLOSED`. Miller Avatar is a separate follow-on
release and does not gate Miller v0.1.

The owner-visible pass has been completed. Its sanitized result is recorded in
`gate-4b-external-codex-human-report.md`; no sensitive live-session material is
retained here.
