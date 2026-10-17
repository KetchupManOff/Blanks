# Playlist Manager Enhancement Plan

## Goal

Replace the current single-list playlist editor under Settings > Audio with a persisted named-playlist manager. Players can create, rename, edit, play, and delete playlists; browse the library; play individual songs; see current playback and the active playlist; and use F1 to skip music globally without disrupting text entry or binding capture.

## Confirmed Decisions

- Entry point remains **Settings > Audio**. Replace the `Playlist Editor` command with `Playlist Manager`; it remains reachable from main-menu, pause, and results settings.
- Every playlist exposes two explicit actions: **Play In Order** makes it active and switches gameplay music to `playlist` mode; **Shuffle Playlist** makes it active and switches to `shuffle` sourced from that playlist. Selecting a library song makes it the selected track and switches to `single` mode.
- The existing Audio-category `Shuffle` setting remains library-wide for backward compatibility. Menu Music remains an independent menu-context override.
- Show concise current-song and active-playlist summaries in both the Audio category and playlist manager. Do not add a persistent gameplay-HUD element.
- Playlist names are trimmed, case-insensitively unique, and limited to 24 characters. New playlists use `New Playlist` with a numeric suffix as needed; creation opens rename, while cancelling retains the generated playlist.
- Playlist deletion requires confirmation. Deleting the active playlist switches normal playback to `single` using the current selected track or the first valid library track; deleting an inactive playlist does not change playback.
- F1 is a fixed, non-rebindable shortcut throughout menu/gameplay/pause/settings/results, except while a text-entry or binding-capture overlay owns input. It advances Playlist/Shuffle, restarts Single, and has no effect when music is Off or cannot play.

## Implementation

1. Extend the persisted audio model in `scripts/persistence/settings.gd`.
   - Bump the settings schema to v4.
   - Replace the runtime use of `music_playlist` with `music_playlists: Array` records shaped as `{id, name, tracks}`, `active_music_playlist_id: String`, and `music_shuffle_source: String` (`library` by default, `playlist` only after the manager's shuffle action); serialize all of them inside `audio`.
   - Add pure settings helpers to sanitize playlist records, resolve/get the active playlist, generate stable `playlist-N` IDs, create uniquely named playlists, rename them, replace their track arrays, and delete them.
   - Enforce structural track rules per playlist: nonempty string IDs and no duplicate track ID within one playlist. Preserve empty playlists so users can create and edit them.
   - Validate names after trimming: nonempty, max 24 characters, and unique case-insensitively except for the record being renamed. Create deterministic fallback names for malformed imported data.
   - Implement the v3-to-v4 migration: if the legacy `music_playlist` has entries, create one active `My Playlist` record containing its ordered tracks (with a suffix if needed). If it is empty, begin with no playlists. Set migrated shuffle source to `library` so existing Shuffle users retain their whole-library behavior. Consume legacy data rather than serializing it again.
   - Keep v1/v2 migration behavior by routing their loaded audio values through the same v4 conversion. Ensure reset clears named playlists and active ID.

2. Make `scripts/audio/audio_manager.gd` playlist-aware while retaining current modes and safety guarantees.
   - Update `sanitize_selection(settings)` to sanitize every playlist against the scanned library, retain non-active empty playlists, clear invalid active IDs, and repair the selected single track/menu track as today.
   - When ordered playback, or playlist-scoped shuffle, has no valid active playlist or its active playlist is empty, fall back to `single` mode using the valid selected/fallback track and reset the shuffle source to `library`; report the settings mutation to the host for persistence. This prevents silence caused by a deleted/rescanned active list while preserving intentionally empty inactive lists.
   - Source `_playlist` from the active named playlist in `apply_music_settings`. Build shuffle order from either the full library or the active playlist according to `music_shuffle_source`; retain existing no-immediate-repeat behavior, ordered advance/wrap, menu override behavior, pause behavior, preview restoration, and normalization handling.
   - Add a public `skip_current_track()` result path. Respect the menu override by restarting its explicit menu track; otherwise: advance/wrap ordered playback, progress the applicable library- or playlist-scoped shuffle order, restart Single, and reject Off/no valid target. Do not persist the transient playlist/shuffle cursor.
   - Add narrow read-only accessors for current track ID and active playback state as necessary for host/UI summaries and tests.

3. Expand `scripts/ui/game_host.gd` into the sole command boundary for the new music operations.
   - Replace the legacy `cmd_music_playlist_changed` path with commands to create, rename, update tracks, delete, play a playlist in order, shuffle a playlist, play a library track, choose library-wide shuffle from Audio settings, and skip current music. The existing Audio music-mode cycle resets the source to `library` whenever it selects Shuffle. Each command validates through settings/audio, immediately saves, applies audio settings, and returns a success/message result suitable for UI feedback.
   - Add read-only playlist accessors that expose safe copies and resolve playlist names/titles for the settings screen. Expose a formatted now-playing summary including `Off`, `No track`, title, playback mode, and `Active playlist: <name>` when applicable.
   - Reuse the existing host-owned OSK route by making its validation/context extensible for playlist names, or add a narrowly scoped playlist-name entry path with the same controller and physical-keyboard behavior. Route committed/cancelled results back to the visible settings manager and refresh it.
   - Add host-level F1 handling that ignores releases/echoes and exits when OSK or binding capture is active. Consume the event, invoke the skip command, play existing UI feedback on success, and refresh the settings summary/status when Audio or the manager is visible. Do not add F1 to player bindings or InputMap.
   - Keep UI code limited to `cmd_*` and read-only methods, as required by the host orchestration boundary.

4. Rework the playlist mode in `scripts/ui/settings_screen.gd` into a browsable manager while retaining its windowed list and controller navigation.
   - Rename the Audio command to `Playlist Manager`; add the current-song/active-playlist summary near the audio rows and include an `F1: skip` hint.
   - Make the manager landing view show: now-playing state, Create Playlist, an Existing Playlists section (active marker and track counts), and the full Library section. Window this view using the existing compact list behavior.
   - Landing interactions: Enter on a playlist opens its editor; Right plays/activates the selected playlist; Enter on a library song plays it immediately as Single. Status text must explain these controls and report every successful/blocked action.
   - Add a playlist-detail editor with **Play In Order**, **Shuffle Playlist**, Rename, Delete, ordered playlist tracks, the full library, and Back. Enter removes a selected playlist track or adds a selected library track; Left/Right reorder selected playlist tracks; retain selection anchors after mutations and show success/duplicate/empty-library feedback. Disable both playback actions for an empty playlist and explain why in the status line.
   - Add a focused delete confirmation state/rows in the settings layer. Accept deletes, Back cancels, and both return to the landing list with a deterministic selection and explicit status.
   - Preserve preview behavior as a separate temporary audition command from Audio settings; manager playback selection is permanent configuration, not preview. Closing settings continues to stop preview exactly as it does now.
   - Keep all existing theme application, responsive sizing, keyboard/controller navigation, compact rendering, and back navigation behavior intact.

5. Update documentation/comments only where the old single-playlist semantics are described, especially in source doc comments and `docs/feel-checklist.md`, so they describe named playlists, active-playlist playback, and F1 skip without changing unrelated music-library documentation.

## Test Plan

1. Extend `tests/test_settings.gd` and `tests/test_audio.gd`.
   - Verify v4 defaults, serialization round-trip, malformed-record sanitation, unique naming, ID generation, rename/delete behavior, reset behavior, and v1/v2/v3 migration of the legacy playlist without losing track order.
   - Verify rescans remove missing IDs from every named playlist, leave empty inactive lists editable, and safely repair an invalid/empty active ordered or playlist-shuffle source to Single.
   - Verify playing an active named playlist starts at its first entry and wraps in order; verify playlist-scoped shuffle draws only its tracks without an immediate repeat; verify Audio-category Shuffle remains library-wide; preserve existing Single/Menu Music behavior.
   - Verify `skip_current_track()` for Off, Single, ordered playlist wrap, library and playlist shuffle no-immediate-repeat semantics, menu override, paused playback, empty library, and first-use normalization transitions.

2. Extend `tests/test_shell.gd` and existing settings-screen coverage.
   - Cover manager entry from Audio, catalog rendering, compact windowing, create/rename/cancel, duplicate-name rejection, editor add/remove/reorder, both playlist playback actions, empty-playlist feedback, direct library-song playback, deletion confirmation, active deletion fallback, back navigation, summaries, and user-facing statuses.
   - Exercise physical keyboard and controller paths where the existing screen tests do so; ensure theme refresh still styles all added rows.
   - Verify F1 reaches the host globally in representative menu/gameplay/settings/pause contexts, is ignored by OSK and binding capture, advances the expected track/mode, and is consumed without triggering gameplay bindings.

3. Run the required full suite:
   - `godot --headless --script tests/run_tests.gd`

## Compatibility And Guardrails

- Existing settings files remain loadable; only the legacy single playlist is migrated into a named record, and all other audio/profile/display data remains untouched.
- Track IDs remain file-path/portable IDs, so rescans retain selections and playlist references whenever the existing library rules retain the ID.
- No gameplay core, online transport, controller mapping schema, or audio bus/normalization behavior changes.
- Empty or missing music folders, unreadable files, and no-playlist states remain safe no-ops with clear manager feedback.
