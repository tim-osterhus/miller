# Miller Text-Alpha Host Check

Overall: PASS

This is the human Gate H1 protocol for the development-only native host. Unit
tests and script validation do not prove visual appearance, focus, physical
shortcut delivery, VoiceOver behavior, system prompts, or M1 performance.
Replace each `NOT_RUN` below with exactly `PASS` or `FAIL` only after direct
observation on the qualification-floor Mac. Stop on the first failure.

Run from the Miller repository:

```bash
./scripts/run-host-check.sh
```

The runner packages the app once, launches it twice with one unchanged temporary
database and cache path, suppresses content logs, and has a separate operator
checkpoint for each launch. After each checkpoint it captures only current
direct fake-helper children, terminates only the app and helpers it owns, and
verifies that launch is gone. Final cleanup removes the temporary database,
WAL/SHM files, caches, status facts, helper, and development bundle.

## Results

```text
menu_bar_lifetime=PASS
menu_bar_icon=PASS
global_activation=PASS
panel_key_eligibility=PASS
first_responder_focus=PASS
escape_behavior=PASS
keyboard_only_conversation=PASS
voiceover_labels_and_order=PASS
shortcut_failure_presentation=NOT_RUN
fake_helper_stream_and_stop=PASS
relaunch_persistence=PASS
synthetic_keychain=PASS
cleanup_process_scan=PASS
```

## First-launch checkpoint

1. Confirm one `Miller` menu-bar item persists after all windows close. The
   menu-bar status item must show the complete Millrace silhouette as a
   monochrome system template icon in one square slot, recognizable and
   unclipped at actual size; opening it must expose the existing Miller menu.
   Its menu must provide Open Miller, New Conversation, Stop Response only
   during a turn, Conversation Window, Settings, and Quit. If macOS hides the
   item due to menu-bar crowding, leave both `menu_bar_icon` and
   `menu_bar_lifetime` as `NOT_RUN`; do not infer any menu-open observation
   that depends on the hidden item. Continue through global activation, and do
   not rearrange or remove other menu-bar items for this test.
2. Confirm Settings selects Command-Shift-Space by default and reports Ready.
   Physically press Command-Shift-Space twice, dismissing between presses.
   Each press must open exactly one overlay and must not open Finder or any
   other system surface. This is activation only, never push-to-talk.
3. Confirm the panel can become key, the `Message Miller` field becomes first
   responder, Escape hides the overlay without stopping a response, and reopen
   preserves the conversation.
4. Complete one typed fake-helper turn using only the keyboard. Confirm Send is
   unavailable while a turn is active, Stop is available, streamed text is
   visible, and a Stop attempt preserves any admitted partial text.
5. Open the conversation window. Confirm active conversations precede archived
   conversations, newest items appear first within each group, and new,
   resume, archive, unarchive, delete-with-confirmation, follow-up, and stop
   controls are keyboard reachable. Lifecycle commands must refuse while that
   conversation has an active turn.

Return to the runner and press Return. It will capture the current direct
fake-helper children, terminate and verify the first launch, and retain the
temporary database, cache, and development bundle for the relaunch.

## Second-launch checkpoint

6. The runner relaunches Miller using the same temporary database path. Confirm
   completed and partial visible text remains. Do not inspect the database
   contents directly.
7. With approval, use VoiceOver to verify `Miller status`, `Message Miller`,
   `Send message`, `Stop response`, `New conversation`, conversation items,
   and a coherent focus order with no trap. Restore VoiceOver to its prior
   state.
8. In Settings, select Control-Shift-Space. Confirm the old shortcut no longer
   opens Miller, the new shortcut does, and Settings reports Ready. Restore
   Command-Shift-Space before continuing. If any reviewed preset naturally
   fails registration, confirm menu access remains operational and Settings
   reports Unavailable; otherwise leave `shortcut_failure_presentation` as
   `NOT_RUN`. Do not change system settings merely to force failure.
9. With approval, select `Run Keychain probe` once. It must add, read, update,
   and delete one random generic-password fixture under
   `ai.millrace.miller.credentials.probe`, report cleanup, and expose no value.
   Do not use or enter a real credential.
10. Leave Miller running, return to the runner, and press Return. It will
    capture the current direct fake-helper children, terminate and verify the
    second launch, then remove `.artifacts/host-check/`, `.artifacts/Miller.app`,
    its temporary SQLite/WAL/SHM files, caches, logs, and bundle.

Record only the result vocabulary and a non-content failure code. Do not retain
screenshots, recordings, typed prompts, assistant text, hostnames, device IDs,
Keychain accounts or values, raw system dialogs, credentials, or process
environment.
