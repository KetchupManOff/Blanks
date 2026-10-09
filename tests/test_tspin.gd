extends "res://tests/test_lib.gd"
## T-Spin classification tests using fully hand-verified board scenarios.
## Each scenario: build a stack, navigate a T piece with real actions, lock,
## and assert the Guideline 3-corner classification and scoring.

const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

const K = TetrominoData.Kind
const TSPIN_NONE = 0
const TSPIN_MINI = 1
const TSPIN_FULL = 2
const MARATHON = ModeRules.Mode.MARATHON


func _new_game() -> RefCounted:
	return CoreGame.new(MARATHON, 1234)


func _soft_drop_to_rest(game: RefCounted, max_rows: int = 25) -> void:
	game.set_soft_drop(true)
	var i: int = 0
	while not game.grounded and i < max_rows:
		game.tick(0.05)
		i += 1
	game.set_soft_drop(false)
	check_true(game.grounded, "piece came to rest via soft drop")


func _setup_tsd_board(game: RefCounted) -> void:
	# Classic T-spin double slot:
	#   y=18: overhang above the left back corner (4,18)
	#   y=19: filled except cols 4,5,6 (bar row)
	#   y=20: filled except col 5 (nub row)
	game.debug_set_cell(4, 18, K.J)
	fill_row_except(game, 19, [4, 5, 6], K.J)
	fill_row_except(game, 20, [5], K.J)


func test_t_spin_double() -> void:
	var game := _new_game()
	_setup_tsd_board(game)
	game.debug_spawn_piece(K.T)
	check_true(game.try_move(1), "move right to slot column")
	_soft_drop_to_rest(game)
	check_eq(game.piece_y, 16, "T rests above the overhang")
	check_true(game.rotate(1), "rotate CW to vertical")
	check_eq(game.last_kick_index, 0, "no kick needed")
	_soft_drop_to_rest(game)
	check_eq(game.piece_y, 18, "T hangs inside the slot")
	check_true(game.rotate(1), "rotate CW into TSD position")
	check_eq(game.last_kick_index, 0, "second rotation needs no kick")
	game.hard_drop()
	var event = game.last_event
	check_eq(event.tspin, TSPIN_FULL, "TSD classified as full T-spin")
	check_eq(event.lines, 2, "two lines cleared")
	check_eq(event.base_points, 1200, "TSD base score 1200 x level 1")
	check_false(event.b2b_applied, "no back-to-back on first difficult clear")
	check_eq(event.total_points, 1200, "TSD total")
	check_eq(game.phase, CoreGame.Phase.CLEARING, "clearing phase after TSD")


func test_t_spin_mini_single() -> void:
	var game := _new_game()
	_setup_tsd_board(game)
	game.debug_spawn_piece(K.T)
	check_true(game.try_move(1), "move right to slot column")
	_soft_drop_to_rest(game)
	check_true(game.rotate(1), "rotate CW to vertical")
	_soft_drop_to_rest(game)
	check_eq(game.piece_y, 18, "T hangs inside the slot")
	check_true(game.rotate(-1), "rotate CCW back to horizontal (mini position)")
	game.hard_drop()
	var event = game.last_event
	check_eq(event.tspin, TSPIN_MINI, "mini geometry: only one front corner filled")
	check_eq(event.lines, 1, "single line cleared")
	check_eq(event.base_points, 200, "T-spin mini single scores 200")
	check_eq(event.total_points, 200, "mini single total")


func test_t_spin_zero_lines() -> void:
	var game := _new_game()
	# Same slot shape but the surrounding rows cannot complete.
	game.debug_set_cell(4, 18, K.J)
	fill_row_except(game, 19, [4, 5, 6, 9], K.J)  # only 6 cells: row stays incomplete
	game.debug_set_cell(4, 20, K.J)
	game.debug_set_cell(6, 20, K.J)
	game.debug_spawn_piece(K.T)
	check_true(game.try_move(1), "move right")
	_soft_drop_to_rest(game)
	check_true(game.rotate(1), "rotate CW to vertical")
	_soft_drop_to_rest(game)
	check_eq(game.piece_y, 18, "T hangs in slot")
	check_true(game.rotate(1), "rotate CW into spin position")
	game.hard_drop()
	var event = game.last_event
	check_eq(event.tspin, TSPIN_FULL, "full T-spin with no line clear")
	check_eq(event.lines, 0, "no lines cleared")
	check_eq(event.base_points, 400, "T-spin zero lines scores 400")
	check_eq(event.combo, -1, "combo chain untouched by zero-line lock")
	check_false(game.b2b_active, "zero-line T-spin does not start back-to-back")


func test_mini_upgraded_by_final_kick() -> void:
	var game := _new_game()
	# Mini corner geometry reachable only through the fifth kick of the 2->L
	# rotation. The piece is placed directly at its pre-rotation position.
	# Blockers kill kicks 0-3; only kick 4 (+1, +2) lands the piece.
	fill_row_except(game, 18, [4, 5], K.J)  # includes corner B at (6,18)
	fill_row_except(game, 19, [4, 5], K.J)
	fill_row_except(game, 20, [0, 5], K.J)  # includes corners C at (6,20), D at (4,20)
	game.debug_set_cell(4, 16, K.J)  # blocks kick 0
	game.debug_set_cell(5, 16, K.J)  # blocks kick 1 (and kick 2 via both)
	# T in state 2 (horizontal) at box (3,16): bar (3,17),(4,17),(5,17), nub (4,18).
	game.debug_spawn_piece(K.T, 3, 16, 2)
	check_true(game.grounded, "pre-rotation piece rests on the stack")
	check_true(game.rotate(1), "2->L rotation succeeds")
	check_eq(game.last_kick_index, 4, "only the final kick fits")
	check_eq(game.piece_state, 3, "piece now in state L")
	game.hard_drop()
	var event = game.last_event
	check_eq(event.tspin, TSPIN_FULL, "mini geometry upgraded to full by final kick")
	check_true(event.tspin_mini_upgraded, "upgrade flag set")
	check_eq(event.lines, 1, "single line cleared (row 19)")
	check_eq(event.base_points, 800, "upgraded spin scores full T-spin single 800")


func test_no_tspin_without_rotation_last() -> void:
	var game := _new_game()
	# Same board as the TSD, but the piece falls after its rotation: the spin
	# must not be recognized because the last movement was gravity.
	_setup_tsd_board(game)
	game.debug_spawn_piece(K.T)
	check_true(game.try_move(1), "move right")
	_soft_drop_to_rest(game)
	check_true(game.rotate(1), "rotate CW to vertical")
	# Drop only partway, then let natural gravity finish the descent so the
	# final movement before locking is a fall, not a rotation.
	game.set_soft_drop(true)
	var steps: int = 0
	while game.piece_y < 18 and steps < 30:
		game.tick(0.05)
		steps += 1
	game.set_soft_drop(false)
	check_eq(game.piece_y, 18, "T in slot position via gravity")
	# Rotate then fall one extra row to invalidate the spin flag: rotate into
	# the TSD position, then move down is impossible (grounded), so instead
	# rotate early and let the fall be the last action.
	game.hard_drop()
	var event = game.last_event
	# The last successful action before lock was the fall: ordinary line clear.
	check_eq(event.tspin, TSPIN_NONE, "no T-spin when gravity moved the piece last")
