# Miller Selectable Transcripts Design

**Status:** Approved for Miller v0.1.1

**Release placement:** New Task 17, before release packaging and owner-visible qualification

## Objective

Miller must let the user select and copy visible transcript text with standard
macOS interactions. The behavior must cover typed conversations and Live Voice
transcripts in both the full conversation window and compact overlay.

The feature changes presentation only. It does not change transcript storage,
provider requests, clipboard ownership, or conversation authority.

## Current State

The current source applies `textSelection(.enabled)` to typed user messages,
assistant Markdown, and code blocks in the full conversation view. The full
conversation view does not show the active Live Voice transcript. The compact
overlay reuses the typed turn views, but its Live Voice rows are not selectable.
The preserved v0.1.0 release application also predates the current selection
changes.

The existing implementation therefore does not provide one qualified contract
across all transcript surfaces. Task 17 must make that contract explicit and
testable before v0.1.1 packaging.

## User Contract

### Supported surfaces

The user can select and copy text from:

- Typed user messages in the full conversation window.
- Typed Miller responses in the full conversation window.
- Typed user messages in the compact overlay.
- Typed Miller responses in the compact overlay.
- Live Voice user transcript entries in the full conversation window.
- Live Voice Miller transcript entries in the full conversation window.
- Live Voice user transcript entries in the compact overlay.
- Live Voice Miller transcript entries in the compact overlay.

The Voice History window remains a session-selection and export surface. This
task does not add a saved-session transcript reader. JSON export remains the
complete-session copy path for saved history.

### Selection behavior

- Pointer dragging selects visible text within a rendered transcript block.
- Shift-click extension and standard macOS selection behavior remain native.
- Command-C copies only the selected text.
- Miller does not read, log, persist, or transform clipboard contents.
- Labels such as `You`, `Miller`, status text, and capability activity are not
  included unless the user explicitly selects selectable label text.
- Links remain clickable.
- Code blocks remain horizontally scrollable and selectable.
- Selection never moves focus to the message input field.
- Opening a link does not replace or submit transcript text.

The initial implementation does not promise one drag selection across separate
messages or structurally separate Markdown blocks. Each rendered text block is
a native macOS selection domain.

## Streaming and Follow-Tail

Transcript selection and follow-tail scrolling must not fight for control.

- Pointer interaction inside transcript text suspends follow-tail before an
  automatic scroll can disturb the interaction.
- New content does not move the viewport while follow-tail is suspended.
- `Jump to latest` clears the suspension and resumes following.
- Selection in an unchanged completed block remains stable while a later block
  streams.
- A currently mutating Markdown block keeps a stable view identity when its
  structural block type and position remain unchanged.
- Reduced Motion continues to disable animated programmatic scrolling.
- Programmatic scrolling never changes first responder or text selection.

Task 19 must manually qualify selection inside a completed response while a
later response or Live Voice entry streams. The task does not require native
selection to survive replacement of the exact text range being selected.

## Presentation Architecture

Task 17 adds one small shared presentation boundary for selectable transcript
content. The boundary applies native text selection consistently and carries a
stable accessibility identity. It must not introduce a second transcript model
or copy transcript text into presentation-owned storage.

The preferred implementation keeps the existing SwiftUI transcript hierarchy:

1. `TranscriptTurnView` remains the typed-turn presentation.
2. `AssistantMarkdownView` remains the Markdown renderer.
3. `LiveTranscriptTurnView` becomes a shared Live Voice row used by the full
   conversation window and compact overlay.
4. The full conversation window shows the active Live Voice transcript while
   the session projection exists.
5. A shared modifier or wrapper applies the selection contract to plain text,
   Markdown text blocks, list items, quotes, and code blocks.
6. `FollowTailScrollView` receives only the minimum additional interaction state
   needed to suspend automatic movement during selection.

An AppKit `NSTextView` replacement is out of scope. Task 17 may use a narrow
AppKit event bridge only if SwiftUI exposes no reliable way to identify pointer
selection interaction. Such a bridge must not own text, clipboard operations,
scrolling, or first-responder policy.

## Accessibility and Keyboard Behavior

- VoiceOver continues to announce user and Miller transcript roles.
- Enabling selection must not combine an entire conversation into one
  inaccessible element.
- Command-C works when transcript text owns the active selection.
- Command-A remains scoped to the active selectable text domain. It must not
  select or mutate the message composer.
- Tab and Shift-Tab navigation remain unchanged.
- Escape retains its existing overlay-dismiss behavior.
- Selection must not trigger message submission, capability approval, or Live
  Voice controls.

## Privacy and Security

This feature grants no new model, provider, plugin, or helper authority.

- Miller never reads the general pasteboard to implement selection.
- Miller never writes the pasteboard without the user's native copy command.
- No copied text enters logs, diagnostics, audit records, or SQLite because of
  the copy operation.
- The feature does not make hidden reasoning, raw provider events, credentials,
  tool arguments, or tool results selectable.
- Only text already visible to the user can be selected.

## Failure Behavior

Selection failure must not affect conversation or voice operation.

- If native selection is unavailable on one block, the transcript still
  renders and streaming continues.
- A selection interaction cannot stop, cancel, or restart a provider turn.
- Follow-tail may remain suspended after an ambiguous pointer interaction. The
  visible `Jump to latest` control provides deterministic recovery.
- The feature adds no custom clipboard error state because the operating system
  owns Command-C.

## Automated Verification

Task 17 must add deterministic coverage for:

- All eight supported transcript surfaces use the shared selection boundary.
- Plain text, inline Markdown, links, lists, quotes, and code blocks remain
  selectable.
- Unchanged Markdown blocks retain stable identities during streaming.
- Transcript selection suspends follow-tail.
- Streaming continues while follow-tail remains suspended.
- `Jump to latest` restores follow-tail.
- Reduced Motion behavior remains unchanged.
- Transcript interaction does not change input focus.
- Production source does not read the pasteboard or persist clipboard contents.
- Hidden reasoning, provider payloads, credentials, and capability audit
  internals remain unselectable.
- Source and package policy retain no test-only transcript or clipboard fixture.

SwiftUI's native selection range is owner-visible state. Automated tests can
verify composition, stable identities, and follow-tail state transitions, but
must not claim that a pointer drag or Command-C succeeded without manual
qualification.

## Owner-Visible Qualification

Task 19 must verify the release application, not a development preview.

1. Select and copy part of a typed user message.
2. Select and copy plain text from a completed Miller response.
3. Select and copy bold text, a link label, a list item, and inline code.
4. Select and copy text from a fenced code block.
5. Select and copy user and Miller Live Voice transcript entries in the full
   conversation window.
6. Repeat typed and Live Voice selection in the compact overlay.
7. Hold a selection in a completed entry while later content streams.
8. Confirm the viewport does not jump while follow-tail is suspended.
9. Use `Jump to latest` and confirm streaming follow resumes.
10. Confirm Command-C copies only the selected visible text.
11. Confirm the message composer retains its prior text and does not submit.
12. Confirm VoiceOver roles, keyboard traversal, links, Escape, and Reduced
    Motion still behave correctly.

The qualification report records pass or fail only. It must not record copied
transcript contents.

## Release Scope

Task 17 is required for v0.1.1 because the existing Task 19 protocol already
requires stable text selection. The task must finish before revised Task 18
packages the release candidate.

Custom wake phrases, wake-triggered Live Voice startup, microphone calibration,
and bundled wake dependencies move to v0.1.2. The completed wakeword foundation
may remain in source, but v0.1.1 must not bundle or advertise wakeword support.

## Non-Goals

Task 17 does not add:

- A saved Voice History transcript reader.
- A `Copy entire conversation` command.
- Automatic clipboard monitoring.
- Clipboard history.
- Rich-text pasteboard formats beyond native SwiftUI behavior.
- Editing of transcript text.
- Selection across multiple transcript messages.
- Computer-control or text-insertion tools.
- Wakeword integration.
- Signing and notarization.

## Acceptance Criteria

Task 17 is complete when:

- Every supported visible transcript surface uses the shared selection
  contract.
- Deterministic presentation and follow-tail tests pass.
- Full Miller application tests pass.
- Package-policy checks find no clipboard authority or private transcript data.
- The release plan assigns manual pointer and Command-C validation to Task 19.
- An independent specification review finds no missing surface or privacy gap.
- An independent quality review reports no unresolved P0, P1, or P2 finding.
