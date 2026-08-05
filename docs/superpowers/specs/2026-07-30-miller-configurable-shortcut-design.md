# Miller Configurable Global Shortcut Design

## Purpose

Replace the conflicting fixed Command-Option-Space activation with a
configurable, non-secret macOS preference. The default is
Command-Shift-Space.

## Scope

Settings offers three reviewed presets:

- Command-Shift-Space;
- Control-Shift-Space; and
- Option-Shift-Space.

The selected preset is stored in
`~/Library/Preferences/ai.millrace.miller.plist`, the existing architecture's
declared non-secret UI-preference root. No shortcut value enters SQLite,
Keychain, the reasoning helper, or conversation state.

An arbitrary shortcut recorder is not part of this repair. Carbon registration
can succeed even when a system action also fires, as demonstrated by Finder's
Command-Option-Space behavior. A recorder would therefore imply conflict
detection that Miller cannot honestly provide. The bounded presets avoid known
macOS defaults and keep the MVP behavior testable.

## Runtime Behavior

Miller loads the saved preset at launch or uses Command-Shift-Space when no
valid value exists. Selecting another preset in Settings saves it and
immediately replaces the registered hot key.

If registration fails:

- Settings reports Unavailable;
- the status item reports shortcut unavailable;
- menu access remains operational; and
- the selected preset remains visible so the operator can choose another.

## Verification

Automated tests cover preset identity, display labels, Carbon modifier mapping,
default fallback, preference round-trip, selection callbacks, registration
failure presentation, and unchanged menu access.

Human H1 physically verifies that the default opens only Miller, produces no
Finder or other system side effect, remains keyboard accessible, and survives
relaunch.
