extends "res://tests/test_lib.gd"
## Cooperative core tests: variable-width boards, section bounds, independent
## player state, shared row completion/collapse, team progression, and the
## deterministic coop seed derivation.

const Board = preload("res://scripts/core/board.gd")
const CoopGame = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

const K = TetrominoData.Kind
const MARATHON = ModeRules.Mode.MARATHON
const SPRINT = ModeRules.Mode.SPRINT
const EMPTY = TetrominoData.EMPTY


func _new_coop(count: int = 2, mode: int = MARATHON, game_seed: int = 1234) -> RefCounted:
	return CoopGame.new(count, mode, game_seed)


func _fill_shared_row_except(g: RefCounted, y: int, except_cols: Array, value: int) -> void:
	for x in g.board.WIDTH:
		if not except_cols.has(x):
			g.debug_set_cell(x, y, value)


# ------------------------------------------------------------------- board

func test_board_variable_width() -> void:
	var b := Board.new(30)
	check_eq(b.WIDTH, 30, "custom width stored")
	check_eq(b.HEIGHT, 22, "height unchanged")
	check_eq(b.HIDDEN_ROWS, 2, "hidden rows unchanged")
	b.set_cell(29, 21, K.T)
	check_eq(b.get_cell(29, 21), K.T, "custom-width set/get round trip")
	check_eq(b.get_cell(10, 21), EMPTY, "cells stay independent")
	var default := Board.new()
	check_eq(default.WIDTH, 10, "default construction keeps 10 columns")
	var invalid := Board.new(0)
	check_eq(invalid.WIDTH, 10, "invalid width falls back to the default")


func test_full_row_detection_spans_all_sections() -> void:
	var b := Board.new(20)
	for x in 10:  # only the first section filled
		b.set_cell(x, 21, K.I)
	check_false(b.is_row_full(21), "one full section is not a shared full row")
	check_true(b.full_rows().is_empty(), "no rows listed")
	for x in 20:
		b.set_cell(x, 21, K.I)
	check_true(b.is_row_full(21), "every section filled completes the row")
	check_eq(b.full_rows(), [21], "full row listed ascending")


func test_section_placement_bounds() -> void:
	var b := Board.new(20)
	var inside: Array = [Vector2i(0, 20), Vector2i(1, 20), Vector2i(2, 20)]
	check_true(b.can_place_within(inside, 0, 9), "cells inside the section are placeable")
	var crossing: Array = [Vector2i(8, 20), Vector2i(9, 20), Vector2i(10, 20)]
	check_false(b.can_place_within(crossing, 0, 9), "crossing into the neighbor section is rejected")
	var sky: Array = [Vector2i(8, -1), Vector2i(9, -1)]
	check_true(b.can_place_within(sky, 0, 9), "sky above the section stays open")
	var sky_cross: Array = [Vector2i(9, -1), Vector2i(10, -1)]
	check_false(b.can_place_within(sky_cross, 0, 9), "section walls block the sky too")
	var floor: Array = [Vector2i(5, 22)]
	check_false(b.can_place_within(floor, 0, 9), "floor still blocks")
	b.set_cell(5, 20, K.J)
	var overlap: Array = [Vector2i(5, 20)]
	check_false(b.can_place_within(overlap, 0, 9), "locked cells block")


# -------------------------------------------------------------- construction

func test_construction_and_sections() -> void:
	var g := _new_coop(2, MARATHON, 7)
	check_eq(g.player_count, 2, "two players")
	check_eq(g.board.WIDTH, 20, "board is ten columns per player")
	check_eq(g.players.size(), 2, "one state per player")
	check_eq(g.phase, CoopGame.Phase.ACTIVE, "starts active")
	check_eq(g.players[0].section_x0, 0, "player 0 owns the left section")
	check_eq(g.players[1].section_x0, 10, "player sections are contiguous")
	var clamped := _new_coop(9, MARATHON, 1)
	check_eq(clamped.player_count, 4, "player count clamps to four")
	check_eq(clamped.board.WIDTH, 40, "four players get forty columns")


func test_pieces_spawn_inside_sections() -> void:
	var g := _new_coop(4, MARATHON, 3)
	for p in g.players:
		for c in g.current_cells(p.index):
			check(c.x >= p.section_x0 and c.x < p.section_x0 + 10, "player %d piece inside its section" % p.index)
			check(c.y <= 1, "player %d spawns in the hidden rows" % p.index)


# --------------------------------------------------------------- movement

func test_movement_confined_to_section() -> void:
	var g := _new_coop(2, MARATHON, 5)
	for i in 10:
		g.try_move(0, -1)
	check_eq(g.players[0].piece_x, 0, "player 0 stops at the board wall")
	check_false(g.try_move(0, -1), "further left rejected")

	var g2 := _new_coop(2, MARATHON, 5)
	g2.debug_spawn_piece(0, K.I, 6, 20, 0)  # horizontal I at section-local 6..9
	check_false(g2.try_move(0, 1), "piece at the section edge cannot move right")
	check_true(g2.try_move(0, -1), "moving left inside the section works")

	var g3 := _new_coop(2, MARATHON, 5)
	g3.debug_spawn_piece(1, K.I, 0, 20, 0)  # player 1 flush against player 0's section
	check_false(g3.try_move(1, -1), "player 1 cannot cross into player 0's section")
	check_true(g3.try_move(1, 1), "player 1 can move right within its section")


func test_rotation_stays_inside_section() -> void:
	var g := _new_coop(2, MARATHON, 11)
	g.debug_spawn_piece(0, K.I, 6, 18, 0)  # horizontal I occupying local 6..9
	check_true(g.rotate(0, 1), "rotation near the section edge succeeds")
	for c in g.current_cells(0):
		check(c.x >= 0 and c.x <= 9, "rotated cells stay inside the section")


# ------------------------------------------------------ independent players

func test_independent_queues() -> void:
	var g := _new_coop(2, MARATHON, 424242)
	var q0: Array[int] = g.preview_kinds(0)
	var q1: Array[int] = g.preview_kinds(1)
	check(q0 != q1, "players draw from different bag streams")
	var replay := _new_coop(2, MARATHON, 424242)
	check_eq(replay.preview_kinds(0), q0, "same seed replays player 0's queue")
	check_eq(replay.preview_kinds(1), q1, "same seed replays player 1's queue")


func test_independent_holds() -> void:
	var g := _new_coop(2, MARATHON, 99)
	var first0: int = g.players[0].piece_kind
	var first1: int = g.players[1].piece_kind
	check_true(g.hold(0), "player 0 holds")
	check_true(g.players[0].hold_used, "player 0's hold is locked")
	check_false(g.hold(0), "player 0 cannot hold twice on one piece")
	check_true(g.hold(1), "player 1 holds independently")
	check_eq(g.players[1].hold_kind, first1, "player 1's hold stores their piece")
	check_eq(g.players[0].hold_kind, first0, "player 0's hold unchanged")


func test_simultaneous_gravity() -> void:
	var g := _new_coop(3, MARATHON, 17)
	var ys: Array = []
	for p in g.players:
		ys.append(p.piece_y)
	g.tick(1.01)
	for i in g.player_count:
		check_eq(g.players[i].piece_y, ys[i] + 1, "player %d falls with shared gravity" % i)


func test_soft_drop_is_per_player() -> void:
	var g := _new_coop(2, MARATHON, 21)
	var y0: int = g.players[0].piece_y
	var y1: int = g.players[1].piece_y
	g.set_soft_drop(0, true)
	g.tick(0.05)
	check_eq(g.players[0].piece_y, y0 + 1, "player 0 soft drops")
	check_eq(g.players[1].piece_y, y1, "player 1 unaffected by player 0's soft drop")
	check_eq(g.score, 1, "soft drop cells score to the team")


# --------------------------------------------------------- shared clearing

func test_global_row_completion_and_collapse() -> void:
	var g := _new_coop(2, MARATHON, 1)
	_fill_shared_row_except(g, 21, [4, 5, 6, 7], K.I)
	g.debug_spawn_piece(0, K.I, 4, 20, 0)  # horizontal I fills local 4..7 of row 21
	g.hard_drop(0)
	check_eq(g.phase, CoopGame.Phase.CLEARING, "shared full row enters clearing")
	check_eq(g.clearing_rows(), [21], "row 21 is clearing")
	check_eq(g.lines, 1, "team line count")
	# The board is empty outside the cleared row: single plus perfect clear.
	check_eq(g.players[0].last_event.perfect_clear, true, "perfect clear spans the shared board")
	check_eq(g.score, 100 + 800, "single plus perfect-clear bonus at level 1")
	check_eq(g.players[0].piece_kind, EMPTY, "locking player waits for its spawn")
	g.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)
	check_eq(g.phase, CoopGame.Phase.ACTIVE, "clearing finishes after the delay")
	check_true(g.players[0].piece_kind != EMPTY, "locker spawned after the clear")
	for x in g.board.WIDTH:
		check_eq(g.board.get_cell(x, 21), EMPTY, "row 21 removed for both sections")


func test_partial_row_never_clears() -> void:
	var g := _new_coop(2, MARATHON, 2)
	# Player 0's ten cells of row 21 are occupied; player 1's are empty.
	for x in 10:
		g.debug_set_cell(x, 21, K.I)
	g.debug_spawn_piece(0, K.O, 4, 19, 0)
	g.hard_drop(0)
	check_eq(g.phase, CoopGame.Phase.ACTIVE, "one full section does not clear the shared row")
	check_eq(g.lines, 0, "no lines counted")
	check_eq(g.score, 0, "no clear points")


func test_clears_freeze_every_player() -> void:
	var g := _new_coop(2, MARATHON, 3)
	_fill_shared_row_except(g, 21, [4, 5, 6, 7], K.I)
	g.debug_spawn_piece(0, K.I, 4, 20, 0)
	g.hard_drop(0)
	check_eq(g.phase, CoopGame.Phase.CLEARING, "clear started")
	g.debug_spawn_piece(1, K.T, 3, 10, 0)
	var frozen_y: int = g.players[1].piece_y
	g.set_soft_drop(1, true)
	g.tick(PlayConfig.LINE_CLEAR_DELAY * 0.5)
	check_eq(g.players[1].piece_y, frozen_y, "surviving piece frozen during the clear")
	g.set_soft_drop(1, false)
	g.tick(PlayConfig.LINE_CLEAR_DELAY)
	check_eq(g.phase, CoopGame.Phase.ACTIVE, "clear resolves")
	check_eq(g.players[1].piece_y, frozen_y + 1, "survivor shifted down with the collapse")
	check_true(g.players[0].piece_kind != EMPTY, "locker resumed with a new piece")


func test_per_player_combos_shared_score() -> void:
	var g := _new_coop(2, MARATHON, 6)
	# Row 19 keeps a hole in player 1's section, rows 20/21 in player 0's.
	_fill_shared_row_except(g, 19, [14, 15, 16, 17], K.J)
	_fill_shared_row_except(g, 20, [4, 5, 6, 7], K.J)
	_fill_shared_row_except(g, 21, [4, 5, 6, 7], K.J)

	g.debug_spawn_piece(0, K.I, 4, 20, 0)
	g.hard_drop(0)
	check_eq(g.lines, 1, "first team clear")
	check_eq(g.players[0].last_event.combo, 0, "first clear of player 0's chain")
	g.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)

	g.debug_spawn_piece(0, K.I, 4, 20, 0)
	g.hard_drop(0)
	check_eq(g.lines, 2, "second team clear")
	check_eq(g.players[0].last_event.combo, 1, "player 0's chain grows independently")
	g.tick(PlayConfig.LINE_CLEAR_DELAY + 0.01)

	g.debug_spawn_piece(1, K.I, 4, 20, 0)
	g.hard_drop(1)
	check_eq(g.lines, 3, "third team clear by player 1")
	check_eq(g.players[1].last_event.combo, 0, "player 1's chain is independent")
	# Only the last cleared row remains occupied before the third lock, so
	# player 1's single also completes a perfect clear of the whole board.
	check_eq(g.players[1].last_event.perfect_clear, true, "third clear empties the shared board")
	# 100 (clear 1) + 100 + 50 combo (clear 2) + 100 + 800 PC (clear 3).
	check_eq(g.score, 1150, "all three events accumulate on the team score")
	check_eq(g.level, 1, "level unchanged below ten lines")


func test_team_level_progression() -> void:
	var g := _new_coop(2, MARATHON, 8)
	g.lines = 9
	_fill_shared_row_except(g, 21, [4, 5, 6, 7], K.I)
	g.debug_spawn_piece(0, K.I, 4, 20, 0)
	g.hard_drop(0)
	check_eq(g.lines, 10, "shared lines reach ten")
	check_eq(g.level, 2, "team levels up on shared line count")


# --------------------------------------------------------------- team loss

func test_block_out_ends_team_run() -> void:
	var g := _new_coop(2, MARATHON, 9)
	# Bury player 0's spawn area only.
	for y in 2:
		for x in 10:
			g.debug_set_cell(x, y, K.J)
	g.hold(0)
	check_eq(g.phase, CoopGame.Phase.GAME_OVER, "one player's block out ends the team run")
	var fresh := _new_coop(2, MARATHON, 9)
	fresh.tick(0.1)
	check_eq(fresh.phase, CoopGame.Phase.ACTIVE, "control game still active")


func test_lock_out_ends_team_run() -> void:
	var g := _new_coop(2, MARATHON, 10)
	# Block player 0's row 2 so their piece locks inside the hidden rows.
	for x in 10:
		g.debug_set_cell(x, 2, K.J)
	g.debug_spawn_piece(0, K.T, 3, 0, 0)
	g.hard_drop(0)
	check_eq(g.phase, CoopGame.Phase.GAME_OVER, "one player's lock out ends the team run")


# ----------------------------------------------------------------- sprint

func test_sprint_finishes_on_shared_lines() -> void:
	var g := _new_coop(2, SPRINT, 12)
	g.lines = 39
	_fill_shared_row_except(g, 21, [14, 15, 16, 17], K.I)
	g.debug_spawn_piece(1, K.I, 4, 20, 0)  # player 1 completes the final row
	g.hard_drop(1)
	check_eq(g.lines, 40, "shared line total reaches the goal")
	check_eq(g.phase, CoopGame.Phase.FINISHED, "team finishes at 40 lines")
	var frozen: float = g.elapsed
	g.tick(5.0)
	check_eq(g.elapsed, frozen, "timer frozen after the finish")


# ----------------------------------------------------------- determinism

func test_coop_seed_derivation() -> void:
	for base in [0, 1, 7, 1234, 987654321, -5]:
		var seen: Array = []
		for i in 4:
			var s: int = ModeRules.coop_seed(base, i)
			check_false(seen.has(s), "seed %d: player %d seed is fresh" % [base, i])
			seen.append(s)
			check_eq(s, ModeRules.coop_seed(base, i), "seed %d: player %d derivation is stable" % [base, i])


func test_deterministic_replay() -> void:
	var a := _new_coop(2, MARATHON, 777)
	var b := _new_coop(2, MARATHON, 777)
	for game in [a, b]:
		game.debug_spawn_piece(0, K.T, 3, 10, 0)
		game.debug_spawn_piece(1, K.L, 2, 8, 0)
		game.try_move(0, 1)
		game.rotate(1, 1)
		game.hard_drop(0)
		game.hard_drop(1)
		game.tick(PlayConfig.LINE_CLEAR_DELAY + 0.02)
		game.try_move(0, -1)
		game.hard_drop(0)
	check_eq(a.score, b.score, "same seed and actions give the same team score")
	check_eq(a.lines, b.lines, "same seed and actions give the same lines")
	check_eq(a.players[0].piece_kind, b.players[0].piece_kind, "same piece sequence per player")
	check_eq(a.players[0].piece_x, b.players[0].piece_x, "same player 0 position")
	check_eq(a.players[1].piece_x, b.players[1].piece_x, "same player 1 position")


# ---------------------------------------------------------- fuzz invariants

func test_lock_poking_above_board_survives() -> void:
	# A piece locking entirely above the board used to crash board.place()
	# on sky cells; those cells are now dropped and the team just tops out.
	var g := _new_coop(1, MARATHON, 3)
	for x in 10:
		g.debug_set_cell(x, 0, K.J)
	g.debug_spawn_piece(0, K.S, 3)  # box_y default sentinel; override below
	g.players[0].piece_y = -2  # S resting on the row-0 stack, all cells in the sky
	g.hard_drop(0)
	check_eq(g.phase, CoopGame.Phase.GAME_OVER, "lock out above the board ends the run")
	check_eq(g.board.get_cell(0, 0), K.J, "stack row 0 intact after the sky lock")


func test_random_play_invariants() -> void:
	# Deterministic fuzz: random per-player actions plus injected shared
	# clears. Pieces must stay inside their sections, never overlap the
	# stack or floor (active and ghost), through locks, clears, and
	# collapse shifts. Terminal states are skipped: a block-out spawn
	# legally overlaps the stack.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260902
	for count in [2, 4]:
		var g := _new_coop(count, MARATHON, 12345)
		var since_inject: int = 0
		for step in 200:
			if g.phase == CoopGame.Phase.GAME_OVER or g.phase == CoopGame.Phase.FINISHED:
				break
			if g.phase == CoopGame.Phase.ACTIVE:
				for p in g.players:
					if p.piece_kind == EMPTY:
						continue
					match rng.randi_range(0, 11):
						0:
							g.try_move(p.index, -1)
						1:
							g.try_move(p.index, 1)
						2:
							g.rotate(p.index, 1)
						3:
							g.rotate(p.index, -1)
						4:
							g.set_soft_drop(p.index, true)
						5:
							g.set_soft_drop(p.index, false)
						6:
							g.hold(p.index)
						7:
							g.hard_drop(p.index)
				since_inject += 1
				if since_inject >= 25 and g.phase == CoopGame.Phase.ACTIVE:
					since_inject = 0
					_inject_shared_clear(g, rng)
			_check_fuzz_invariants(g, "%dp step %d" % [count, step])
			g.tick(1.0 / 30.0)
			_check_fuzz_invariants(g, "%dp post-tick %d" % [count, step])


func _check_fuzz_invariants(g: RefCounted, tag: String) -> void:
	if g.phase == CoopGame.Phase.GAME_OVER or g.phase == CoopGame.Phase.FINISHED:
		return
	for p in g.players:
		if p.piece_kind == EMPTY:
			continue
		for c in g.current_cells(p.index):
			check(c.x >= p.section_x0 and c.x < p.section_x0 + 10, "%s: active cell %s inside P%d section" % [tag, c, p.index])
			check(c.y < g.board.HEIGHT, "%s: active cell %s above the floor" % [tag, c])
			if c.y >= 0:
				check_eq(g.board.get_cell(c.x, c.y), EMPTY, "%s: active cell %s not on the stack" % [tag, c])
		for c in g.ghost_cells(p.index):
			check(c.x >= p.section_x0 and c.x < p.section_x0 + 10, "%s: ghost cell %s inside P%d section" % [tag, c, p.index])
			check(c.y < g.board.HEIGHT, "%s: ghost cell %s above the floor" % [tag, c])
			if c.y >= 0:
				check_eq(g.board.get_cell(c.x, c.y), EMPTY, "%s: ghost cell %s not on the stack" % [tag, c])


func _inject_shared_clear(g: RefCounted, rng: RandomNumberGenerator) -> void:
	# Fill the lowest empty row fully except a 4-wide slot in a random
	# player's section and complete it. Skipped when any piece hovers at or
	# below the target row so the fill never writes under an active piece.
	var target_y := -1
	for y in g.board.HEIGHT:
		var occupied := false
		for x in g.board.WIDTH:
			if g.board.get_cell(x, y) != EMPTY:
				occupied = true
				break
		if not occupied:
			target_y = y
			break
	if target_y < 4:
		return
	for p in g.players:
		if p.piece_kind == EMPTY:
			continue
		for c in g.current_cells(p.index):
			if c.y >= target_y:
				return
	var player: int = rng.randi_range(0, g.player_count - 1)
	var x0: int = player * 10
	var hole_start: int = x0 + rng.randi_range(0, 6)
	for x in g.board.WIDTH:
		if x < hole_start or x >= hole_start + 4:
			g.debug_set_cell(x, target_y, K.J)
	for y in target_y:
		for x in range(hole_start, hole_start + 4):
			g.debug_set_cell(x, y, EMPTY)
	g.debug_spawn_piece(player, K.I, hole_start - x0, target_y - 1, 0)
	g.hard_drop(player)
