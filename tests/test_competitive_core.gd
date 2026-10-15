extends "res://tests/test_lib.gd"
## Independent-board competitive core tests: construction and validation,
## per-player isolation (bags, movement, hold), Versus eliminations and
## winner/draw ranking, the garbage economy (attack table, combo/B2B,
## cancellation, deterministic holes, garbage kills), Tower clock/growth/
## ranking, and snapshot round trips including dynamic geometry.

const CompetitiveGame = preload("res://scripts/core/competitive_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

var _seed: int = 771001


func _next_seed() -> int:
	_seed += 13
	return _seed


func _new_versus(count: int = 2, garbage: bool = true) -> RefCounted:
	return CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, _next_seed(), count, garbage)


func _new_tower(count: int = 1) -> RefCounted:
	return CompetitiveGame.new(ModeRules.Mode.TOWER, _next_seed(), count, false)


func _tick(game: RefCounted, steps: int) -> void:
	for i in steps:
		game.tick(PlayConfig.FIXED_STEP)


func _fill_rows_except(game: RefCounted, player: int, y0: int, y1: int, except_col: int) -> void:
	for y in range(y0, y1 + 1):
		for x in 10:
			if x != except_col:
				game.debug_set_cell(player, x, y, TetrominoData.Kind.I)


## Drops a vertical I piece into `col`, completing every previously filled
## row it spans (the classic deterministic blanks/double/triple setup).
func _drop_vertical_i(game: RefCounted, player: int, col: int = 9) -> void:
	game.debug_spawn_piece(player, TetrominoData.Kind.I, col - 2, 0, 1)
	game.hard_drop(player)


# ----------------------------------------------------------- construction

func test_construction_for_one_to_four_players() -> void:
	for count in [1, 2, 3, 4]:
		var mode: int = ModeRules.Mode.TOWER if count == 1 else ModeRules.Mode.CLASSIC_VERSUS
		var game := CompetitiveGame.new(mode, _next_seed(), count, false)
		check_eq(game.player_count, count, "%d-player match builds" % count)
		check_eq(game.players.size(), count, "one state per player")
		check_eq(game.active_players(), count, "everyone starts active")
		for p in game.players:
			check_eq(p.board.WIDTH, 10, "independent 10-column boards")
			check_eq(p.piece_kind != TetrominoData.EMPTY, true, "player %d spawned" % p.index)


func test_garbage_only_applies_to_versus() -> void:
	var game := _new_versus(2, true)
	check_true(game.garbage_enabled, "versus may run with garbage")
	var tower := _new_tower(2)
	check_false(tower.garbage_enabled, "tower never runs with garbage")
	# A garbage request on Tower is neutralized at construction.
	var forced := CompetitiveGame.new(ModeRules.Mode.TOWER, _next_seed(), 2, true)
	check_false(forced.garbage_enabled, "tower construction refuses garbage")


func test_independent_player_state() -> void:
	var game := _new_versus(2)
	var bag0: Array[int] = game.preview_kinds(0)
	var bag1: Array[int] = game.preview_kinds(1)
	var x1_before: int = game.players[1].piece_x
	# Moving one player never touches the other's piece or queue.
	var moved := false
	for dx in [-1, 1, -1, 1, -1, 1]:
		if game.try_move(0, dx):
			moved = true
	check_true(moved, "player 0 moved somewhere")
	check_eq(game.players[1].piece_x, x1_before, "player 1 piece untouched")
	check_eq(game.preview_kinds(0), bag0, "player 0 bag unchanged by movement")
	check_eq(game.preview_kinds(1), bag1, "player 1 bag unchanged by movement")
	# Hold works per player with separate slots.
	check_true(game.hold(0), "player 0 holds")
	check_eq(game.players[1].hold_kind, TetrominoData.EMPTY, "player 1 hold untouched")
	# Bags are player-indexed from the match seed: identical across two
	# same-seed matches, so host and client twins line up.
	var twin := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, game.seed, 2, true)
	check_eq(twin.preview_kinds(0), bag0, "same seed reproduces player 0 bag")
	check_eq(twin.preview_kinds(1), bag1, "same seed reproduces player 1 bag")


func test_deterministic_bags_differ_per_player_index() -> void:
	var game := _new_versus(4)
	var any_difference := false
	for i in 4:
		for j in range(i + 1, 4):
			if game.preview_kinds(i) != game.preview_kinds(j):
				any_difference = true
	check_true(any_difference, "player-indexed seed derivation diverges the bags")


# ------------------------------------------------------------- attack table

func test_attack_table() -> void:
	var none: int = Scoring.TSpinGrade.NONE
	check_eq(CompetitiveGame.attack_lines(none, 1, 0, false), 0, "single sends 0")
	check_eq(CompetitiveGame.attack_lines(none, 2, 0, false), 1, "double sends 1")
	check_eq(CompetitiveGame.attack_lines(none, 3, 0, false), 2, "triple sends 2")
	check_eq(CompetitiveGame.attack_lines(none, 4, 0, false), 4, "blanks clear sends 4")
	var full: int = Scoring.TSpinGrade.FULL
	check_eq(CompetitiveGame.attack_lines(full, 1, 0, false), 2, "t-spin single sends 2")
	check_eq(CompetitiveGame.attack_lines(full, 2, 0, false), 4, "t-spin double sends 4")
	check_eq(CompetitiveGame.attack_lines(full, 3, 0, false), 6, "t-spin triple sends 6")
	var mini: int = Scoring.TSpinGrade.MINI
	check_eq(CompetitiveGame.attack_lines(mini, 1, 0, false), 0, "t-spin minis are not in the table")
	check_eq(CompetitiveGame.attack_lines(full, 0, 0, false), 0, "zero-line t-spins send nothing")


func test_combo_and_b2b_attack_bonuses() -> void:
	var none: int = Scoring.TSpinGrade.NONE
	check_eq(CompetitiveGame.attack_lines(none, 1, 0, false), 0, "first clear of a combo sends no bonus")
	check_eq(CompetitiveGame.attack_lines(none, 1, 1, false), 1, "second consecutive clear adds one")
	check_eq(CompetitiveGame.attack_lines(none, 2, 2, false), 3, "combo adds on top of the base")
	check_eq(CompetitiveGame.attack_lines(none, 4, 0, true), 5, "back-to-back adds one to a blanks clear")
	check_eq(CompetitiveGame.attack_lines(none, 2, 1, true), 3, "combo and back-to-back stack")


# ----------------------------------------------------------------- garbage

func test_blanks_queues_garbage_for_every_opponent() -> void:
	var game := _new_versus(3, true)
	_fill_rows_except(game, 0, 18, 21, 9)
	_drop_vertical_i(game, 0)
	check_eq(game.players[1].pending_garbage, 4, "opponent 1 queued the full attack")
	check_eq(game.players[2].pending_garbage, 4, "opponent 2 queued the full attack")
	check_eq(game.players[0].pending_garbage, 0, "sender queues nothing to itself")
	# Garbage-off Versus never queues anything.
	var peaceful := _new_versus(3, false)
	_fill_rows_except(peaceful, 0, 18, 21, 9)
	_drop_vertical_i(peaceful, 0)
	check_eq(peaceful.players[1].pending_garbage, 0, "garbage off queues nothing")
	check_eq(peaceful.players[2].pending_garbage, 0, "garbage off queues nothing (2)")


func test_single_sends_nothing_and_doubles_send_one() -> void:
	var game := _new_versus(2, true)
	_fill_rows_except(game, 0, 21, 21, 9)
	_drop_vertical_i(game, 0)
	check_eq(game.players[1].pending_garbage, 0, "single sends 0")
	var game2 := _new_versus(2, true)
	_fill_rows_except(game2, 0, 20, 21, 9)
	_drop_vertical_i(game2, 0)
	check_eq(game2.players[1].pending_garbage, 1, "double sends 1")
	var game3 := _new_versus(2, true)
	_fill_rows_except(game3, 0, 19, 21, 9)
	_drop_vertical_i(game3, 0)
	check_eq(game3.players[1].pending_garbage, 2, "triple sends 2")


func test_attack_cancels_senders_incoming_queue_first() -> void:
	var game := _new_versus(2, true)
	# The sender already owes 3 incoming lines; a blanks clear (4) cancels those
	# first and only 1 line reaches the opponent.
	game.players[0].pending_garbage = 3
	_fill_rows_except(game, 0, 18, 21, 9)
	_drop_vertical_i(game, 0)
	check_eq(game.players[0].pending_garbage, 0, "outgoing attack canceled the incoming queue")
	check_eq(game.players[1].pending_garbage, 1, "only the uncanceled remainder is sent")
	# A larger queue swallows the whole attack.
	var game2 := _new_versus(2, true)
	game2.players[0].pending_garbage = 9
	_fill_rows_except(game2, 0, 18, 21, 9)
	_drop_vertical_i(game2, 0)
	check_eq(game2.players[0].pending_garbage, 5, "the queue keeps the leftover incoming lines")
	check_eq(game2.players[1].pending_garbage, 0, "nothing is sent when fully canceled")


func test_garbage_lands_before_next_spawn_with_deterministic_holes() -> void:
	var game := _new_versus(2, true)
	var twin := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, game.seed, 2, true)
	game.players[1].pending_garbage = 3
	twin.players[1].pending_garbage = 3
	# A lock without a clear resolves the queue immediately.
	game.debug_spawn_piece(1, TetrominoData.Kind.O, 4, 18)
	twin.debug_spawn_piece(1, TetrominoData.Kind.O, 4, 18)
	game.hard_drop(1)
	twin.hard_drop(1)
	check_eq(game.players[1].pending_garbage, 0, "queue drained at the next spawn")
	for row in 3:
		var y: int = 21 - row
		var holes: int = 0
		for x in 10:
			if game.debug_get_cell(1, x, y) == TetrominoData.EMPTY:
				holes += 1
		check_eq(holes, 1, "each garbage row has exactly one hole")
	# The hole sequence is a pure function of the seed: identical setup,
	# identical columns.
	for row in 3:
		var y: int = 21 - row
		for x in 10:
			check_eq(
				twin.debug_get_cell(1, x, y) == TetrominoData.EMPTY,
				game.debug_get_cell(1, x, y) == TetrominoData.EMPTY,
				"hole column %d matches the same-seed twin" % y
			)


func test_garbage_applies_after_clear_resolution() -> void:
	var game := _new_versus(2, true)
	game.players[0].pending_garbage = 2
	# Player 0 locks a clearing piece: the garbage must wait until the
	# clear delay resolves, not land under the flashing rows.
	_fill_rows_except(game, 0, 21, 21, 9)
	_drop_vertical_i(game, 0)
	check_eq(game.players[0].pending_garbage, 2, "garbage waits through the clear delay")
	var rows_before: int = game.players[0].board.HEIGHT
	_tick(game, int(PlayConfig.LINE_CLEAR_DELAY / PlayConfig.FIXED_STEP) + 2)
	check_eq(game.players[0].pending_garbage, 0, "garbage landed after the collapse")
	check_eq(rows_before, 22, "versus boards keep the fixed height")


func test_garbage_induced_elimination() -> void:
	var game := _new_versus(2, true)
	# A tall stack (with a well column so no row completes at the lock)
	# plus a big garbage wave pushes the spawn area under the incoming
	# rows: the next spawn is a normal block-out.
	_fill_rows_except(game, 0, 6, 21, 9)
	game.players[0].pending_garbage = 8
	game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 2)
	game.hard_drop(0)
	check_true(game.players[0].eliminated, "garbage push ends in a spawn block-out")
	# Match end is evaluated on the following tick.
	game.tick(PlayConfig.FIXED_STEP)
	check_eq(game.active_players(), 1, "the opponent survives")
	check_eq(game.phase, CompetitiveGame.Phase.FINISHED, "last survivor finishes the match")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [1], "the survivor wins")


# ------------------------------------------------------ versus eliminations

func test_lockout_eliminates_and_last_survivor_wins() -> void:
	var game := _new_versus(2)
	_fill_rows_except(game, 0, 2, 21, -1)
	# The active piece rests in the hidden rows on the full stack: locking
	# entirely above the visible field is a lock-out.
	game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	game.hard_drop(0)
	check_true(game.players[0].eliminated, "lock-out eliminates")
	check_false(game.players[1].eliminated, "the opponent is untouched")
	game.tick(PlayConfig.FIXED_STEP)
	check_eq(game.phase, CompetitiveGame.Phase.FINISHED, "match ends at one survivor")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [1], "survivor is the winner")
	check_false(result["draw"], "single winner is not a draw")
	check_eq(result["placements"], [2, 1], "placements follow the elimination order")


func test_spawn_blockout_eliminates() -> void:
	var game := _new_versus(2)
	# Fill the spawn area itself: the next spawn overlaps and dies.
	_fill_rows_except(game, 0, 0, 21, -1)
	game._spawn_from_queue(game.players[0], true)
	check_true(game.players[0].eliminated, "spawn block-out eliminates")
	game.tick(PlayConfig.FIXED_STEP)
	check_eq(game.phase, CompetitiveGame.Phase.FINISHED, "match ends immediately")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [1], "the surviving opponent wins")


func test_simultaneous_final_elimination_is_a_draw() -> void:
	var game := _new_versus(2)
	for player in 2:
		_fill_rows_except(game, player, 2, 21, -1)
		game.debug_spawn_piece(player, TetrominoData.Kind.O, 4, 0)
	# One tick locks both pieces above the visible field: same tick, so
	# the final elimination is simultaneous.
	game.tick(0.6)
	check_true(game.players[0].eliminated, "player 0 fell on the final tick")
	check_true(game.players[1].eliminated, "player 1 fell on the same tick")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [0, 1], "the draw covers both finalists")
	check_true(result["draw"], "flagged as a draw")
	check_eq(result["placements"], [1, 1], "finalists share the top placement")


func test_elimination_order_ranks_placements() -> void:
	var game := _new_versus(3)
	# Player 0 dies first, player 1 later (a real tick apart, which is
	# what "later" means to the elimination clock): placements 3, 2 and
	# the survivor takes 1.
	_fill_rows_except(game, 0, 2, 21, -1)
	game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	game.hard_drop(0)
	check_eq(game.active_players(), 2, "match continues after the first elimination")
	check_eq(game.phase, CompetitiveGame.Phase.ACTIVE, "two players keep playing")
	_tick(game, 5)
	_fill_rows_except(game, 1, 2, 21, -1)
	game.debug_spawn_piece(1, TetrominoData.Kind.O, 4, 0)
	game.hard_drop(1)
	game.tick(PlayConfig.FIXED_STEP)
	check_eq(game.phase, CompetitiveGame.Phase.FINISHED, "match ends at one survivor")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [2], "the survivor wins")
	check_eq(result["placements"], [3, 2, 1], "elimination order ranks the placements")


func test_same_tick_mid_match_eliminations_share_placement() -> void:
	var game := _new_versus(4)
	for player in [0, 1]:
		_fill_rows_except(game, player, 2, 21, -1)
		game.debug_spawn_piece(player, TetrominoData.Kind.O, 4, 0)
	# One tick locks both pieces above the visible field: the same tick
	# means the same placement, but the match continues with two left.
	game.tick(0.6)
	check_eq(game.active_players(), 2, "two players remain")
	check_eq(game.phase, CompetitiveGame.Phase.ACTIVE, "the match continues")
	check_eq(game.match_result(), {}, "unfinished matches produce no result")
	# A later elimination ranks strictly better than the shared pair.
	_tick(game, 5)
	_fill_rows_except(game, 2, 2, 21, -1)
	game.debug_spawn_piece(2, TetrominoData.Kind.O, 4, 0)
	game.hard_drop(2)
	game.tick(PlayConfig.FIXED_STEP)
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [3], "the untouched survivor wins")
	check_eq(result["placements"][0], 3, "simultaneous mid-match falls share a placement")
	check_eq(result["placements"][1], 3, "simultaneous mid-match falls share a placement (2)")
	check_eq(result["placements"][2], 2, "the later fall ranks second")
	check_eq(result["placements"][3], 1, "the survivor ranks first")


func test_versus_has_no_clock() -> void:
	var game := _new_versus(2)
	_tick(game, 120 * 60)
	check_eq(game.phase, CompetitiveGame.Phase.ACTIVE, "versus runs until eliminations")
	check_eq(game.time_remaining(), 0.0, "no countdown outside tower")


# ------------------------------------------------------------------- tower

func test_tower_clock_finishes_without_locking_the_piece() -> void:
	var game := _new_tower(1)
	check_eq(game.time_remaining(), ModeRules.TOWER_DURATION_SECONDS, "starts at the full duration")
	game.tick(ModeRules.TOWER_DURATION_SECONDS - 0.1)
	check_eq(game.phase, CompetitiveGame.Phase.ACTIVE, "still active just before expiry")
	var kind: int = game.players[0].piece_kind
	var y: int = game.players[0].piece_y
	game.tick(0.2)
	check_eq(game.phase, CompetitiveGame.Phase.FINISHED, "expiry finishes the match")
	check_eq(game.players[0].piece_kind, kind, "the in-flight piece is not locked away")
	check_eq(game.players[0].piece_y, y, "the in-flight piece is not scored or moved")
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [0], "solo tower has one ranking entry")
	check_eq(result["placements"], [1], "solo placement is first by definition")


func test_tower_height_is_locked_cells_only() -> void:
	var game := _new_tower(1)
	check_eq(game.player_height(0), 0, "empty board has zero height")
	game.debug_set_cell(0, 4, 20, TetrominoData.Kind.T)
	check_eq(game.player_height(0), 2, "floor-to-top distance of the locked stack")
	# The active piece never counts.
	var active_height: int = game.player_height(0)
	check_eq(active_height, 2, "active piece excluded from height")


func test_tower_ghost_cache_invalidates_on_piece_and_board_changes() -> void:
	var game := _new_tower(1)
	game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	var first_y: int = game.ghost_y(0)
	var player = game.players[0]
	check_eq(player.ghost_cache_result, first_y, "first query caches the landing row")
	check_eq(player.ghost_cache_board_revision, player.board.revision, "cache records board revision")
	check_eq(game.ghost_y(0), first_y, "unchanged query reuses the landing row")
	check_true(game.try_move(0, -1), "piece moves before cache invalidation check")
	game.ghost_y(0)
	check_eq(player.ghost_cache_x, player.piece_x, "piece movement refreshes the cache key")
	for x in 10:
		game.debug_set_cell(0, x, 15, TetrominoData.Kind.I)
	var blocked_y: int = game.ghost_y(0)
	check_true(blocked_y < first_y, "board mutation recomputes a nearer landing row")
	check_eq(player.ghost_cache_board_revision, player.board.revision, "refreshed cache follows board revision")


func test_tower_expands_before_ceiling_loss() -> void:
	var game := _new_tower(1)
	_fill_rows_except(game, 0, 2, 21, -1)
	game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	# The grounded hidden-row contact grows the board within the same
	# step instead of eliminating or discarding cells.
	game.tick(PlayConfig.FIXED_STEP)
	check_false(game.players[0].eliminated, "tower never eliminates for ceiling contact")
	check_eq(game.phase, CompetitiveGame.Phase.ACTIVE, "match continues")
	check_eq(game.players[0].board.HEIGHT, 32, "board grew by the tower rows")
	check_eq(game.players[0].piece_y, 10, "active piece translated down with the stack")
	# Locked cells and the floor translated together.
	for x in 10:
		check_eq(game.players[0].board.get_cell(x, 12), TetrominoData.Kind.I, "former visible top row is now mid-board")
		check_eq(game.players[0].board.get_cell(x, 31), TetrominoData.Kind.I, "floor row content preserved at the new floor")
	# Height counts locked cells only: the stack is 20 rows here (the O is
	# still in flight), and growth never changes it.
	check_eq(game.player_height(0), 20, "height is invariant under the growth")


func test_tower_repeated_expansion_and_clear_after_growth() -> void:
	var game := _new_tower(1)
	# Each O dropped from the spawn area either rests in the hidden rows
	# (growing the board within the spawn step) or stacks visibly on the
	# tower; the board never kills. The well column keeps every stack
	# row from completing during the climb.
	_fill_rows_except(game, 0, 2, 21, 9)
	for i in 6:
		game.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
		game.hard_drop(0)
	check_false(game.players[0].eliminated, "repeated ceiling contact never eliminates")
	check_true(game.players[0].board.HEIGHT > 32, "the board grew at least twice")
	# A line clear still works at the grown geometry: complete the top
	# row of the shifted stack with an O dropped into a 2-wide notch.
	var well := _new_tower(1)
	well.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	# A full stack with a 1-wide well: no row is complete, so the growth
	# and the first lock stay clear-free.
	_fill_rows_except(well, 0, 2, 21, 9)
	well.tick(PlayConfig.FIXED_STEP)
	check_eq(well.players[0].board.HEIGHT, 32, "the well board grew once")
	well.hard_drop(0)
	check_eq(well.clearing_rows(0).size(), 0, "the well keeps the first lock clear-free")
	# After the growth the stack spans rows 10..31; open a notch in row 11.
	for x in 10:
		if x != 8 and x != 9:
			well.debug_set_cell(0, x, 11, TetrominoData.Kind.I)
	well.debug_spawn_piece(0, TetrominoData.Kind.O, 8, 0)
	well.hard_drop(0)
	check_eq(well.clearing_rows(0), [11], "the notched row clears at the grown height")
	_tick(well, int(PlayConfig.LINE_CLEAR_DELAY / PlayConfig.FIXED_STEP) + 2)
	check_eq(well.clearing_rows(0).size(), 0, "the clear resolved at the grown height")
	check_eq(well.player_height(0), 21, "the cleared row left a 21-high stack")


func test_tower_ranking_height_then_score_then_draw() -> void:
	var game := _new_tower(2)
	game.debug_set_cell(0, 3, 21, TetrominoData.Kind.T)
	game.players[0].score = 100
	game.players[1].score = 500
	game.tick(ModeRules.TOWER_DURATION_SECONDS)
	var result: Dictionary = game.match_result()
	check_eq(result["winners"], [1], "the lowest stack wins")
	check_eq(result["placements"], [2, 1], "placements follow height")

	var tie := _new_tower(2)
	tie.debug_set_cell(0, 3, 21, TetrominoData.Kind.T)
	tie.debug_set_cell(1, 5, 21, TetrominoData.Kind.T)
	tie.players[0].score = 900
	tie.players[1].score = 400
	tie.tick(ModeRules.TOWER_DURATION_SECONDS)
	var tie_result: Dictionary = tie.match_result()
	check_eq(tie_result["winners"], [0], "equal height falls back to score")
	check_eq(tie_result["placements"], [1, 2], "score breaks the height tie")

	var draw := _new_tower(2)
	draw.debug_set_cell(0, 3, 21, TetrominoData.Kind.T)
	draw.debug_set_cell(1, 5, 21, TetrominoData.Kind.T)
	draw.players[0].score = 700
	draw.players[1].score = 700
	draw.tick(ModeRules.TOWER_DURATION_SECONDS)
	var draw_result: Dictionary = draw.match_result()
	check_eq(draw_result["winners"], [0, 1], "a full tie is a draw")
	check_true(draw_result["draw"], "draw flagged")
	check_eq(draw_result["placements"], [1, 1], "drawn players share the placement")


func test_tower_never_sends_garbage() -> void:
	var game := _new_tower(2)
	_fill_rows_except(game, 0, 18, 21, 9)
	_drop_vertical_i(game, 0)
	check_eq(game.players[1].pending_garbage, 0, "tower has no garbage economy")


# ---------------------------------------------------------------- snapshots

func test_snapshot_round_trip_identity() -> void:
	var game := _new_versus(2, true)
	_tick(game, 120)
	var snap: Dictionary = game.to_snapshot()
	var twin := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, game.seed, 2, true)
	check_true(twin.apply_snapshot(snap), "twin accepts the snapshot")
	check_eq(twin.to_snapshot(), snap, "applied twin serializes identically")


func test_snapshot_continues_deterministically() -> void:
	var host := _new_versus(3, true)
	_tick(host, 75)
	var snap: Dictionary = host.to_snapshot()
	var client := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, host.seed, 3, true)
	check_true(client.apply_snapshot(snap), "client accepts the host snapshot")
	_tick(host, 60)
	_tick(client, 60)
	check_eq(client.to_snapshot(), host.to_snapshot(), "post-snapshot evolution matches")


func test_snapshot_rejects_foreign_configurations() -> void:
	var game := _new_versus(2, true)
	_tick(game, 10)
	var snap: Dictionary = game.to_snapshot()
	var versus_off := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, game.seed, 2, false)
	check_false(versus_off.apply_snapshot(snap), "garbage mismatch rejected")
	var tower_twin := CompetitiveGame.new(ModeRules.Mode.TOWER, game.seed, 2, false)
	check_false(tower_twin.apply_snapshot(snap), "mode mismatch rejected")
	var small := CompetitiveGame.new(ModeRules.Mode.CLASSIC_VERSUS, game.seed, 3, true)
	check_false(small.apply_snapshot(snap), "player count mismatch rejected")
	snap["v"] = 9999
	check_false(game.apply_snapshot(snap), "bad version rejected")


func test_snapshot_rejects_malformed_payloads() -> void:
	var game := _new_versus(2, true)
	_tick(game, 10)
	check_false(game.apply_snapshot("nope"), "non-dictionary rejected")
	check_false(game.apply_snapshot({}), "empty dictionary rejected")
	var before: Dictionary = game.to_snapshot()
	var snap: Dictionary = game.to_snapshot()
	snap["players"][0] = "garbage"
	check_false(game.apply_snapshot(snap), "malformed player entry rejected")
	check_eq(game.to_snapshot(), before, "state untouched on malformed entry")
	snap = game.to_snapshot()
	snap["players"][0]["board"] = {"h": 22, "cells": PackedInt32Array()}
	check_false(game.apply_snapshot(snap), "wrong board geometry rejected")
	snap = game.to_snapshot()
	snap["players"][0]["board"] = {"h": 10, "cells": snap["players"][0]["board"]["cells"]}
	check_false(game.apply_snapshot(snap), "height below the default rejected")
	check_eq(game.to_snapshot(), before, "state untouched on geometry reject")


func test_tower_snapshot_carries_dynamic_geometry() -> void:
	var game := _new_tower(1)
	_fill_rows_except(game, 0, 2, 21, -1)
	game.tick(PlayConfig.FIXED_STEP)
	check_eq(game.players[0].board.HEIGHT, 32, "board grew before the snapshot")
	_tick(game, 20)
	var snap: Dictionary = game.to_snapshot()
	var twin := CompetitiveGame.new(ModeRules.Mode.TOWER, game.seed, 1, false)
	check_true(twin.apply_snapshot(snap), "twin accepts the grown geometry")
	check_eq(twin.players[0].board.HEIGHT, 32, "twin board resized on restore")
	check_eq(twin.to_snapshot(), snap, "grown twin serializes identically")
	_tick(twin, 30)
	_tick(game, 30)
	check_eq(twin.to_snapshot(), game.to_snapshot(), "evolution matches at the grown height")
