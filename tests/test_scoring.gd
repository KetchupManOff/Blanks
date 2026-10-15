extends "res://tests/test_lib.gd"
## Scoring and progression tests: base values, combos, back-to-back, perfect
## clears, drop points, and the ClearEvent bookkeeping.

const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

const K = TetrominoData.Kind
const TSPIN_NONE = 0
const TSPIN_MINI = 1
const TSPIN_FULL = 2
const MARATHON = ModeRules.Mode.MARATHON


func _new_game() -> RefCounted:
	return CoreGame.new(MARATHON, 4242)


func _clear_single(game: RefCounted) -> void:
	# Horizontal I completing the bottom row; leaves no residue above.
	fill_row_except(game, 21, [3, 4, 5, 6], K.I)
	game.debug_spawn_piece(K.I, 3, 20, 0)
	game.hard_drop()
	game.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)


func _clear_blanks(game: RefCounted) -> void:
	for y in [19, 20, 21]:
		fill_row_except(game, y, [], K.J)
	fill_row_except(game, 18, [3, 4, 5, 6], K.J)
	game.debug_spawn_piece(K.I, 3, 17, 0)
	game.hard_drop()
	game.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)


func _no_clear_lock(game: RefCounted) -> void:
	game.debug_spawn_piece(K.O, 0, 20, 0)
	game.hard_drop()


func test_base_points_table() -> void:
	check_eq(Scoring.base_points(TSPIN_NONE, 1, 1), 100, "single 100 x level")
	check_eq(Scoring.base_points(TSPIN_NONE, 2, 1), 300, "double 300 x level")
	check_eq(Scoring.base_points(TSPIN_NONE, 3, 1), 500, "triple 500 x level")
	check_eq(Scoring.base_points(TSPIN_NONE, 4, 1), 800, "blanks 800 x level")
	check_eq(Scoring.base_points(TSPIN_NONE, 2, 5), 1500, "double at level 5")
	check_eq(Scoring.base_points(TSPIN_FULL, 0, 1), 400, "t-spin zero lines 400")
	check_eq(Scoring.base_points(TSPIN_FULL, 1, 1), 800, "t-spin single 800")
	check_eq(Scoring.base_points(TSPIN_FULL, 2, 1), 1200, "t-spin double 1200")
	check_eq(Scoring.base_points(TSPIN_FULL, 3, 1), 1600, "t-spin triple 1600")
	check_eq(Scoring.base_points(TSPIN_FULL, 2, 3), 3600, "t-spin double at level 3")
	check_eq(Scoring.base_points(TSPIN_MINI, 0, 1), 100, "mini zero 100")
	check_eq(Scoring.base_points(TSPIN_MINI, 1, 1), 200, "mini single 200")
	check_eq(Scoring.base_points(TSPIN_MINI, 2, 1), 400, "mini double 400")


func test_difficult_clears() -> void:
	check_false(Scoring.is_difficult(TSPIN_NONE, 1), "single is ordinary")
	check_false(Scoring.is_difficult(TSPIN_NONE, 3), "triple is ordinary")
	check_true(Scoring.is_difficult(TSPIN_NONE, 4), "blanks is difficult")
	check_true(Scoring.is_difficult(TSPIN_FULL, 1), "t-spin single is difficult")
	check_true(Scoring.is_difficult(TSPIN_MINI, 2), "mini double is difficult")
	check_false(Scoring.is_difficult(TSPIN_FULL, 0), "zero-line t-spin is not a clear")
	check_false(Scoring.is_difficult(TSPIN_NONE, 0), "no clear is not difficult")


func test_combo_points_table() -> void:
	check_eq(Scoring.combo_points(0, 1), 0, "first clear has no combo bonus")
	check_eq(Scoring.combo_points(1, 1), 50, "second consecutive clear +50")
	check_eq(Scoring.combo_points(2, 1), 100, "third consecutive clear +100")
	check_eq(Scoring.combo_points(1, 3), 150, "combo scales with level")
	check_eq(Scoring.combo_points(-1, 1), 0, "no chain gives no bonus")


func test_perfect_clear_points_table() -> void:
	check_eq(Scoring.perfect_clear_points(1, 1), 800, "PC single 800")
	check_eq(Scoring.perfect_clear_points(2, 1), 1200, "PC double 1200")
	check_eq(Scoring.perfect_clear_points(3, 1), 1800, "PC triple 1800")
	check_eq(Scoring.perfect_clear_points(4, 1), 2000, "PC blanks 2000")
	check_eq(Scoring.perfect_clear_points(4, 2), 4000, "PC blanks at level 2")


func test_combo_chain_in_game() -> void:
	var game := _new_game()
	# Bystander block in the hidden row: avoids perfect-clear bonuses here.
	game.debug_set_cell(9, 0, K.J)
	_clear_single(game)
	var e1 = game.last_event
	check_eq(e1.combo, 0, "first clear starts the chain at zero")
	check_eq(e1.combo_points, 0, "no bonus on first clear")
	check_eq(e1.total_points, 100, "first single worth 100")
	_clear_single(game)
	var e2 = game.last_event
	check_eq(e2.combo, 1, "second clear combo 1")
	check_eq(e2.combo_points, 50, "combo 1 bonus 50")
	check_eq(e2.total_points, 150, "single + combo 1")
	_clear_single(game)
	var e3 = game.last_event
	check_eq(e3.combo, 2, "third clear combo 2")
	check_eq(e3.total_points, 200, "single + combo 2")
	check_eq(game.score, 450, "running score with combo chain")
	_no_clear_lock(game)
	check_eq(game.combo, -1, "lock without clear resets the chain")
	_clear_single(game)
	var e4 = game.last_event
	check_eq(e4.combo, 0, "chain restarts")
	check_eq(e4.total_points, 100, "no combo bonus after reset")
	check_eq(game.score, 550, "total score across the sequence")


func test_back_to_back_chain() -> void:
	var game := _new_game()
	# Bystander block in the hidden row: avoids perfect-clear bonuses here.
	game.debug_set_cell(9, 0, K.J)
	_clear_blanks(game)
	var e1 = game.last_event
	check_eq(e1.base_points, 800, "first blanks clear plain 800")
	check_false(e1.b2b_applied, "no b2b on first blanks clear")
	check_true(game.b2b_active, "blanks clear starts the b2b chain")
	_clear_blanks(game)
	var e2 = game.last_event
	check_true(e2.b2b_applied, "second blanks clear gets b2b")
	check_eq(e2.base_points, 1200, "b2b blanks 800 x 1.5")
	check_eq(e2.combo_points, 50, "combo also runs during b2b")
	check_eq(e2.total_points, 1250, "b2b blanks plus combo")
	_clear_single(game)
	var e3 = game.last_event
	check_false(e3.b2b_applied, "single does not get b2b")
	check_eq(e3.base_points, 100, "single plain 100")
	check_false(game.b2b_active, "single breaks the b2b chain")
	_clear_blanks(game)
	var e4 = game.last_event
	check_false(e4.b2b_applied, "blanks clear after broken chain is plain")
	check_eq(e4.base_points, 800, "plain blanks clear after chain break")


func test_b2b_survives_non_clearing_locks() -> void:
	var game := _new_game()
	_clear_blanks(game)
	_no_clear_lock(game)
	check_true(game.b2b_active, "lock without clear keeps b2b")
	_clear_blanks(game)
	check_true(game.last_event.b2b_applied, "b2b applies across non-clearing locks")


func test_perfect_clear_bonus() -> void:
	var game := _new_game()
	_clear_single(game)
	var event = game.last_event
	check_true(event.perfect_clear, "clearing the only row empties the board")
	check_eq(event.pc_points, 800, "perfect clear single +800")
	check_eq(event.total_points, 900, "single plus PC bonus")
	check_true(game.board.is_completely_empty(), "board actually empty")


func test_perfect_clear_requires_empty_board() -> void:
	var game := _new_game()
	game.debug_set_cell(9, 0, K.J)  # hidden row block survives the clear
	fill_row_except(game, 21, [3, 4, 5, 6], K.I)
	game.debug_spawn_piece(K.I, 3, 20, 0)
	game.hard_drop()
	var event = game.last_event
	check_false(event.perfect_clear, "hidden row block prevents perfect clear")
	check_eq(event.total_points, 100, "plain single")


func test_soft_drop_points() -> void:
	var game := _new_game()
	game.set_soft_drop(true)
	game.tick(0.05)  # one row at 20x speed
	check_eq(game.score, 1, "soft drop awards one point per cell")
	game.set_soft_drop(false)


func test_hard_drop_points() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.T, 3, 10, 0)
	var distance: int = game.ghost_y() - game.piece_y
	game.hard_drop()
	check_eq(game.score, 2 * distance, "hard drop awards two points per cell")


func test_level_scales_line_scores() -> void:
	var game := _new_game()
	game.lines = 10
	game.level = ModeRules.level_after_lines(MARATHON, game.lines)
	check_eq(game.level, 2, "level updated from lines")
	fill_row_except(game, 21, [5], K.I)
	game.debug_spawn_piece(K.I, 3, 18, 1)
	game.hard_drop()
	check_eq(game.last_event.base_points, 200, "single at level 2 worth 200")
