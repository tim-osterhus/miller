# Miller Avatar C7 owner-visible protocol

Status: `HUMAN_IN_PROGRESS_RETEST_REQUIRED`

Expected success marker: `MILLER_AVATAR_C7_HUMAN_PASS`

This protocol qualifies the optional Avatar presentation only. It does not
replace Miller v0.1.2 qualification and must not reuse the retained v0.1.2 app
as integration evidence.

## Preconditions

1. Coordinate a clean stop for any existing Miller and Gateway processes
   before replacing or launching the integrated candidate. Do not run two
   Miller app instances concurrently.
2. Build and package the candidate from the reviewed C7 Miller source and
   Miller Avatar `v0.1.0-alpha.7` at exact commit
   `34f9e58315e3f41c3202bf593276a5dd9d89cc26`. Treat a packaging script that
   executes the candidate for a smoke test as a launch and run it only after
   existing Miller processes are stopped.
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
   Miller Avatar `v0.1.0-alpha.7` at
   `34f9e58315e3f41c3202bf593276a5dd9d89cc26`, include the fixed renderer
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
- Enable Avatar and confirm one noninteractive leading surface appears without
  narrowing or covering Miller's fixed 520-point content.
- Adjust the selected profile's Avatar surface-width control across its range.
  Confirm the window resizes live, the Avatar region changes width without
  changing Miller's content width, and the setting survives a profile switch
  and application restart.
- With animation active, confirm the avatar uses the available surface without
  excessive deadspace and remains fully in frame throughout the active clip.

### 3. Typed presentation

- Submit one typed request.
- Confirm the visible states progress through the expected idle, listening,
  thinking, and terminal presentation without flicker or stale reversal.
- Replace the selected profile while idle, then during a new typed turn.
  Confirm the old surface disappears before the replacement appears and no
  old callback changes the replacement.

### 4. Real Live presentation

- Start one real Live session and speak normally.
- Continue speaking through several partial transcript updates. Confirm the
  listening animation remains one continuous action rather than restarting for
  every transcribed word.
- Confirm provider lifecycle alone does not create mouth motion.
- Confirm audible remote speech selects the speaking presentation and produces
  bounded mouth motion; silence returns neutral promptly.
- Use a response containing several sentence breaks. Confirm those short
  acoustic gaps do not restart the speaking animation; the action ends once
  when the WebRTC output buffer actually stops.
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
  normalized static rest pose without deformation, clipping, or stale spring
  state. A neutral T-pose is the current v0.1 Reduced Motion policy.
- Confirm the static pose uses the surface without excessive deadspace. Its
  scale may differ from an animated pose, but toggling Reduced Motion must not
  produce a malformed frame or repeated zoom changes.
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

Current owner-observed state before the alpha.7-integrated retest:

- Physical Tab and Shift-Tab traversal: `PASS`.
- VoiceOver traversal: `NOT_RUN`.
- Disable/re-enable, profile replacement, retry, and repeated cycles: `PASS`.
- Live speaking sentence-boundary continuity: `PASS` on the prior candidate.
- Live listening transcript-delta continuity: `FAIL_RETEST_REQUIRED` on the
  prior candidate.
- Active-motion scale/deadspace and Reduced Motion static-pose integrity:
  `FAIL_RETEST_REQUIRED` on the prior candidate.
- Per-profile Avatar surface width: `NOT_RUN` because this is new in alpha.7.
