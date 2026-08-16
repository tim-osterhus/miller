# Miller

Miller is a macOS menu-bar assistant for typed conversations, GPT-Live voice,
local history, and permissioned tools.

Miller is for people who want a personal assistant without surrendering control
of local data or tool permissions. It keeps conversation state on your Mac and
shows tool activity while it runs.

**Current source version:** v0.1.2 for Apple Silicon Macs running macOS 15 or
newer. The source release passed its principal owner-visible flows. The owner
accepted two bounded deferrals documented in the qualification record.

## Build and open Miller

You need:

- An Apple Silicon Mac running macOS 15 or newer.
- Swift 6.1.
- Node.js `v22.22.0` at `/opt/homebrew/opt/node@22/bin/`.
- Network access for dependency bootstrap and hosted providers.
- The official Codex CLI/App Server `0.146.0` or newer for Live Voice.

Clone the repository and build the release app:

```bash
git clone https://github.com/tim-osterhus/miller.git
cd miller
git checkout main
./scripts/bootstrap-gateway-dependencies.sh
./scripts/package-release-app.sh
open .artifacts/release/Miller.app
```

The bootstrap verifies the pinned npm dependency closure. Packaging does not
install dependencies implicitly.

The resulting app is ad-hoc signed for structural verification. It is not
Developer ID signed or notarized.

## Wake Listening

Wake Listening is off by default. A verified package enables the existing
Voice settings section with the first valid phrase **Hey Miller**. The owner
may replace it with one bounded English phrase; invalid input leaves the last
working phrase and keyword file unchanged. Wake uses only the system-default
microphone, never saves or logs audio, and yields the microphone to manual
Live Voice before reopening it after Live cleanup.

The wake runtime is prepared explicitly, after checking the printed storage
forecast and retaining at least 6 GiB free:

```bash
./scripts/bootstrap-wakeword-dependencies.sh
./scripts/verify-wakeword-dependencies.sh
./scripts/package-release-app.sh
```

Packaging verifies the retained pinned inputs and ships only the linked native
runtime plus the required model/token files. It does not bootstrap, and it
does not ship archives, headers, compiler inputs, or private generated
keyword files.

## The conversation loop

Miller provides:

- Streaming typed responses with cancellation.
- GPT-Live voice with mute, interruption, and visible transcripts.
- Local conversation history with explicit review, export, and deletion.
- Codex OAuth and configurable OpenAI-compatible provider profiles.
- Markdown rendering and external browser links.
- Follow-tail scrolling that pauses when you select text or scroll upward.
- A bounded capability-activity panel for recent tool actions.

Miller owns conversation identity, context selection, cancellation, and final
turn status. Providers do not own Miller's durable history.

## Live Voice

Live Voice uses GPT-Live through an owner-installed official Codex CLI/App
Server.

Miller requests microphone access only after you select **Start Live Voice**.
WebKit carries microphone and remote audio through WebRTC. Miller does not save
audio.

Live transcripts are bounded presentation text. Miller can save a selected text
turn to local history when the owner explicitly saves it; saved text never
implies saved audio.

If Live Voice is unavailable, typed conversations and local history remain
available.

## Tools with an authority boundary

Miller supports local and remote MCP servers. It also imports reviewed portable
skills and plugin bundles from Settings.

Before enabling an MCP server, Miller shows its identity, endpoint class, and
declared tools. Each server and tool can use a separate trust policy.

| Trust policy | Behavior |
| --- | --- |
| Read-only | Declared read-only calls can run automatically. Changes require approval. |
| Ask before changes | Changing or unknown calls require approval. |
| Fully trusted | Miller can run admitted calls without per-call approval. |

One native capability broker applies these policies across Codex typed chat,
Codex Live Voice sideband calls, and the Pi gateway. Miller records bounded
audit events for classification, approval, denial, and result status.

Codex account apps remain Codex-only in v0.1.2. OpenAI-compatible providers do
not inherit account apps installed through Codex.

## Provider support

| Provider path | Typed chat | Live Voice | Codex account apps |
| --- | --- | --- | --- |
| Codex OAuth | Yes | Yes | Yes |
| OpenAI-compatible HTTPS endpoint | Yes | No | No |

DeepSeek is the qualified OpenAI-compatible reference. Model identifiers remain
configurable, and each provider confirms model availability on first use.

Miller tested official Codex CLI/App Server `0.146.0` on Apple Silicon. The
`0.145.0` fixtures document the protocol shape but do not establish runtime
support. Protocol reference/evidence is therefore separate from tested runtime
support.

## Local data and privacy

Miller stores conversations and non-secret provider metadata in local SQLite:

```text
~/Library/Application Support/ai.millrace.miller/miller.sqlite3
```

Provider secrets use the macOS Keychain service
`ai.millrace.miller.credentials`. SQLite does not store those secrets.

Before a remote request, Miller selects bounded context from local history and
sends that text to the chosen provider. See `docs/privacy.md` for the exact
context limits and deletion boundaries.

Miller does not claim secure erasure. FileVault, backups, snapshots, and storage
hardware may retain earlier bytes.

## Known limits

- v0.1.2 is a source-first release without Developer ID signing or notarization.
- Hosted reasoning and Live Voice require network access.
- The bounded Live-text compatibility spike ended `INCONCLUSIVE`; typed input
  during an active Live session is not product-supported in v0.1.2.
- Wake Listening supports **Hey Miller** and one bounded custom English phrase.
- A slow first wake-to-Live admission remains a nonblocking optimization target.

## Runtime boundaries

Miller is standalone. It does not require Millrace or Millrace OS.

The native app owns interaction, conversation state, settings, and visible
outcomes. The capability broker owns tool policy. A supervised Node gateway
adapts provider traffic behind a bounded JSONL protocol.

Miller can later delegate governed, multi-stage work to Millrace. Miller does
not treat model, client, process, or interface state as Millrace runtime truth.

See `docs/architecture.md` for process and ownership boundaries.

## Development and verification

Run the complete local checks from the repository root:

```bash
./scripts/bootstrap-gateway-dependencies.sh
./scripts/test.sh
./scripts/package-release-app.sh
./scripts/verify-release-package.sh .artifacts/release/Miller.app
```

Remove generated build and dependency roots after qualification:

```bash
./scripts/clean.sh --build-caches
./scripts/clean.sh --dependencies
```

The v0.1.2 qualification artifacts retain no credentials, audio, transcript
content, or provider payloads. The owner approved the source release with two
deferrals: the forced combined-fallback scenario and destructive reset/removal
testing on a real account.

- `docs/qualification/v0.1.2-headless-report.md`
- `docs/qualification/v0.1.2-human-protocol.md`
- `docs/qualification/miller-v012-06-release-closure.md`

## Documentation

- `docs/installation.md`: requirements and first-run setup.
- `docs/provider-compatibility.md`: typed and voice provider boundaries.
- `docs/privacy.md`: local storage and remote context disclosure.
- `docs/security.md`: credentials, tools, helpers, and endpoint validation.
- `docs/removal.md`: local reset and removal procedure.
- `docs/troubleshooting.md`: bounded recovery for common failures.
- `docs/development.md`: build, test, package, and cleanup commands.
- `docs/upcoming-releases.md`: v0.1.3 scope and later client work.
- `CHANGELOG.md`: release history and known limitations.
- `PROVENANCE.md` and `THIRD_PARTY_NOTICES.md`: dependency provenance and
  licensing.

## License

Miller is licensed under the Apache License 2.0. See `LICENSE` and `NOTICE`.
