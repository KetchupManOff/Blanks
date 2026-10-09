extends "res://tests/test_lib.gd"
## Tetromino geometry and SRS rotation tests, including kick table verification
## against the published (y-up) Guideline data with y negated.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")

const K = TetrominoData.Kind


func _cells_as_set(cells: Array) -> Dictionary:
	var set := {}
	for c in cells:
		set[Vector2i(c.x, c.y)] = true
	return set


func _same_cells(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var set := _cells_as_set(b)
	for c in a:
		if not set.has(Vector2i(c.x, c.y)):
			return false
	return true


func test_spawn_geometry() -> void:
	# Guideline spawn shapes, box-local.
	check(_same_cells(TetrominoData.cells(K.T, 0), [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]), "T spawn shape")
	check(_same_cells(TetrominoData.cells(K.J, 0), [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]), "J spawn shape")
	check(_same_cells(TetrominoData.cells(K.L, 0), [Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]), "L spawn shape")
	check(_same_cells(TetrominoData.cells(K.S, 0), [Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1)]), "S spawn shape")
	check(_same_cells(TetrominoData.cells(K.Z, 0), [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)]), "Z spawn shape")
	check(_same_cells(TetrominoData.cells(K.I, 0), [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]), "I spawn shape")
	check(_same_cells(TetrominoData.cells(K.O, 0), [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]), "O spawn shape")


func test_rotated_geometry_matches_srs() -> void:
	# Expected SRS states, box-local, y down.
	var t_r: Array = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1)]
	var t_2: Array = [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
	var t_l: Array = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)]
	check(_same_cells(TetrominoData.cells(K.T, 1), t_r), "T state R")
	check(_same_cells(TetrominoData.cells(K.T, 2), t_2), "T state 2")
	check(_same_cells(TetrominoData.cells(K.T, 3), t_l), "T state L")

	var i_r: Array = [Vector2i(2, 0), Vector2i(2, 1), Vector2i(2, 2), Vector2i(2, 3)]
	var i_2: Array = [Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]
	var i_l: Array = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3)]
	check(_same_cells(TetrominoData.cells(K.I, 1), i_r), "I state R")
	check(_same_cells(TetrominoData.cells(K.I, 2), i_2), "I state 2")
	check(_same_cells(TetrominoData.cells(K.I, 3), i_l), "I state L")

	var s_r: Array = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 2)]
	var z_r: Array = [Vector2i(2, 0), Vector2i(2, 1), Vector2i(1, 1), Vector2i(1, 2)]
	var j_r: Array = [Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1), Vector2i(1, 2)]
	var l_r: Array = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 2)]
	check(_same_cells(TetrominoData.cells(K.S, 1), s_r), "S state R")
	check(_same_cells(TetrominoData.cells(K.Z, 1), z_r), "Z state R")
	check(_same_cells(TetrominoData.cells(K.J, 1), j_r), "J state R")
	check(_same_cells(TetrominoData.cells(K.L, 1), l_r), "L state R")


func _rotate_cw(cells: Array, size: int) -> Array:
	var out: Array = []
	for c in cells:
		out.append(Vector2i(size - 1 - c.y, c.x))
	return out


func test_rotation_states_follow_box_rotation() -> void:
	# Each stored state must equal the previous state rotated 90 degrees CW
	# inside its bounding box (y down), and CCW must walk backwards.
	for kind in [K.I, K.O, K.T, K.S, K.Z, K.J, K.L]:
		var size: int = TetrominoData.box_size(kind)
		for state in 4:
			var next_state: int = (state + 1) % 4
			var computed: Array = _rotate_cw(TetrominoData.cells(kind, state), size)
			check(
				_same_cells(computed, TetrominoData.cells(kind, next_state)),
				"kind %d: CW(state %d) matches stored state %d" % [kind, state, next_state]
			)


func test_o_piece_never_moves_under_rotation() -> void:
	var original: Array = TetrominoData.cells(K.O, 0)
	for state in 4:
		check(_same_cells(TetrominoData.cells(K.O, state), original), "O state %d identical" % state)


func _check_kick_table(kind: int, published: Dictionary) -> String:
	# published: "from-to" -> Array of Vector2i in y-UP convention.
	for key in published:
		var parts: PackedStringArray = String(key).split("-")
		var from_state: int = int(parts[0])
		var dir: int = int(parts[1]) - from_state  # +1 or -1
		var ours: Array = TetrominoData.kicks(kind, from_state, dir)
		var expected: Array = published[key]
		if ours.size() != expected.size():
			return "kick list length mismatch for " + key
		for i in ours.size():
			var exp: Vector2i = expected[i]
			if ours[i] != Vector2i(exp.x, -exp.y):
				return "kick %d of %s wrong: got %s expected (x, -y of) %s" % [i, key, str(ours[i]), str(exp)]
	return ""


func test_jlstz_kick_table_matches_guideline() -> void:
	# Published SRS wall kick data for J, L, S, T, Z (y positive is up).
	var published := {
		"0-1": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
		"1-0": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
		"1-2": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
		"2-1": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
		"2-3": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
		"3-2": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
		"3-0": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
		"0-3": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
	}
	var error: String = _check_kick_table(K.T, published)
	check_eq(error, "", "JLSTZ kick table: " + error)


func test_i_kick_table_matches_guideline() -> void:
	# Published SRS I-piece wall kick data (y positive is up).
	var published := {
		"0-1": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, -1), Vector2i(1, 2)],
		"1-0": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, 1), Vector2i(-1, -2)],
		"1-2": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, 2), Vector2i(2, -1)],
		"2-1": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, -2), Vector2i(-2, 1)],
		"2-3": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, 1), Vector2i(-1, -2)],
		"3-2": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, -1), Vector2i(1, 2)],
		"3-0": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, -2), Vector2i(-2, 1)],
		"0-3": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, 2), Vector2i(2, -1)],
	}
	var error: String = _check_kick_table(K.I, published)
	check_eq(error, "", "I kick table: " + error)


func _new_game() -> RefCounted:
	return CoreGame.new(ModeRules.Mode.MARATHON, 1234)


func test_i_floor_kick() -> void:
	var game := _new_game()
	# I lying flat on the floor, then rotated CW: must stand up via the final
	# kick (+1, -2) with its bottom cell on the floor.
	game.debug_spawn_piece(K.I, 3, 20, 0)
	var ok: bool = game.rotate(1)
	check_true(ok, "I floor rotation succeeds")
	check_eq(game.piece_state, 1, "I rotated to state R")
	check_eq(game.last_kick_index, 4, "I floor rotation used the fifth kick")
	var cells: Array = game.current_cells()
	check(_same_cells(cells, [Vector2i(6, 18), Vector2i(6, 19), Vector2i(6, 20), Vector2i(6, 21)]), "I ends vertical, bottom on floor")


func test_failed_rotation_leaves_state_unchanged() -> void:
	var game := _new_game()
	# Two-wide shaft at columns 5-6; a vertical I inside cannot rotate at all.
	fill_rect(game, 0, 0, 4, 21, K.J)
	fill_rect(game, 7, 0, 9, 21, K.J)
	game.debug_spawn_piece(K.I, 3, 18, 1)
	var ok: bool = game.rotate(1)
	check_false(ok, "rotation in tight shaft fails")
	check_eq(game.piece_state, 1, "state unchanged after failed rotation")
	check_eq(game.piece_x, 3, "x unchanged after failed rotation")
	check_eq(game.piece_y, 18, "y unchanged after failed rotation")
	check_false(game.try_move(-1), "move into wall fails")
	check_eq(game.piece_x, 3, "x unchanged after failed move")


func test_wall_moves_stop_at_edges() -> void:
	var game := _new_game()
	game.debug_spawn_piece(K.O, 0, 20, 0)
	check_false(game.try_move(-1), "O at left wall cannot move left")
	check_true(game.try_move(1), "O moves right once")
	game.debug_spawn_piece(K.O, 8, 20, 0)
	check_false(game.try_move(1), "O at right wall cannot move right")


func test_rotation_near_wall_stays_in_bounds() -> void:
	var game := _new_game()
	var wall_boxes := {K.I: 6, K.O: 8, K.T: 7, K.S: 7, K.Z: 7, K.J: 7, K.L: 7}
	for kind in wall_boxes:
		game.debug_spawn_piece(kind, wall_boxes[kind], 0, 0)
		game.rotate(1)
		game.rotate(1)
		for c in game.current_cells():
			check(c.x >= 0 and c.x < 10 and c.y >= 0, "kind %d rotated at right wall stays inside" % kind)
		game.debug_spawn_piece(kind, 0, 0, 0)
		game.rotate(-1)
		for c in game.current_cells():
			check(c.x >= 0 and c.x < 10 and c.y >= 0, "kind %d rotated at left wall stays inside" % kind)
