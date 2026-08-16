# Remove Miller

Miller v0.1.2 tested official Codex CLI/App Server `0.146.0` on Apple Silicon;
`0.145.0` is protocol reference/evidence only, not a runtime support claim.
Reset and removal never modify the external Codex installation.

Dragging `Miller.app` to Trash does not remove Miller-managed data or
OS-managed effects. If complete local removal is desired, reset first.

1. Open Miller Settings.
2. Select **Reset Miller** and confirm.
3. Review every reported root. Retry or investigate any reported failure.
4. Quit Miller and verify it is no longer running.
5. Remove `Miller.app`.

Reset stops and reaps the helper, then closes SQLite. It removes the database,
WAL and SHM files, helper cache, and Miller Keychain items. Reset reports
partial failure and does not claim secure erasure.

The managed locations are:

```text
~/Library/Application Support/ai.millrace.miller/
~/Library/Caches/ai.millrace.miller/
~/Library/Preferences/ai.millrace.miller.plist
Keychain service: ai.millrace.miller.credentials
```

The current reset flow removes the database, helper cache, and Keychain items.
The shortcut and selected external-Codex-path preferences may be removed
separately after reset if they remain.
macOS may retain effects in backups, APFS snapshots, unified logs, browser
history/cache, temporary storage, Keychain metadata, or crash infrastructure.

Wake reset also disables capture, releases the microphone lease, removes the
SQLite wake preferences, and removes Miller's generated
`~/Library/Application Support/ai.millrace.miller/wake-keywords.txt` file and
its owner-only wake directory. The packaged model/token files are part of the
app bundle and disappear when the app is removed; bootstrap archives and
extraction roots are temporary and are deleted by their scripts. This applies
to the default **Hey Miller** phrase and any bounded custom phrase.

Avatar reset disables presentation, disposes the renderer, removes Avatar
preferences, and removes Miller-owned profile, bookmark, binding, digest,
quarantine, and failure metadata under:

```text
~/Library/Application Support/ai.millrace.miller/avatar/
```

It does not delete, move, or modify the original user-selected VRM or VRMA
files. Remove those separately only if desired. Miller distributes no default
model or animation pack, so app removal has no character asset to preserve.

An externally installed Codex CLI is owned by the user or its package manager.
Miller reset, repository cleanup, and app removal never remove or modify that
installation.

For repository cleanup during development, run:

```bash
./scripts/clean.sh
./scripts/clean.sh --dependencies
```

Those commands remove only fixed repository-generated roots. They do not touch
Miller user data, Keychain, or unrelated system caches.

## Export, deletion, and reset

Export is an explicit action from the selected history conversation. It
produces selectable text and does not export microphone or remote audio.
Deleting a turn or conversation removes it from Miller's SQLite history; reset
removes the database, WAL/SHM sidecars, cache, preferences, and Miller-owned
Keychain items after the owner confirms the listed roots. These operations are
not secure-erasure claims because backups and operating-system storage may
retain prior bytes.

Before app removal, review the export and deletion results, reset Miller, quit
the app, and verify that no Miller process remains. Removing the app does not
remove an owner-installed Codex runtime or provider account.

## Repository qualification cleanup

The release cleanup removes `.build`, `.cache`, `Gateway/node_modules`,
staging roots, unretained wake inputs, sockets, and helper/test processes.
`.artifacts/release/Miller.app` and the sanitized qualification report are
retained for inspection. The verified release app is not removed unless a
newly verified artifact intentionally replaces it.
