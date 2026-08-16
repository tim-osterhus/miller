# Miller Avatar C7 owner-visible protocol

Status: `HUMAN_NOT_RUN`

Expected success marker: `MILLER_AVATAR_C7_HUMAN_PASS`

This protocol qualifies the optional Avatar presentation only. It does not
replace Miller v0.1.2 qualification and must not reuse the retained v0.1.2 app
as integration evidence.

## Preconditions

1. Coordinate a clean pause for the retained v0.1.2 Miller and Gateway
   processes before running any command that launches an app or app smoke
   harness. Nonlaunching source builds may run while the retained app is
   active. Do not run the two Miller app instances concurrently.
2. Build and package the candidate from the reviewed C7 Miller source and
   Miller Avatar `v0.1.0-alpha.3` at exact commit
   `dac4d0ab432a9c158dca40985b28335bdfc70e2b`. Do not replace the retained
   release bundle. Treat
   a packaging script that executes the candidate for a smoke test as a launch
   and run it only after the retained processes are paused.
3. Use a private local VRM 1.0 model and compatible VRMA 1.0 motions sufficient
   to bind `idle`, `listening`, `thinking`, and `speaking`. One motion may serve
   more than one role. Work from disposable copies when testing changed or
   removed files.
4. Keep the assets outside both repositories and package roots. Record only
   result codes and bounded measurements; retain no asset, source path, image,
   transcript, audio, provider payload, or identifying metadata.
5. Leave normal networking available. This protocol does not require or
   authorize disabling network interfaces.
6. Verify the packaged candidate inventory before launch. It must resolve
   Miller Avatar `v0.1.0-alpha.3` at
   `dac4d0ab432a9c158dca40985b28335bdfc70e2b`, include the fixed renderer
   resources, and
   contain no VRM, VRMA, texture, thumbnail, private fixture, transcript, or
   audio asset.

## Checks

### 1. Avatar Off baseline

- Launch with Avatar disabled.
- Confirm the ordinary 520-point Miller content remains unchanged and every
  native control is usable.
- Complete one typed turn. Confirm no Avatar surface appears and no model file
  is requested.

### 2. Profile and motion setup

- Open Settings -> Avatar and import the private model copy.
- Add compatible motions to at least `idle`, `listening`, `thinking`, and
  `speaking`. Exercise `success` and `failure` when compatible clips exist.
- Confirm motion bindings, Reduced Motion, retry, remove, and enablement
  controls have clear labels and status.
- Enable Avatar and confirm one noninteractive 200-point leading surface
  appears without narrowing or covering Miller's 520-point content.

### 3. Typed presentation

- Submit one typed request.
- Confirm the visible states progress through the expected idle, listening,
  thinking, and terminal presentation without flicker or stale reversal.
- Replace the selected profile while idle, then during a new typed turn.
  Confirm the old surface disappears before the replacement appears and no
  old callback changes the replacement.

### 4. Real Live presentation

- Start one real Live session and speak normally.
- Confirm provider lifecycle alone does not create mouth motion.
- Confirm audible remote speech selects the speaking presentation and produces
  bounded mouth motion; silence returns neutral promptly.
- Interrupt once, mute and unmute the microphone once, end the session, then
  start a second session. Confirm mute does not stop remote-output motion and
  every terminal path returns neutral.

### 5. Focus and accessibility

- Press Tab and Shift-Tab repeatedly through all native controls before,
  during, and after a renderer or profile replacement.
- Confirm focus never enters or becomes trapped in the Avatar WebKit surface.
- With VoiceOver, traverse the window and Settings. Confirm the Avatar image is
  not exposed as an interactive child, Avatar status and controls are named,
  and existing Miller controls remain reachable in a coherent order.

### 6. Reduced Motion and fallback

- Enable Miller's Avatar Reduced Motion setting, then the macOS setting.
- Confirm either authority stops skeletal and mouth motion and restores the
  normalized static pose without disabling typed or Live operation.
- Disable Avatar and confirm the surface detaches and the ordinary Miller
  layout returns.
- Re-enable with no selected profile and confirm a truthful static/no-avatar
  fallback rather than a blank interactive region.

### 7. Failure isolation

- Using disposable copies, exercise a removed model, changed model, invalid
  motion, and removed motion. Use explicit retry after restoring a valid copy.
- Confirm the failure remains in Avatar status, unaffected motions or static
  presentation remain usable when permitted, and typed, Live, history,
  settings, capability approval, and tool execution remain available.
- Do not deliberately corrupt the owner's original asset.

### 8. Repeated lifecycle and cleanup

- Repeat open, hide, show, profile change, disable, enable, and close at least
  three times, including one cycle during Live output.
- Confirm no duplicate surface, stuck mouth pose, stale animation, lost native
  focus, or unexpected microphone owner remains.
- Quit the integrated candidate and verify its app, WebKit renderer children,
  and Live helper processes stop. Verify the original user asset copies remain
  untouched.

## Result record

Record each section as `PASS`, `FAIL`, or `NOT_RUN`. A C7 human pass requires
all eight sections to pass. Any visual, audio, focus, accessibility, lifecycle,
or feature-isolation failure blocks C8. Store only the section results, bounded
timings if collected, source revisions, and sanitized failure codes.
