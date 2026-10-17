# Manual Feel Checklist

Run through this checklist after any change to the rules engine, input layer,
menu/settings shell, or render timing. Headless tests cover rule correctness;
this checklist covers responsiveness and feel, which cannot be automated.

How to run: open the project in Godot 4, press Play (F5), pick a mode from the
main menu, and work through the items below.

## Main menu

- [ ] Arrow keys and the D-pad/stick move the selection with a visible
      selected state; Enter or controller A activates, controller B backs
      out where a back action exists.
- [ ] Space (hard drop) does not accidentally activate menu items.
- [ ] Marathon and 40-Line Sprint open the profile picker; picking a
      profile starts the correct mode, and the first connected pad routes
      to that profile (no pads needed - keyboard-only starts work).
- [ ] The main menu shows the active profile name; PROFILES opens the
      profile browser, and Settings opens with Back returning to the menu.

## Profiles and results

- [ ] The profile browser lists every profile, marks the active one, and
      shows each selected profile's five-best histories per mode
      (score-ordered for Marathon, time-ordered for Sprints, including
      co-op variants).
- [ ] Create Profile opens the on-screen keyboard: type with the physical
      keyboard or navigate the grid with D-pad/stick/A; blank and
      duplicate names are rejected with a message.
- [ ] Rename changes the profile's name everywhere (main menu summary,
      lobby, co-op tags) and survives a restart.
- [ ] A finished Marathon records on game over, a finished Sprint records
      on completion, and abandoned runs record nothing; the solo results
      subtitle shows the personal best/placement ("NEW PERSONAL BEST!"
      or "Best N (this run #K)").
- [ ] Retry records the retried run's own result; returning to the menu
      never records an unfinished run; histories keep the best five.

## Pause and settings

- [ ] Pause (Esc/P/Start) freezes the timer and all motion; the pause menu
      shows Resume, Restart, Settings, and Main Menu.
- [ ] Pause -> Settings -> Back -> Resume preserves the exact active piece,
      timer, board, hold, and previews (no new run, no timer advance).
- [ ] Returning to the main menu during an active run asks for confirmation;
      declining keeps playing.
- [ ] Retry from the results overlay starts a fresh run of the same mode
      with the same profile/controller assignment.
- [ ] Esc from the results overlay returns to the main menu.

## Bindings and settings

- [ ] Keyboard Bindings captures the next key press (with modifiers);
      Escape cancels without changing anything; mouse events are ignored;
      controller input never lands in the shared keyboard profile.
- [ ] Capturing a keyboard binding already owned by another action is
      rejected and the owning action is named.
- [ ] Delete during capture clears the latest secondary binding; the last
      binding of an action can never be removed.
- [ ] Left/Right on a keyboard binding row resets that action to its
      defaults; Reset Keyboard Bindings / Reset Controller Bindings /
      Reset All behave as labelled.
- [ ] Remapped keyboard bindings stay applied after returning to gameplay,
      restarting the game, and rebooting the machine (settings.json round
      trip).
- [ ] Controller Bindings opens the guided flow for the active profile:
      hold any pad button for two seconds (progress shows live;
      releasing or switching buttons/phones resets the hold), release to
      start, then capture one button/axis per action in order with the
      current action and progress visible.
- [ ] During guided capture, reusing an input captured for an earlier
      action is refused with the owning action named; Escape or the pad's
      B button discards the whole uncommitted sequence and nothing is
      saved; Finish saves the complete controller-only profile at once.
- [ ] No gameplay or menu action fires during the claim hold or capture.
- [ ] Guided rebinding from pause live-applies to the paused run: the new
      mapping is active immediately after saving.
- [ ] Corrupting user://settings.json (garbage text) still boots into the
      main menu with default settings; a v1 file migrates into the shared
      keyboard profile plus a Player 1 profile.
- [ ] Fullscreen toggle and window scale (1x/2x/3x) apply immediately, keep
      the 16:9 aspect, and persist across restarts.
- [ ] Volume changes apply immediately to Master/Music/SFX and persist
      across restarts; music volume only affects music, SFX volume only
      affects effects.
- [ ] Settings uses the category switcher (Controls / Display / Audio /
      Reset): every category is reachable, Back always works, and the
      content list scrolls the selection into view instead of running off
      the 720px viewport.

## Themes

- [ ] The Theme row (Settings > Display) cycles Modern Neon Arcade, Retro
      CRT, Clean Tournament, and any `user://themes/*.theme` files; the
      value shows the theme name and whether it is built-in, portable, or
      custom.
- [ ] Theme changes apply immediately to the open screen, menus, HUD,
      board, ghost, hold/next panels, and co-op sections without
      restarting or disturbing an active run (pause -> theme change ->
      resume keeps board, timer, hold, and previews).
- [ ] Reload Themes picks up files added or edited while the game runs;
      the status line reports loaded/invalid counts and the user themes
      folder path.
- [ ] A selected theme that disappears or becomes invalid falls back to
      Modern Neon Arcade, persists the repair, and shows a status message.
- [ ] All three built-in themes keep text readable against their
      backgrounds at 1280x720, in a resized window, and in fullscreen.
- [ ] A custom theme overriding only some properties inherits the rest
      from Modern Neon; invalid values fall back per property and are
      listed in the status line, never blocking startup.
- [ ] Custom piece colors stay readable against the board; unreadable
      entries fall back per piece to the default colors.
- [ ] Release builds: the export preset's non-resource include filter must
      cover `themes/*.theme` (and `themes/README.md` if it should ship);
      without it exported builds have no built-in themes and fall back to
      the Modern Neon defaults.

## Open files (exported install)

The release ships `music/`, `sfx/`, and `themes/` as plain folders beside
the executable (see `docs/MODDING.md`); the PCK only carries code and the
theme fallbacks. Verify from a clean copy of the packaged folder on a
machine without Godot installed.

- [ ] The packaged folder runs with `music/`, `sfx/`, and `themes/` beside
      the executable; the three built-in themes are selectable and the
      music library lists the shipped tracks.
- [ ] Editing a file in `themes/` and using Reload Themes applies the edit
      without restarting; a broken edited file is reported in the status
      line and the packaged built-in with the same name stays active.
- [ ] Deleting a loose theme file makes the packaged built-in with that
      name return; deleting every loose theme still leaves the three
      built-ins selectable (PCK fallback).
- [ ] Editing a track in `music/` and using Rescan Music Library applies
      it; selections and playlist entries keep pointing at the same
      tracks (ids are preserved across edits).
- [ ] Adding a new file to `music/` or `themes/` adds it after a rescan or
      reload; a new `sfx/` file replaces the sound with the same name on
      the next launch.
- [ ] Deleting the whole `music/` or `sfx/` folder leaves the game fully
      playable and silent, with no errors on startup.

## Audio

- [ ] The game boots and plays normally with no audio assets anywhere:
      missing sounds are silent no-ops, never errors.
- [ ] Menu Music (Settings > Audio) can pick a track different from the
      gameplay music: the main menu loops it, starting a run switches to
      the gameplay selection, and returning to the menu restores it.
- [ ] Menu Music set to "Follow Game Music" makes the menu use the normal
      music mode/selection; the explicit menu track keeps playing in the
      menu even when the gameplay music mode is Off.
- [ ] A menu music track that later disappears (rescan) falls back to
      "Follow Game Music" and re-saves settings without breaking anything.
- [ ] Music mode cycles Off / Single / Playlist / Shuffle and persists;
      Audio-category Shuffle always draws from the whole library, and
      selecting it resets any playlist-scoped shuffle, while Playlist
      plays the active named playlist.
- [ ] Single loops the selected track; Playlist follows the stored order
      from its first entry and wraps; Shuffle never repeats the current
      track back to back (with two or more tracks).
- [ ] The track selector lists built-in tracks first (friendly labels)
      and custom files from `user://music/` by filename; only `.ogg`,
      `.mp3`, and `.wav` files appear.
- [ ] "Rescan Music Library" picks up files added while the game runs and
      reports skipped unreadable files in the status line; rescans keep
      every named playlist's remaining entries (ids preserved in order)
      while dropping only what vanished.
- [ ] Preview plays the selected track; closing settings restores the
      previously configured playback exactly.
- [ ] The Playlist Manager (Settings > Audio) creates, renames, edits,
      plays, and deletes named playlists: creation opens rename (cancel
      keeps the generated "New Playlist" name), Enter opens a playlist's
      editor (add/remove library tracks, reorder with Left/Right),
      Left/Right on a catalog playlist plays it in order, and Enter on a
      library song plays it immediately as Single. Empty playlists stay
      valid editing targets whose playback actions explain themselves;
      deleting always asks for confirmation first, and deleting the
      active playlist falls playback back to Single with a valid track
      and the library shuffle source.
- [ ] Deleting the active playlist (or emptying it) repairs playback to
      Single through the same save path, and the manager lists stay
      navigable with a large library (windowed rendering).
- [ ] Old settings migrate cleanly: the single legacy playlist becomes
      an active "My Playlist" with its ordered entries (empty ones start
      with no playlists) and is never re-serialized in the old shape.
- [ ] The Audio category and the Playlist Manager show the current song,
      its playback mode, and the active playlist when one drives
      playback, and both refresh after a skip.
- [ ] F1 skips the current track everywhere (menu, gameplay, pause,
      settings, results) except while typing a name or capturing a
      binding: it restarts Single, advances Playlist in order and
      Shuffle (library- or playlist-scoped), restarts the menu track in
      the menu, keeps paused playback paused, and does nothing when
      music is Off or nothing can play.
- [ ] Selecting a track that later disappears falls back to the first
      valid track and re-saves settings; an empty library never breaks
      startup or the settings screen.
- [ ] Music pauses with the game and resumes at the same position.
- [ ] Menu move/confirm/back, pause, move, rotate, soft drop (once per
      press), hard drop, hold, lock, line clear, T-spin, level-up, game
      over, and sprint finish each play their own sound exactly once per
      event, in solo and in co-op (shared team events once, not per
      player).
- [ ] Unreadable custom files are skipped and shown in the settings
      status, never blocking startup.
- [ ] Normalize Custom Music defaults to ON: custom tracks play at a
      matched perceived loudness. First use of a track may analyze it
      silently (WAVs start at their original volume and normalize
      seamlessly within a moment; compressed tracks start after a short
      silent pause of at most ~15s), and the result is cached in
      `user://music_normalization.json` so later plays start normalized.
- [ ] Toggling Normalize Custom Music in settings (Enter/Left/Right)
      switches custom tracks between matched and original volume
      immediately; the Music bus volume slider, built-in tracks, and
      SFX levels are unaffected.
- [ ] Two custom tracks with deliberately different source levels play
      at a comparable level in Single, Playlist, and Shuffle, and
      playlist/shuffle transitions stay gapless while each track's gain
      is applied.
- [ ] Preview plays the selected track with the same normalization policy
      without corrupting the restore; pausing during a first-use analysis
      resumes paused (never stuck silent).
- [ ] Replacing a custom file re-measures it on the next play (only its
      cache entry is discarded); deleting a file prunes its entry on the
      next rescan; silent or corrupt custom files fall back to their
      original volume instead of breaking playback.

## Menu usability

- [ ] Menus are readable and navigable at 1280x720 and at typical desktop
      resolutions, and after resizing the window.
- [ ] Nothing behind the menus ticks: opening the main menu releases the
      previous run's board, previews, and HUD.

## Movement

- [ ] Single tap of Left/Right moves exactly one column.
- [ ] Holding Left/Right pauses briefly (DAS), then repeats smoothly (ARR).
- [ ] Tapping Left while holding Right (and vice versa) switches direction to
      the most recently pressed key without stutter.
- [ ] Releasing the newer key falls back to the still-held key immediately.
- [ ] Pieces stop flush against walls; no visual overlap with the frame.
- [ ] Holding Left against a wall for several seconds never locks the input.

## Rotation

- [ ] Rotate CW (Up/X) and CCW (Z) respond on the same frame as the keypress.
- [ ] Rotation held down does not auto-repeat.
- [ ] I piece rotates from flat-on-floor to vertical using the floor kick.
- [ ] Rotation works against both walls and on top of flat stacks.
- [ ] Rotation inside a 1-2 cell notch fails cleanly with no visual glitch.
- [ ] O piece rotation never shifts the piece.

## Drops and locking

- [ ] Hard drop (Space) locks instantly at the ghost position; the ghost and
      landing spot always match.
- [ ] Soft drop (Down/S) is clearly faster than gravity and stops at the
      stack without locking early while held.
- [ ] A grounded piece locks after roughly half a second of no input.
- [ ] Moving or rotating a grounded piece repeatedly keeps it alive but it
      still locks after ~15 manipulations (finite lock resets).
- [ ] Sliding a piece off a ledge lets it fall again instead of locking.

## Hold and previews

- [ ] Hold (C/Shift) swaps immediately; the hold panel updates on the same
      frame.
- [ ] Hold cannot be used twice on the same piece; the held piece dims.
- [ ] Holding becomes available again after the next piece locks.
- [ ] All five previews match the actual spawn order.

## Modes and flow

- [ ] Marathon starts at level 1 and the level rises every 10 lines.
- [ ] Sprint counts down from 40 and stops the timer on completion.
- [ ] Restart (R) works during play; the pause menu's Restart covers pause,
      game over, and finish.
- [ ] Pause (Esc) freezes the timer and all motion; unpausing resumes without
      lost or stuck inputs.

## Co-op

- [ ] CO-OP on the main menu opens the lobby; Esc/B returns to the menu.
- [ ] A free pad claims a slot by holding any button for two seconds
      (live progress shown); releasing opens the profile picker for that
      slot. Enter on a free slot joins it with the keyboard instead.
- [ ] Each slot joins by picking or creating a profile; a profile already
      joined in another slot is hidden and cannot join twice; joined slots
      show the profile name, pad number (or KEYBOARD), and that profile's
      drop/rotate/hold buttons.
- [ ] A joined slot can be removed (activate twice to confirm); its pad
      becomes claimable again.
- [ ] Mode toggles Marathon/Sprint; Start launches only with at least one
      joined profile and passes slot order as player order.
- [ ] Each player's fixed keyboard cluster stays the no-pad fallback;
      co-op never writes the shared keyboard profile or the profiles'
      controller bindings.
- [ ] Each player moves/rotates/drops/holds only their own piece at the same
      time on one keyboard; DAS/ARR feel matches solo per player.
- [ ] Controller input follows each slot's own profile on its claimed pad:
      two pads with different profiles control different players, and one
      pad never drives several players.
- [ ] Pieces never cross section boundaries, including wall kicks and ghost
      pieces; sections stay tinted and separated by bright dividers.
- [ ] Per-player hold/next panels above each section match their own bag
      order; hold dims after use per player. Player tags show "P# <profile
      name>".
- [ ] A row clears only when every section contributes all ten cells; one
      player's clear removes the same rows for the whole team.
- [ ] During the clear flash every player freezes, then survivors resume and
      the locker receives its next piece.
- [ ] Score, lines, level, and the timer are shared team totals; the event
      label shows which player scored (e.g. "P2  BLANKS +800").
- [ ] Any player topping out ends the team run immediately; Sprint finishes
      when the shared line total reaches 40 no matter who cleared it.
- [ ] Eligible team results record once into every participating profile
      (deduplicated), and the results text keeps the player count.
- [ ] Pause, restart, settings, retry, and results behave exactly like solo
      (pause/restart fire from any joined pad's own profile mapping).
- [ ] The board and panels fit the 1280x720 viewport for 1, 2, 3, and 4
      players, and window scales 1x through 3x keep everything visible.
- [ ] Focus loss during a coop run cancels every player's held inputs and
      pauses once; unplugging a claimed pad mid-run clears its held state
      without affecting other players and never falls back to another pad.

## Focus loss

- [ ] Alt-tabbing or clicking away while holding Left/Right/Down cancels all
      held movement; nothing keeps moving after refocusing.
- [ ] Focus loss pauses automatically and the elapsed time does not advance.
- [ ] Refocusing does not unpause by itself; Esc resumes.

## Rendering

- [ ] Pieces spawn visible in the peek area above the field frame.
- [ ] Ghost piece updates instantly after every move/rotate.
- [ ] Line clear flash is visible for its short delay, then rows collapse.
- [ ] No flicker at 60, 120, or 240 Hz monitor refresh rates.
- [ ] Window resizing scales the whole layout without clipping the board.

## Controller

- [ ] D-pad/stick moves pieces left/right with the same DAS behavior using
      the active profile's own bindings; face buttons rotate/drop/hold as
      bound for that profile.
- [ ] Menu navigation is profile-independent: A confirms, B backs out, and
      the D-pad/left stick move the selection even when a profile remaps
      those buttons to gameplay actions (stick repeats are edge-protected).
- [ ] Start pauses per the profile mapping; unplugging/replugging the
      claimed pad mid-game does not leave movement stuck and never hands
      control to a different pad or profile.

## Exit

- [ ] Closing the window exits cleanly with no error output.
