# Remove Miller

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
