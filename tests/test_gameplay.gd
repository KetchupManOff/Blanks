extends "res://tests/test_lib.gd"
## Core gameplay state machine tests: spawn, movement, gravity, ghost, hold,
## lock delay, hard drop, top-out, line clears, and mode progression.

const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

const K = TetrominoData.Kind
const MARATHON = ModeRules.Mode.MARATHON
const SPRINT = ModeRules.Mode.SPRINT


func _new_game(mode: int = MARATHON, seed_value: int = 1234) -> RefCounted:
	return CoreGame.new(mode, seed_value)


func _soft_drop_to_rest(game: RefCounted, max_rows: int = 25) -> void:
	game.set_soft_drop(true)
	var i: int = 0
	while not game.grounded and i < max_rows:
		game.tick(0.05)
		i += 1
	game.set_soft_drop(false)
	check_true(game.grounded, "piece came to rest via soft drop")


func _cells_as_set(cells: Array) -> Dictionary:
	var set := {}
	for c in cells:
		set[Vector2i(c.x, c.y)] = true
	return set


func test_spawn_positions() -> void:
	var game := _new_game()
	for kind in [K.I, K.O, K.T, K.S, K.Z, K.J, K.L]:
		game.debug_spawn_piece(kind)
		var spawn: Vector2i = TetrominoData.spawn_box(kind)
		check_eq(game.piece_x, spawn.x, "kind %d spawns at box x" % kind)
		check_eq(game.piece_y, spawn.y, "kind %d spawns in hidden rows" % kind)
		for c in game.current_cells():
			check(c.y <= 1, "kind %d spawn cells stay in hidden buffer rows" % kind)


func test_moves_update_position() -> void:
	var game := _new_game()
	check_true(game.try_move(1), "move right succeeds on empty board")
	check_eq(game.piece_x, 4, "x updated after move")
	check_true(game.try_move(-1), "move left succeeds")
	check_eq(game.piece_x, 3, "x back at spawn column")


func test_gravity_falls_one_row_per_second_at_level_1() -> void:
	var game := _new_game()
	var y0: int = game.piece_y
	game.tick(0.99)
	check_eq(game.piece_y, y0, "piece has not fallen after 0.99s")
	game.tick(0.02)
	check_eq(game.piece_y, y0 + 1, "piece falls one row after 1.0s")


func test_soft_drop_twenty_times_faster() -> void:
	var game := _new_game()
	var y0: int = game.piece_y
	game.set_soft_drop(true)
	game.tick(0.04)
	check_eq(game.piece_y, y0, "no fall before 0.05s soft interval")
	game.tick(0.02)
	check_eq(game.piece_y, y0 + 1, "soft drop falls one row per 0.05s")


func test_ghost_position_empty_board() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T)
	# T-0 at box (3,0): bar bottom lands on row 21, so box y = 20.
	check_eq(game.ghost_y(), 20, "T ghost drops to bottom on empty board")
	game.debug_spawn_piece(K.O)
	check_eq(game.ghost_y(), 20, "O ghost drops to bottom on empty board")


func test_ghost_position_with_stack() -> void:
	var game := _new_game()
	game.debug_set_cell(4, 21, K.J)
	game.debug_set_cell(5, 21, K.J)
	game.debug_spawn_piece(K.T)
	# Bar cells (3..5, y+1): rows 21 blocked at cols 4,5, so bar rests at row 20.
	check_eq(game.ghost_y(), 19, "ghost accounts for stack height")
	var ghost: Array = game.ghost_cells()
	check_eq(_cells_as_set(ghost).size(), 4, "ghost has four cells")


func test_hard_drop_locks_at_ghost_and_scores() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T)
	var ghost_set: Dictionary = _cells_as_set(game.ghost_cells())
	var expected_score: int = 2 * (game.ghost_y() - game.piece_y)
	check_true(expected_score > 0, "hard drop travels a positive distance")
	game.hard_drop()
	for c in ghost_set.keys():
		check_eq(game.board.get_cell(c.x, c.y), K.T, "locked cell %d,%d matches ghost" % [c.x, c.y])
	check_eq(game.score, expected_score, "hard drop awards two points per cell")
	check_eq(game.phase, CoreGame.Phase.ACTIVE, "next piece spawned immediately after lock")
	check_eq(game.lines, 0, "no lines cleared on empty board")
	check_eq(game.hold_used, false, "hold availability reset after lock")


func test_hold_once_per_piece() -> void:
	var game := _new_game()
	var first_kind: int = game.piece_kind
	var next_kind: int = game.preview_kinds()[0]
	check_true(game.hold(), "first hold succeeds")
	check_eq(game.hold_kind, first_kind, "hold stores the active piece")
	check_eq(game.piece_kind, next_kind, "hold spawns the next piece")
	check_true(game.hold_used, "hold marked as used")
	check_false(game.hold(), "second hold before lock is rejected")
	check_eq(game.piece_kind, next_kind, "active piece unchanged after rejected hold")


func test_hold_swap_returns_piece() -> void:
	var game := _new_game()
	var first_kind: int = game.piece_kind
	game.hold()
	game.debug_spawn_piece(game.piece_kind, 3, 20, 0)
	game.hard_drop()
	# A new piece is active now; hold swaps back to the first piece.
	var active_before_swap: int = game.piece_kind
	check_true(game.hold(), "hold after lock succeeds")
	check_eq(game.piece_kind, first_kind, "hold returns the previously held piece")
	check_eq(game.hold_kind, active_before_swap, "hold stores the previously active piece")
	check_eq(game.piece_state, 0, "swapped piece returns in spawn state")
	check_eq(game.piece_y, 0, "swapped piece returns at spawn row")


func test_hold_resets_rotation_state() -> void:
	var game := _new_game()
	var first_kind: int = game.piece_kind
	game.hold()
	game.rotate(1)
	check_eq(game.piece_state, 1, "piece rotated before holding")
	var next_kind: int = game.preview_kinds()[0]
	game.hard_drop()
	game.hold()
	check_eq(game.piece_kind, first_kind, "swap returns the first piece")
	check_eq(game.piece_state, 0, "returned piece starts unrotated")
	check_eq(game.hold_kind, next_kind, "hold stores the locked piece")


func test_lock_delay_expires() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T, 3, 20, 0)
	check_true(game.grounded, "piece resting on floor is grounded")
	game.tick(0.49)
	check_eq(game.phase, CoreGame.Phase.ACTIVE, "piece still active at 0.49s of lock delay")
	check_eq(game.piece_y, 20, "piece has not locked yet")
	game.tick(0.02)
	check_eq(game.piece_y, 0, "piece locked at 0.5s of lock delay; next piece spawned")


func test_lock_delay_resets_on_move() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T, 3, 20, 0)
	game.tick(0.4)
	check_true(game.try_move(1), "move while grounded succeeds")
	game.tick(0.4)
	check_eq(game.piece_y, 20, "piece not locked: move reset the lock delay")
	game.tick(0.2)
	check_eq(game.piece_y, 0, "piece locked 0.5s after the last reset")


func test_lock_delay_resets_are_capped() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T, 3, 20, 0)
	# Use all 15 resets with alternating moves.
	for i in 15:
		check_true(game.try_move(1 if i % 2 == 0 else -1), "reset move %d succeeds" % i)
	check_eq(game.lock_resets_used, 15, "all lock resets consumed")
	game.tick(0.4)
	# A further move must not reset the timer any more.
	check_true(game.try_move(1), "extra move still works")
	game.tick(0.2)
	check_eq(game.piece_y, 0, "piece locks despite the extra move: resets are capped")


func test_piece_falling_off_ledge_does_not_lock_early() -> void:
	var game := _new_game()
	# A shelf at row 21 with a three-column hole at 4,5,6.
	fill_row_except(game, 21, [4, 5, 6], K.J)
	game.debug_spawn_piece(K.T, 3, 19, 0)
	# T-0 at (3,19) rests on the shelf.
	check_true(game.grounded, "T rests on shelf")
	game.try_move(1)
	# Bar now spans the hole at columns 4,5,6: it must fall, not lock.
	check_false(game.grounded, "piece over hole is airborne")
	game.tick(0.5)
	check_eq(game.phase, CoreGame.Phase.ACTIVE, "airborne piece does not lock after 0.5s")
	check_false(game.grounded, "piece still airborne before gravity interval elapses")
	game.tick(0.6)
	# The piece fell into the hole and cleared row 21.
	check_eq(game.phase, CoreGame.Phase.CLEARING, "piece fell through the hole and cleared the row")


func test_block_out_at_spawn() -> void:
	var game := _new_game()
	# Bury the spawn area completely, then hold to trigger the next spawn.
	fill_rect(game, 0, 0, 9, 1, K.J)
	game.hold()
	check_eq(game.phase, CoreGame.Phase.GAME_OVER, "block out ends the game")


func test_lock_out_above_visible_field() -> void:
	var game := _new_game()
	# Block row 2 so the active piece locks entirely within the hidden rows.
	fill_rect(game, 0, 2, 9, 2, K.J)
	game.debug_spawn_piece(K.T, 3, 0, 0)
	game.hard_drop()
	check_eq(game.phase, CoreGame.Phase.GAME_OVER, "locking fully in hidden rows ends the game")


func test_line_clear_flow() -> void:
	var game := _new_game()
	fill_row_except(game, 21, [5], K.I)
	game.debug_spawn_piece(K.I, 3, 18, 1)  # vertical I filling (5,21)
	game.hard_drop()
	check_eq(game.phase, CoreGame.Phase.CLEARING, "line clear enters clearing phase")
	check_eq(game.clearing_rows(), [21], "row 21 marked for clearing")
	check_eq(game.lines, 1, "lines counter updated")
	check_eq(game.score, 100, "single clear scores 100 at level 1")
	game.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)
	check_eq(game.phase, CoreGame.Phase.ACTIVE, "clearing finishes after the delay")
	# Row 21 was removed; the I cells above it shifted down into row 21.
	check_eq(game.board.get_cell(0, 21), TetrominoData.EMPTY, "old row 20 shifted down is empty")
	check_eq(game.board.get_cell(5, 21), K.I, "remaining I cell collapsed into row 21")
	check_eq(game.piece_y, 0, "next piece spawned after clear")


func test_multi_line_clear_counts_all() -> void:
	var game := _new_game()
	fill_row_except(game, 20, [5], K.I)
	fill_row_except(game, 21, [5], K.I)
	game.debug_spawn_piece(K.I, 3, 18, 1)  # vertical I fills (5,20) and (5,21)
	game.hard_drop()
	check_eq(game.lines, 2, "double clear counts both rows")
	check_eq(game.score, 300, "double clear scores 300")


func test_blanks_clear() -> void:
	var game := _new_game()
	# A bystander block in the hidden row keeps this from being a perfect clear.
	game.debug_set_cell(9, 0, K.J)
	# Three full rows plus a four-wide slot in the top row: the horizontal I
	# completes all four rows at once.
	for y in [19, 20, 21]:
		fill_row_except(game, y, [], K.J)
	fill_row_except(game, 18, [3, 4, 5, 6], K.J)
	game.debug_spawn_piece(K.I, 3, 17, 0)
	game.hard_drop()
	check_eq(game.lines, 4, "blanks clear counts four lines")
	check_eq(game.score, 800, "blanks clear scores 800 at level 1")
	check_eq(game.level, 1, "level unchanged below ten lines")


func test_marathon_level_progression() -> void:
	check_eq(ModeRules.level_after_lines(MARATHON, 0), 1, "start at level 1")
	check_eq(ModeRules.level_after_lines(MARATHON, 9), 1, "nine lines still level 1")
	check_eq(ModeRules.level_after_lines(MARATHON, 10), 2, "ten lines reach level 2")
	check_eq(ModeRules.level_after_lines(MARATHON, 140), 15, "140 lines reach level 15")
	check_eq(ModeRules.level_after_lines(MARATHON, 500), 15, "level capped at 15")
	check_eq(ModeRules.level_after_lines(SPRINT, 500), 1, "sprint stays at level 1")


func test_marathon_gravity_curve() -> void:
	check_eq(ModeRules.gravity_seconds(MARATHON, 1), 1.0, "level 1 gravity is 1s per row")
	var g5: float = ModeRules.gravity_seconds(MARATHON, 5)
	var g10: float = ModeRules.gravity_seconds(MARATHON, 10)
	var g15: float = ModeRules.gravity_seconds(MARATHON, 15)
	check(g5 < 1.0 and g10 < g5 and g15 < g10, "gravity accelerates with level")
	check_eq(ModeRules.gravity_seconds(MARATHON, 20), g15, "gravity clamped at level cap")
	check_eq(ModeRules.gravity_seconds(SPRINT, 1), 1.0, "sprint gravity fixed")


func test_sprint_finishes_at_forty_lines() -> void:
	var game := _new_game(SPRINT)
	game.lines = 39
	fill_row_except(game, 21, [5], K.I)
	game.debug_spawn_piece(K.I, 3, 18, 1)
	game.hard_drop()
	check_eq(game.lines, 40, "final line counted")
	check_eq(game.phase, CoreGame.Phase.FINISHED, "sprint finished at 40 lines")
	var frozen: float = game.elapsed
	game.tick(5.0)
	check_eq(game.elapsed, frozen, "elapsed time frozen after finish")


func test_marathon_does_not_finish() -> void:
	var game := _new_game(MARATHON)
	game.lines = 39
	fill_row_except(game, 21, [5], K.I)
	game.debug_spawn_piece(K.I, 3, 18, 1)
	game.hard_drop()
	check_eq(game.phase, CoreGame.Phase.CLEARING, "marathon continues past 40 lines")
	check_eq(game.level, 5, "level follows line count in marathon")


func test_deterministic_seed_replay() -> void:
	var a := _new_game(MARATHON, 777)
	var b := _new_game(MARATHON, 777)
	var actions: Array = ["r", "r", "l", "cw", "l", "cw", "r", "hd", "hd", "r", "l", "cw", "hd"]
	for action in actions:
		for game in [a, b]:
			match action:
				"cw":
					game.rotate(1)
				"hd":
					game.hard_drop()
				"r":
					game.try_move(1)
				"l":
					game.try_move(-1)
			game.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)
	check_eq(a.score, b.score, "same seed and actions give same score")
	check_eq(a.lines, b.lines, "same seed and actions give same lines")
	check_eq(a.piece_kind, b.piece_kind, "same piece sequence")
	check_eq(a.piece_x, b.piece_x, "same horizontal position")
	check_eq(a.piece_y, b.piece_y, "same vertical position")


func test_elapsed_time_accumulates_with_ticks() -> void:
	var game := _new_game()
	game.tick(0.5)
	check(absf(game.elapsed - 0.5) < 0.0001, "elapsed tracks tick delta")
	game.tick(0.25)
	check(absf(game.elapsed - 0.75) < 0.0001, "elapsed accumulates")


func test_game_over_stops_simulation() -> void:
	var game := _new_game()
	game.phase = CoreGame.Phase.GAME_OVER
	game.tick(10.0)
	check_eq(game.elapsed, 0.0, "no time passes after game over")
