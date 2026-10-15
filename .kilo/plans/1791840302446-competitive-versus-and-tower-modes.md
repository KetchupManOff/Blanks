# Classic Versus and Tower Modes

## Confirmed Rules

- Add Classic Versus to the existing local multiplayer and relay-backed online lobby flows, requiring 2-4 joined/ready players. Add Tower to the solo profile-picker flow as well as the 2-4 player local/online lobby flows. Existing Marathon/Sprint co-op remains a 1-4 player shared-team mode.
- **Classic Versus** gives every competitor an independent 10-column board. A player is eliminated by normal block-out or lock-out; the last active player wins. Simultaneous final elimination is a draw.
- The host chooses `Garbage: On/Off` in the Versus lobby. With it off, Versus is independent survival. With it on, each attack targets every surviving opponent.
- Garbage attack table: single 0, double 1, triple 2, Tetris 4, T-spin single 2, T-spin double 4, T-spin triple 6; add one line for each combo after the first and one for a back-to-back difficult clear. Outgoing attacks first cancel the sender's queued incoming lines. Insert uncanceled lines with deterministic seeded holes before the recipient's next spawned piece.
- **Tower** is a 3-minute independent-board mode with no garbage. In multiplayer, the lowest locked-stack height at expiry wins; normal score breaks a height tie; a remaining tie is a draw. In solo, the same height and score ordering produces a best-five Tower leaderboard. Height is the occupied distance from the fixed floor to the highest locked block, excludes the active piece, and is zero for an empty board.
- Tower never top-outs at the ceiling. When a piece would enter the two top hidden rows, prepend 10 empty logical rows, translate every board/player coordinate downward, and preserve the visual floor. Recompute presentation scaling so each full board remains visible in the 720px logical viewport.
- Save multiplayer competitive outcomes as a separate per-profile match history (not in the existing top-five score/time tables), including mode, placement/winner or draw, score, Tower height, duration, player count, and Versus garbage setting. Save solo Tower in a distinct top-five leaderboard ordered by lowest height then highest score.

## Implementation Plan

1. Extend competitive configuration and mode metadata.
   - Update `scripts/core/mode_rules.gd` with stable `CLASSIC_VERSUS` and `TOWER` mode identities, labels, solo/multiplayer display descriptors, fixed Tower duration, and seed derivation shared by independent player states.
   - Keep Marathon/Sprint persistence keys and rankings unchanged. Add a solo Tower descriptor ranked by height ascending then score descending, and distinct multiplayer competitive-history descriptors instead of forcing match outcomes through `mode_key(mode, coop)`.
   - Define typed configuration data for match mode, player count, seed, and `garbage_enabled`; validate Classic Versus requires 2-4 players, permit Tower with 1 player only through the local solo path and 2-4 through multiplayer, and reject garbage for Tower.

2. Make board geometry dynamically extensible without changing legacy board behavior.
   - Update `scripts/core/board.gd` to retain the default `HEIGHT = 22` constant for normal construction while exposing mutable runtime height and variable-size snapshot validation.
   - Add a prepend-rows operation that inserts empty rows at the top, preserves all locked cells, and resizes backing storage. Migrate board iteration, collision, clearing, perfect-clear checks, and snapshot restore to runtime height.
   - Preserve current negative-y open-sky semantics for ordinary games. Tower expansion must happen before a Tower piece can lock/spawn into discarded negative space or hit the standard lock-out path.
   - Update all existing fixed-height call sites, renderers, snapshot validators, and tests to use runtime board height where they operate on a board instance.

3. Introduce a pure independent-board competitive core.
   - Add `scripts/core/competitive_game.gd` as a `RefCounted`, deterministic, host-authoritative match model. It owns one independent Tower player for solo or 2-4 independent player states for multiplayer: board, bag, active/hold/ghost state, gravity/lock state, scoring/combo/B2B, clear-delay state, elimination state, queued garbage, and per-player last clear event.
   - Reuse tetromino, SRS, scoring, fixed-step timing, and mode gravity rules rather than connecting gameplay to the scene tree. Factor only genuinely shared single-player mechanics out of `game.gd` if needed; do not alter normal solo or shared-board co-op semantics.
   - Expose player-indexed action methods matching the existing co-op input API, plus match phase, elapsed timer, active-player count, winner/draw list, per-player height, and result/placement data.
   - Apply garbage after line-clear resolution and before the recipient's next spawn, with deterministic hole generation from the match seed and attack sequence. Eliminate a player if garbage causes an unrecoverable normal spawn/block-out condition.
   - For Tower, run the shared 180-second match clock through active and clear-delay simulation; finish at zero without locking/scoring an in-flight piece afterward. Expand all relevant coordinates and active pieces when any player needs added ceiling space. Do not eliminate Tower players for ceiling contact.
   - Implement complete versioned/validated match snapshots containing config, clock, random/attack state, player states, dynamic board heights/cells, pending garbage, eliminations, placements, and winner/draw status. Reject mode, roster, geometry, or malformed-state mismatches safely.

4. Add competitive rendering and responsive layout.
   - Add a dedicated independent-board renderer/presenter path under `scripts/presentation/` rather than adapting `CoopBoardRenderer`'s shared-wide-board assumptions.
   - Render solo Tower as one centered board with its hold/next panels and height/timer HUD; render 2 players side-by-side and 3-4 players in a responsive grid, each with its own board, player tag, hold/next panels, score, elimination state, and pending-garbage indicator. Use the current theme and effects path.
   - Make each presenter recompute viewport/texture dimensions, board origin, and cell size whenever Tower height changes. Bottom-anchor the floor and scale the complete board to available vertical space so expansion is visible and not clipped by the Bloom `SubViewport`.
   - Add a competitive HUD for Tower countdown and per-player height; add Versus active/eliminated status and match-result text. Preserve existing solo and co-op HUD/presenter construction untouched.

5. Integrate local lobby, input, host lifecycle, results, and persistence.
   - Add a `TOWER` item and command to `scripts/ui/menu_controller.gd`/`scripts/ui/game_host.gd`, reusing the solo profile picker and starting a one-player Tower run. Update `scripts/ui/coop_setup_menu.gd` to cycle Marathon, Sprint, Classic Versus, and Tower; show the garbage On/Off setting only for Versus; require at least two assigned profiles for both multiplayer Tower and Versus starts with clear disabled/start-status feedback.
   - Extend `scripts/ui/game_host.gd` with a `CompetitiveGame` lifecycle parallel to `core` and `coop`: solo/multiplayer start and restart configuration retention, fixed-step ticking, player-indexed action routing, pause/focus cleanup, audio event dispatch, competitive presenter/HUD setup, results overlay, and orderly teardown.
   - Reuse `InputController` and existing 1-4 player keyboard/controller assignments. Route only player-owned actions to competitive states.
   - Extend `scripts/persistence/settings.gd`, profile UI, and result formatting to migrate existing settings non-destructively; store/display the bounded multiplayer match history separately from legacy best-run results; and add the bounded solo Tower height-then-score leaderboard.

6. Integrate relay-backed online matches.
   - Extend `scripts/online/online_service.gd`, `scripts/ui/online_menu.gd`, and `GameHost` mode cycling/start validation to publish the competitive mode and Versus garbage option in host-only lobby state and the match configuration.
   - Branch online authoritative construction between `CoopGame` and `CompetitiveGame`; retain current intent ownership, sequencing, rate limiting, roster mapping, lobby return, and disconnect behavior.
   - Send and apply the new competitive snapshots to clients, including dynamic Tower geometry. Rebuild/resize client presenters when snapshot height changes; never let clients simulate competitive state independently.
   - Keep protocol validation explicit so old/co-op-shaped or malformed match configurations/snapshots fail into the existing session error path rather than corrupting state.

7. Expand automated coverage and manual acceptance checks.
   - Add board tests for top-row prepending, coordinate/cell preservation, runtime-height clears, and dynamic snapshot validation.
   - Add competitive-core tests for one-player Tower plus 2/3/4 player construction, independent movement/hold/bags, normal elimination, final-survivor winner, simultaneous-elimination draw, garbage-off behavior, full attack table, combo/B2B, cancellation, deterministic holes, garbage-induced elimination, and snapshot round trips/rejections.
   - Add Tower tests for timer expiry, locked-only height, score tiebreak/draw, no ceiling loss, repeated expansion, active/locked coordinate translation, floor preservation, line clears after growth, and dynamic snapshot round trips.
   - Extend local shell tests for the solo Tower profile-picker/menu path and leaderboard ordering, lobby cycling, garbage visibility/persistence across retry, two-player minimum for multiplayer competitive modes, input routing, results/history, presenter resizing, and return-to-menu cleanup.
   - Extend online core/session tests through the in-memory relay for host/client 2-4 player competitive startup, host-only garbage setting, intents, Versus winner propagation, Tower timer/height outcome, dynamic-height snapshots, malformed payload rejection, and repeat-round lobby reset.
   - Run `godot --headless --script tests/run_tests.gd` and `cd relay && npm test`. Manually verify local and two-client online matches for every competitive mode/configuration, 2-4 player layout, theme changes during Tower growth, pause/retry/results, disconnect handling, and viewport scales 1x through 3x.

## Compatibility and Failure Handling

- Existing settings files remain valid; the competitive-history field is additive and absent fields default to an empty history.
- Existing Marathon/Sprint solo and shared-board co-op flow, snapshots, result ranking, and profiles retain their current behavior and keys.
- Classic Versus and multiplayer Tower are unavailable to one-player rosters; solo Tower is available only through the local solo flow. Invalid garbage/mode combinations are rejected before match start, and Tower expansion has no fixed ceiling cap.
- If a Tower board grows beyond practical visual cell size, rendering continues to scale down rather than clipping or changing game state; simulation geometry is never driven by presentation size.
