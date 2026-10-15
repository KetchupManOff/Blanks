# Online Multiplayer Reliability Plan

## Decisions

- Preserve profile privacy online: only a sanitized display name crosses the relay, never profile IDs or bindings.
- Migrate settings from schema v2 to v3 by copying the existing shared `keyboard_bindings` into **every** existing profile. New profiles receive default keyboard and controller mappings.
- Keyboard and controller mappings are both per-profile. The active profile remains the keyboard mapping installed in `InputMap` for menu/solo compatibility; local multiplayer and online gameplay poll each assigned profile's keyboard records directly so bindings cannot bleed between players.
- Online pause is host-only and global. A client pause key must not enter a local paused state; it is ignored while online (with UI copy that identifies host-only pause). Host pause/resume is replicated to all peers.
- Keep simulation host-authoritative. Do not implement gameplay prediction/rollback. Reduce perceived lag through newest-snapshot coalescing, tick-ordered application, and visual interpolation of remote authoritative state.
- Treat sounds as local presentation. Replicated scoring events use a stable authoritative revision, not recreated object instance IDs.

## Root Causes To Address

- `OnlineService` caches `display_name` in `ensure_ready()`; profile changes before create/join can leave the roster with a stale/default name.
- Profile persistence has one shared keyboard profile, while online input always selects a fixed `CoopBindings` keyboard cluster by roster slot. Neither data nor routing supports a profile-specific keyboard mapping.
- `GameHost.action_pause()` only changes local `HostState`; no protocol message synchronizes it. A paused client disables its own input while a paused host freezes simulation with clients still trying to play.
- Every snapshot rebuilds `ClearEvent` objects, while audio edge detection compares their instance IDs. The same replicated event therefore plays again for every snapshot.
- Snapshots are sent over one reliable ordered WebSocket channel and every complete snapshot is applied. There is no latest-only queueing, no applied-tick guard beyond chunk assembly, and no renderer interpolation, so queues can replay stale world state and make clients visibly trail the host.

## Implementation

1. Update profile persistence and migration in `scripts/persistence/settings.gd`.
   - Bump `SCHEMA_VERSION` to 3 and remove the owned top-level `keyboard_bindings` field from newly saved documents.
   - Extend profile records to include sanitized `keyboard_bindings` alongside `controller_bindings`; add `keyboard_bindings_for(profile_id)` plus a profile-targeted keyboard update/reset API matching the controller helpers.
   - Add explicit v2 migration: sanitize its top-level keyboard mapping once, deep-copy it into every retained profile, then resolve the active ID normally. Maintain the v1 mixed-profile migration by splitting the keyboard and controller categories into the generated default profile.
   - Preserve intentionally empty action bindings, unknown top-level settings, results, and match history. Do not persist device assignment or relay identity.

2. Make binding UI profile-targeted in `scripts/ui/profile_screen.gd`, `scripts/ui/settings_screen.gd`, and `scripts/ui/game_host.gd`.
   - Add `KEYBOARD BINDINGS` alongside `CONTROLLER BINDINGS` in a selected profile's management submenu so any profile can be edited without making it active first.
   - Change the keyboard binding page to carry a target profile ID, render its name, read/write only that profile's keyboard mappings, and reset only that profile's keyboard mappings.
   - Add host commands to open, commit, reset, and live-refresh keyboard bindings for a specific profile; retain the existing controller flow unchanged except for parallel naming/helpers.
   - Keep settings controls concise: show bindings for the active profile when entering from Settings, but route to the same profile-targeted page. Update labels and status text to say which profile is being edited.
   - Replace uses of `settings.keyboard_bindings` and the global reset test assumptions throughout UI/test code. Apply the active profile's keyboard mapping to `InputMap` after load, active-profile changes, a relevant rebind, and settings reset.

3. Replace fixed gameplay keyboard clusters with per-profile keyboard polling in `scripts/input/input_controller.gd`; retire `scripts/input/coop_bindings.gd` if it has no remaining callers.
   - Cache both sanitized keyboard and controller records for each solo/co-op slot. For online, cache only the local player's active profile on the local slot and leave remote slots non-pollable.
   - Add raw keyboard-record matching that respects physical key code and modifier fields, mirroring controller record matching without routing through shared `InputMap` actions.
   - Use each slot's cached keyboard records for movement, soft drop, single-fire actions, DAS/ARR, and input-event fast paths. Preserve per-device controller polling and remote-slot ownership guards.
   - Restrict online pause/restart handling: host uses its own profile's keyboard/controller pause mapping; clients cannot locally transition `GameHost` out of `PLAYING`; restart remains disabled online.
   - Preserve `InputMap` only for solo gameplay and menus, where the active profile is the single keyboard owner. Update comments/docstrings to remove the fixed-cluster model.

4. Fix online identity creation and validation in `scripts/online/online_service.gd`.
   - Refresh `display_name` from `GameHost.active_profile_name()` immediately before creating a room and immediately before sending the client hello, rather than relying on the earlier `READY` cache.
   - Add a protocol-safe display-name normalizer used for local and received names: trim/collapse whitespace, exclude controls/newlines, enforce the profile length limit, and fall back to a deterministic non-empty player name.
   - Continue treating the host roster as authoritative and use its roster display names in match config/player tags. Names are fixed for a running room; profile renames outside a lobby affect the next create/join flow.

5. Add host-authoritative pause replication across `scripts/online/online_net.gd`, `scripts/online/online_service.gd`, and `scripts/ui/game_host.gd`.
   - Add a host-to-client pause-state envelope carrying `paused` and a monotonically increasing match-state revision. Dispatch and validate it as host-only and `IN_MATCH`-only.
   - Have only the online host toggle pause. On each toggle, change authoritative host state, clear held local input, broadcast the state immediately, and send a structural snapshot containing the same pause/revision state.
   - On clients, apply the host pause state idempotently: open/close a passive pause overlay, pause/resume local music, clear held input on pause, and return to `PLAYING` on resume without attempting to tick the client twin.
   - Gate host intent acceptance and local input submission on the authoritative paused state. Drop/reject client intents while paused without poisoning sequence state. Focus loss on an online client only releases held controls; it must never create a local pause.
   - Ensure lifecycle methods (`online_begin_*`, result/return/leave teardown, settings return paths) clear the pause revision and restore normal input/music state.

6. Give replicated events stable identity in `scripts/core/coop_game.gd`, `scripts/core/competitive_game.gd`, and `scripts/ui/game_host.gd`.
   - Add an authoritative event revision/counter that advances exactly when a scoring/lock event is created. Include it with each player event (or the match last-event payload) in snapshots and restore it on clients.
   - Keep rebuilding value objects for HUD data if desired, but change audio edge tracking to compare the replicated revision plus player/phase rather than `Object.get_instance_id()`.
   - Maintain hard-drop lock-sound suppression consistently for snapshot-driven client events, so a client does not layer a duplicate plain lock SFX after an optimistic hard drop.
   - Keep music loop behavior and the SFX pool unchanged; the defect is repeated replicated event detection, not normal overlapping playback.

7. Make snapshots latest-only and interpolation-ready in `scripts/online/online_service.gd`, `scripts/ui/game_host.gd`, and online presenters.
   - Include/validate the authoritative simulation tick already emitted by both core snapshots, plus the match-state revision. Track the newest fully decoded snapshot ID and tick; discard duplicate, stale, and superseded complete snapshots before calling `online_apply_snapshot`.
   - Coalesce inbound periodic snapshots: retain only the newest complete state until the next client frame, while structural/pause/terminal state is applied promptly. Reset receive/coalescing state at match start, lobby return, and leave.
   - Split snapshot application from presentation timing. `GameHost` applies only tick-newer authoritative core state, maintains previous/current render samples with receive timestamps, and exposes an interpolation alpha/clamped render time for online clients.
   - Update `scripts/presentation/coop_board_renderer.gd` and `scripts/presentation/competitive_board_renderer.gd` to interpolate only safe visual state (active-piece position and transition/flash timing) between authoritative samples; locked boards, clears, holds, elimination, geometry, and all gameplay decisions remain snapped to current authoritative state. Snap immediately on structural changes, rotations, locks, clears, board-size changes, pause/resume, or missing adjacent samples.
   - Keep outbound host snapshot cadence at 50 ms initially, but correct comments that call it unreliable. The relay transport is reliable/ordered; application-level coalescing is what prevents stale visual replay.

8. Extend automated coverage.
   - `tests/test_settings.gd` and `tests/test_bindings.gd`: verify v1/v2-to-v3 migration, independent profile keyboard mappings, empty-action preservation, active `InputMap` refresh, profile-specific reset, and no controller/keyboard category leakage. Replace fixed-cluster assertions.
   - `tests/test_shell.gd`, `tests/test_coop_shell.gd`, and `tests/test_competitive_shell.gd`: exercise keyboard rebinding from profile management and Settings, local multi-profile routing, and active-profile input refresh.
   - `tests/test_online_session.gd`: use named host/client stubs to cover profile changes after `READY`, sanitized hello names, roster/player-tag propagation, host pause/resume, ignored client pause, intent rejection during pause, resume control recovery, and focus-loss release behavior.
   - Add controllable queued/delayed delivery to `scripts/online/relay_memory.gd` or a test-only relay double. Verify only the newest complete snapshot applies, old tick/snapshot IDs cannot overwrite current state, dropped partial snapshots are superseded, structural snapshots/pause arrive promptly, and host/client elapsed/tick converge after delivery resumes.
   - `tests/test_online_core.gd` and `tests/test_audio.gd`: verify stable event revisions, applying an identical snapshot repeatedly emits each lock/clear/T-spin/level/end audio edge once, and advancing only the revision emits exactly one additional event.

9. Validate the completed change.
   - Run `godot --headless --script tests/run_tests.gd`.
   - Run `npm test` in `relay/`.
   - Perform a multi-process manual pass through the production/dev relay: two profiles with different keyboard maps; keyboard and controller clients; active-profile switch before both host create and client join; host pause/resume while keys are held; client focus loss; all game modes; repeated locks/clears/hard drops; and deliberately throttled/high-latency relay traffic. Confirm player names, timers, input ownership, and state converge without repeating SFX.

## Risks And Guardrails

- Profile migration is irreversible after save: deep-copy v2's one shared map into all profiles exactly once and cover it with fixture tests before releasing.
- Keyboard conflicts are allowed across different local profiles because online peers use separate machines; when multiple profiles share one local keyboard, direct per-slot matching can intentionally drive multiple slots if configured identically. Surface this as a local co-op configuration warning rather than silently changing bindings.
- Pause envelopes and structural snapshots can arrive near each other; apply them idempotently by revision so an older snapshot never reopens input after a newer pause.
- Interpolation must be presentation-only. Never mutate `CoopGame`/`CompetitiveGame` from a client render frame or infer collisions from rendered positions.
- No host migration, account identity, binding sharing, or gameplay rollback is introduced.
