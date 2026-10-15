extends RefCounted
## Independent-board competitive match engine for Classic Versus and Tower.
## Every player owns a full 10-column board, bag, piece, hold, and scoring
## chains - nothing is shared but the match clock and the garbage economy.
## Classic Versus eliminates players on normal block-out/lock-out (and on
## garbage-induced spawn block-out); the last active player wins and a
## simultaneous final elimination is a draw. Tower runs a fixed 180-second
## clock, never eliminates for ceiling contact - the board grows upward
## instead - and ranks survivors by locked stack height, then score.
## Runs without any scene-tree dependency exactly like CoreGame/CoopGame:
## the presentation layer advances it with fixed tick() steps and reads its
## state; online clients only ever apply host snapshots.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const BoardClass = preload("res://scripts/core/board.gd")
const BagRandomizer = preload("res://scripts/core/randomizer.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

enum Phase { ACTIVE, FINISHED }

const T = TetrominoData.Kind.T
const BOARD_WIDTH: int = 10
const MAX_PLAYERS: int = 4
## Tower growth: rows prepended whenever a piece would enter the current
## hidden spawn rows. Uncapped; presentation scales down instead.
const TOWER_GROW_ROWS: int = 10
const SNAPSHOT_VERSION: int = 1


## Outgoing garbage for one clear: base attack from the table, plus one
## line per combo after the first and one for a back-to-back difficult
## clear. T-spin minis send nothing (not part of the confirmed table).
static func attack_lines(tspin: int, lines: int, combo: int, b2b_applied: bool) -> int:
	var base: int = 0
	if tspin == Scoring.TSpinGrade.FULL:
		match lines:
			1: base = ModeRules.ATTACK_TSPIN_SINGLE
			2: base = ModeRules.ATTACK_TSPIN_DOUBLE
			3: base = ModeRules.ATTACK_TSPIN_TRIPLE
			_: base = 0
	else:
		match lines:
			1: base = ModeRules.ATTACK_SINGLE
			2: base = ModeRules.ATTACK_DOUBLE
			3: base = ModeRules.ATTACK_TRIPLE
			4: base = ModeRules.ATTACK_BLANKS
			_: base = 0
	var bonus: int = maxi(0, combo) + (1 if b2b_applied else 0)
	return base + bonus


class PlayerState:
	extends RefCounted
	## Per-player simulation state: one independent board, bag, active
	## piece, hold, clear-delay state, scoring chains, garbage queue, and
	## elimination bookkeeping. The match engine owns the clock and the
	## result ranking.
	var index: int = 0
	var board = null  # BoardClass, untyped to keep dynamic calls working
	var bag = null  # BagRandomizer
	var piece_kind: int = -1  # TetrominoData.EMPTY while clearing/eliminated
	var piece_state: int = 0
	var piece_x: int = 0
	var piece_y: int = 0
	var hold_kind: int = -1
	var hold_used: bool = false
	var gravity_acc: float = 0.0
	var soft_drop: bool = false
	var grounded: bool = false
	var lock_timer: float = 0.0
	var lock_resets_used: int = 0
	var spin_ready: bool = false
	var last_kick_index: int = -1
	var combo: int = -1
	var b2b_active: bool = false
	var last_event: RefCounted = null
	var score: int = 0
	var lines: int = 0
	var level: int = 1
	var clearing_rows: Array[int] = []
	var clear_timer: float = 0.0
	var eliminated: bool = false
	var eliminated_at_tick: int = -1
	var pending_garbage: int = 0
	var ghost_cache_board_revision: int = -1
	var ghost_cache_phase: int = -1
	var ghost_cache_kind: int = -1
	var ghost_cache_state: int = -1
	var ghost_cache_x: int = 0
	var ghost_cache_y: int = 0
	var ghost_cache_result: int = 0

	func _init(player_index: int) -> void:
		index = player_index


var mode: int = ModeRules.Mode.CLASSIC_VERSUS
var seed: int = 0
var player_count: int = 2
var garbage_enabled: bool = false
var players: Array = []
var phase: int = Phase.ACTIVE
var elapsed: float = 0.0
var tick_count: int = 0
var last_event_player: int = -1
# Authoritative event revision: advances exactly when a lock event is
# created; carried inside every per-player event so snapshot rebuilds on
# clients identify the same host event (fresh local instance ids never
# compare equal).
var event_revision: int = 0

## Deterministic garbage-hole PRNG (xorshift32): the hole sequence is a
## pure function of the match seed plus the attack order, so host and
## client snapshots stay interchangeable.
var _garbage_state: int = 0

## Result bookkeeping, filled when the match reaches Phase.FINISHED.
var winners: Array = []  # player indices; size 1 = winner, >1 = draw
var placements: Array = []  # per-player 1-based placement (0 until ranked)


func _init(match_mode: int = ModeRules.Mode.CLASSIC_VERSUS, match_seed: int = 0, count: int = 2, garbage: bool = false) -> void:
	mode = match_mode
	seed = match_seed
	player_count = clampi(count, 1, MAX_PLAYERS)
	garbage_enabled = garbage and mode == ModeRules.Mode.CLASSIC_VERSUS
	_garbage_state = (match_seed * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF
	if _garbage_state == 0:
		_garbage_state = 0x1F123BB5
	for i in player_count:
		var p := PlayerState.new(i)
		p.board = BoardClass.new(BOARD_WIDTH)
		# Same per-player seed derivation as coop: identical seeds and
		# rosters produce identical bags on every machine.
		p.bag = BagRandomizer.new(ModeRules.coop_seed(match_seed, i))
		players.append(p)
	for p in players:
		_spawn_from_queue(p, true)


# ---------------------------------------------------------------- helpers

func time_remaining() -> float:
	## Tower countdown (zero for other modes); never negative.
	if mode != ModeRules.Mode.TOWER:
		return 0.0
	return maxf(0.0, ModeRules.TOWER_DURATION_SECONDS - elapsed)


func active_players() -> int:
	var count: int = 0
	for p in players:
		if not p.eliminated:
			count += 1
	return count


func is_clearing(p: PlayerState) -> bool:
	return not p.clearing_rows.is_empty()


func player_height(player: int) -> int:
	## Locked-stack height of one player's board (Tower ranking metric).
	if player < 0 or player >= player_count:
		return 0
	return players[player].board.locked_height()


func player_score(player: int) -> int:
	if player < 0 or player >= player_count:
		return 0
	return players[player].score


func is_eliminated(player: int) -> bool:
	if player < 0 or player >= player_count:
		return true
	return players[player].eliminated


func pending_garbage(player: int) -> int:
	if player < 0 or player >= player_count:
		return 0
	return players[player].pending_garbage


# ---------------------------------------------------------------- simulation

func tick(delta: float) -> void:
	if phase != Phase.ACTIVE:
		return
	elapsed += delta
	tick_count += 1
	if mode == ModeRules.Mode.TOWER and elapsed >= ModeRules.TOWER_DURATION_SECONDS:
		# The clock owns the Tower ending: no piece locks or scores after
		# expiry, in-flight pieces simply freeze as they are.
		_finish_tower()
		return
	for p in players:
		if p.eliminated:
			continue
		if is_clearing(p):
			p.clear_timer -= delta
			if p.clear_timer <= 0.0:
				_resolve_clear(p)
			continue
		_apply_gravity(p, delta)
		if not p.eliminated and p.piece_kind != TetrominoData.EMPTY and p.grounded:
			p.lock_timer += delta
			if p.lock_timer >= PlayConfig.LOCK_DELAY:
				_lock_piece(p)
	_check_match_end()


func _apply_gravity(p: PlayerState, delta: float) -> void:
	var interval: float = ModeRules.gravity_seconds(mode, p.level)
	if p.soft_drop:
		interval = interval / PlayConfig.SOFT_DROP_FACTOR
	p.gravity_acc += delta
	while p.gravity_acc >= interval:
		p.gravity_acc -= interval
		if _can_move_to(p, p.piece_x, p.piece_y + 1):
			p.piece_y += 1
			p.spin_ready = false
			if p.soft_drop:
				p.score += PlayConfig.SOFT_DROP_POINTS_PER_CELL
			_update_grounded(p)
			if not p.grounded:
				p.lock_timer = 0.0
		else:
			p.gravity_acc = 0.0
			break
	_update_grounded(p)
	_tower_check_expand(p)


func _update_grounded(p: PlayerState) -> void:
	if p.piece_kind == TetrominoData.EMPTY:
		p.grounded = false
		return
	# Board-only check: grounded is pure geometry. The action guards
	# (phase/clearing) live in _can_move_to and must not leak a false
	# "grounded" into spawn bookkeeping or the Tower expansion trigger.
	p.grounded = not p.board.can_place(
		TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y + 1)
	)


func _check_match_end() -> void:
	if mode != ModeRules.Mode.CLASSIC_VERSUS:
		# Tower only ends on its clock; players never eliminate.
		return
	if active_players() <= 1:
		_finish_versus()


# ------------------------------------------------------------------ queries

func current_cells(player: int) -> Array:
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
		return []
	return TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y)


func ghost_y(player: int) -> int:
	var p: PlayerState = players[player]
	if (
		p.ghost_cache_board_revision == p.board.revision
		and p.ghost_cache_phase == phase
		and p.ghost_cache_kind == p.piece_kind
		and p.ghost_cache_state == p.piece_state
		and p.ghost_cache_x == p.piece_x
		and p.ghost_cache_y == p.piece_y
	):
		return p.ghost_cache_result
	var y: int = p.piece_y
	while _can_move_to(p, p.piece_x, y + 1):
		y += 1
	p.ghost_cache_board_revision = p.board.revision
	p.ghost_cache_phase = phase
	p.ghost_cache_kind = p.piece_kind
	p.ghost_cache_state = p.piece_state
	p.ghost_cache_x = p.piece_x
	p.ghost_cache_y = p.piece_y
	p.ghost_cache_result = y
	return y


func ghost_cells(player: int) -> Array:
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
		return []
	return TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, ghost_y(player))


func preview_kinds(player: int) -> Array[int]:
	return players[player].bag.preview(PlayConfig.PREVIEW_COUNT)


func _can_move_to(p: PlayerState, box_x: int, box_y: int) -> bool:
	if phase != Phase.ACTIVE or p.eliminated or is_clearing(p):
		return false
	if p.piece_kind == TetrominoData.EMPTY:
		return false
	return p.board.can_place(TetrominoData.board_cells(p.piece_kind, p.piece_state, box_x, box_y))


func _player_actionable(p: PlayerState) -> bool:
	return phase == Phase.ACTIVE and p != null and not p.eliminated and p.piece_kind != TetrominoData.EMPTY


# ------------------------------------------------------------------ actions
# All action methods are no-ops unless the player has an active piece in a
# running match, and failed actions leave state fully unchanged.

func try_move(player: int, dx: int) -> bool:
	if player < 0 or player >= player_count:
		return false
	var p: PlayerState = players[player]
	if not _player_actionable(p):
		return false
	if not _can_move_to(p, p.piece_x + dx, p.piece_y):
		return false
	p.piece_x += dx
	p.spin_ready = false
	_after_successful_shift(p)
	return true


func rotate(player: int, dir: int) -> bool:
	# dir: +1 clockwise, -1 counter-clockwise.
	if player < 0 or player >= player_count:
		return false
	var p: PlayerState = players[player]
	if not _player_actionable(p):
		return false
	var from_state: int = p.piece_state
	var to_state: int = wrapi(from_state + dir, 0, 4)
	var kicks: Array = TetrominoData.kicks(p.piece_kind, from_state, dir)
	var base_cells: Array = TetrominoData.board_cells(p.piece_kind, to_state, 0, 0)
	for i in kicks.size():
		var kick: Vector2i = kicks[i]
		var candidate: Array = []
		for c in base_cells:
			candidate.append(Vector2i(c.x + p.piece_x + kick.x, c.y + p.piece_y + kick.y))
		if p.board.can_place(candidate):
			p.piece_x += kick.x
			p.piece_y += kick.y
			p.piece_state = to_state
			p.spin_ready = true
			p.last_kick_index = i
			_after_successful_shift(p)
			_tower_check_expand(p)
			return true
	return false


func hard_drop(player: int) -> bool:
	if player < 0 or player >= player_count:
		return false
	var p: PlayerState = players[player]
	if not _player_actionable(p):
		return false
	var target_y: int = ghost_y(player)
	var distance: int = target_y - p.piece_y
	if distance > 0:
		p.piece_y = target_y
		p.score += distance * PlayConfig.HARD_DROP_POINTS_PER_CELL
		p.spin_ready = false
	_lock_piece(p, true)
	return true


func set_soft_drop(player: int, active: bool) -> void:
	if player < 0 or player >= player_count:
		return
	players[player].soft_drop = active


func hold(player: int) -> bool:
	if player < 0 or player >= player_count:
		return false
	var p: PlayerState = players[player]
	if not _player_actionable(p) or p.hold_used:
		return false
	p.hold_used = true
	var previous: int = p.piece_kind
	if p.hold_kind == TetrominoData.EMPTY:
		_spawn_from_queue(p, false)
	else:
		p.piece_kind = p.hold_kind
		_reset_piece_state(p)
	p.hold_kind = previous
	return true


func _after_successful_shift(p: PlayerState) -> void:
	_update_grounded(p)
	if p.grounded and p.lock_resets_used < PlayConfig.MAX_LOCK_RESETS:
		p.lock_timer = 0.0
		p.lock_resets_used += 1


func _reset_piece_state(p: PlayerState) -> void:
	var spawn: Vector2i = TetrominoData.spawn_box(p.piece_kind)
	p.piece_state = 0
	p.piece_x = spawn.x
	p.piece_y = spawn.y
	p.gravity_acc = 0.0
	p.lock_timer = 0.0
	p.lock_resets_used = 0
	p.spin_ready = false
	p.last_kick_index = -1
	_update_grounded(p)
	_tower_check_expand(p)


# -------------------------------------------------------------------- spawn

func _spawn_from_queue(p: PlayerState, reset_hold: bool) -> void:
	if p.eliminated:
		return
	p.piece_kind = p.bag.next_piece()
	if reset_hold:
		p.hold_used = false
	_reset_piece_state(p)
	if not p.board.can_place(TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y)):
		if mode == ModeRules.Mode.TOWER:
			# Ceiling contact at spawn: grow instead of dying, then retry
			# once from the standard top-of-board spawn position.
			_grow_player_board(p)
			_reset_piece_state(p)
			if p.board.can_place(TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y)):
				return
		# Block out: a spawn overlapping existing blocks eliminates the
		# player (Versus) or is unreachable (Tower - expansion above
		# always makes the spawn fit).
		_eliminate(p)


# --------------------------------------------------------------------- lock

func _lock_piece(p: PlayerState, from_hard_drop: bool = false) -> void:
	var cells: Array = TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y)
	var kind: int = p.piece_kind
	p.board.place(cells, kind)
	p.piece_kind = TetrominoData.EMPTY
	p.grounded = false
	p.lock_timer = 0.0
	p.lock_resets_used = 0

	# Lock out: piece locked entirely above the visible field. Tower never
	# eliminates for ceiling contact - expansion has already moved the
	# piece into visible space - so only Versus evaluates this.
	var lock_out: bool = true
	for c in cells:
		if c.y >= p.board.HIDDEN_ROWS:
			lock_out = false
			break

	# T-Spin classification happens before line removal (corners checked
	# with the stack intact).
	var tspin: int = Scoring.TSpinGrade.NONE
	var upgraded: bool = false
	if kind == T and p.spin_ready:
		tspin = _classify_tspin(p)
		if tspin == Scoring.TSpinGrade.MINI and p.last_kick_index == 4:
			# Guideline "mini upgrade": final-kick T-Spins count as full.
			tspin = Scoring.TSpinGrade.FULL
			upgraded = true

	var cleared: Array = p.board.full_rows()
	var event: Scoring.ClearEvent = Scoring.ClearEvent.new()
	event.lines = cleared.size()
	event.tspin = tspin
	event.tspin_mini_upgraded = upgraded
	event.level = p.level
	event.rev = event_revision + 1
	event.hard_drop = from_hard_drop
	event_revision += 1

	if not cleared.is_empty():
		var difficult: bool = Scoring.is_difficult(tspin, cleared.size())
		event.base_points = Scoring.base_points(tspin, cleared.size(), p.level)
		event.b2b_applied = difficult and p.b2b_active
		if event.b2b_applied:
			event.base_points = int(round(event.base_points * PlayConfig.B2B_MULTIPLIER))
		p.combo += 1
		event.combo = p.combo
		event.combo_points = Scoring.combo_points(p.combo, p.level)
		event.perfect_clear = p.board.is_area_empty_of_blocks_outside_rows(cleared)
		if event.perfect_clear:
			event.pc_points = Scoring.perfect_clear_points(cleared.size(), p.level)
		p.b2b_active = difficult
	else:
		if tspin != Scoring.TSpinGrade.NONE:
			event.base_points = Scoring.base_points(tspin, 0, p.level)
		p.combo = -1
		event.combo = -1

	event.total_points = event.base_points + event.combo_points + event.pc_points
	p.score += event.total_points
	p.last_event = event
	last_event_player = p.index
	p.lines += cleared.size()

	if garbage_enabled and not cleared.is_empty():
		_send_attack(p, event, cleared.size())

	if lock_out and mode == ModeRules.Mode.TOWER:
		# Tower never eliminates for ceiling contact: expansion has always
		# moved the piece into visible space before it can lock here.
		lock_out = false
	if lock_out:
		_eliminate(p)
		return
	if not cleared.is_empty():
		p.clearing_rows.clear()
		for y in cleared:
			p.clearing_rows.append(y)
		p.clear_timer = PlayConfig.LINE_CLEAR_DELAY
	else:
		_apply_pending_garbage(p)
		_spawn_from_queue(p, true)


func _resolve_clear(p: PlayerState) -> void:
	var cleared: Array = []
	for y in p.clearing_rows:
		cleared.append(y)
	p.clearing_rows = []
	p.board.clear_rows(cleared)
	# Garbage lands after the recipient's own clear resolution and before
	# the next piece spawns.
	_apply_pending_garbage(p)
	_spawn_from_queue(p, true)


# ------------------------------------------------------------------ garbage

func _send_attack(p: PlayerState, event: Scoring.ClearEvent, cleared_lines: int) -> void:
	## Computes the outgoing attack, cancels it against the sender's own
	## queued incoming lines first, then queues the remainder for every
	## surviving opponent.
	var outgoing: int = attack_lines(event.tspin, cleared_lines, event.combo, event.b2b_applied)
	if outgoing <= 0:
		return
	var canceled: int = mini(outgoing, p.pending_garbage)
	p.pending_garbage -= canceled
	outgoing -= canceled
	if outgoing <= 0:
		return
	for q in players:
		if q.index == p.index or q.eliminated:
			continue
		q.pending_garbage += outgoing


func _apply_pending_garbage(p: PlayerState) -> void:
	if not garbage_enabled or p.pending_garbage <= 0:
		return
	var count: int = p.pending_garbage
	p.pending_garbage = 0
	var holes: Array = []
	for i in count:
		holes.append(_next_garbage_hole())
	p.board.insert_garbage_rows(count, holes, TetrominoData.GARBAGE)
	# An overfilled stack now blocks the standard spawn: the upcoming
	# _spawn_from_queue resolves it as a normal Versus block-out.


func _next_garbage_hole() -> int:
	## One deterministic hole column 0..BOARD_WIDTH-1 from the match PRNG.
	var x := _garbage_state
	x ^= (x << 13) & 0xFFFFFFFF
	x &= 0xFFFFFFFF
	x ^= x >> 17
	x ^= (x << 5) & 0xFFFFFFFF
	x &= 0xFFFFFFFF
	_garbage_state = x
	return x % BOARD_WIDTH


# --------------------------------------------------------------- tower growth

func _grow_player_board(p: PlayerState) -> void:
	## Prepends TOWER_GROW_ROWS empty rows above this player's stack and
	## translates every live coordinate (active piece, ghost anchor, and
	## pending line-clear rows) down with it. The floor and the stack keep
	## their relative alignment, so locked height is invariant.
	var rows: int = TOWER_GROW_ROWS
	p.board.prepend_rows(rows)
	p.piece_y += rows
	p.lock_timer = 0.0
	p.gravity_acc = 0.0
	for i in p.clearing_rows.size():
		p.clearing_rows[i] += rows
	_update_grounded(p)


func _tower_check_expand(p: PlayerState) -> void:
	## Tower ceiling rule: expand before a piece can be locked or spawned
	## into discarded negative space or hit the lock-out path. The trigger
	## is a grounded piece resting in the hidden spawn rows, or any piece
	## cell already above row zero (an upward kick near the ceiling).
	if mode != ModeRules.Mode.TOWER or p.eliminated:
		return
	if p.piece_kind == TetrominoData.EMPTY or is_clearing(p):
		return
	var hidden_contact: bool = false
	var above_top: bool = false
	for c in TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y):
		if c.y < 0:
			above_top = true
			break
		if c.y < p.board.HIDDEN_ROWS:
			hidden_contact = true
	if above_top or (hidden_contact and p.grounded):
		_grow_player_board(p)


# -------------------------------------------------------------- elimination

func _eliminate(p: PlayerState) -> void:
	if p.eliminated:
		return
	p.eliminated = true
	p.eliminated_at_tick = tick_count
	p.piece_kind = TetrominoData.EMPTY
	p.grounded = false
	p.clearing_rows = []
	p.clear_timer = 0.0
	p.pending_garbage = 0
	p.soft_drop = false


# ------------------------------------------------------------------- results

func _finish_versus() -> void:
	## Survivor victory or a simultaneous final-elimination draw. Players
	## eliminated on the same tick share a placement; earlier eliminations
	## rank strictly worse in tick order (latest eliminated = best).
	phase = Phase.FINISHED
	placements = []
	placements.resize(player_count)
	winners = []
	var survivors: Array = []
	for p in players:
		if not p.eliminated:
			survivors.append(p.index)
	# Elimination groups, latest tick first.
	var groups: Array = []
	for p in players:
		if not p.eliminated:
			continue
		var placed: bool = false
		for g in groups:
			if int(g["tick"]) == p.eliminated_at_tick:
				g["players"].append(p.index)
				placed = true
				break
		if not placed:
			groups.append({"tick": p.eliminated_at_tick, "players": [p.index]})
	groups.sort_custom(func(a, b) -> bool: return int(a["tick"]) > int(b["tick"]))
	var place: int = 1
	if survivors.size() == 1:
		placements[int(survivors[0])] = 1
		winners = [int(survivors[0])]
		place = 2
	elif survivors.is_empty():
		# The final simultaneous elimination group decides the outcome: it
		# is a draw when more than one player fell on the same tick, or a
		# single de-facto winner otherwise. Either way the group holds
		# placement 1 and earlier groups rank below it.
		if not groups.is_empty():
			var top: Array = (groups[0] as Dictionary)["players"]
			top.sort()
			winners = top
	else:
		# Defensive: multiple survivors cannot occur (the match ends the
		# tick the count reaches one); rank them by score so a placement
		# still exists for every player.
		var sorted_survivors: Array = survivors.duplicate()
		sorted_survivors.sort_custom(func(a, b) -> bool:
			if players[int(a)].score != players[int(b)].score:
				return players[int(a)].score > players[int(b)].score
			return int(a) < int(b))
		for idx in sorted_survivors:
			placements[int(idx)] = place
			place += 1
		winners = [int(sorted_survivors[0])]
	for g in groups:
		for idx in (g as Dictionary)["players"]:
			placements[int(idx)] = place
		place += int((g as Dictionary)["players"].size())


func _finish_tower() -> void:
	## Tower ranking: locked height ascending, then score descending. A
	## remaining tie on both is a draw (shared placement).
	phase = Phase.FINISHED
	placements = []
	placements.resize(player_count)
	var order: Array = []
	for i in player_count:
		order.append(i)
	order.sort_custom(func(a, b) -> bool:
		var ha: int = players[int(a)].board.locked_height()
		var hb: int = players[int(b)].board.locked_height()
		if ha != hb:
			return ha < hb
		var sa: int = players[int(a)].score
		var sb: int = players[int(b)].score
		if sa != sb:
			return sa > sb
		return int(a) < int(b))
	var place: int = 0
	var prev_height: int = -1
	var prev_score: int = -1
	for rank in order.size():
		var idx: int = int(order[rank])
		var height: int = players[idx].board.locked_height()
		var score: int = players[idx].score
		if rank == 0 or height != prev_height or score != prev_score:
			place = rank + 1
		placements[idx] = place
		prev_height = height
		prev_score = score
	winners = []
	for i in player_count:
		if int(placements[i]) == 1:
			winners.append(i)


func match_result() -> Dictionary:
	## Terminal match summary for results screens and persistence. Only a
	## finished match ranks: calling this earlier returns {} instead of
	## forcing a ranking onto a live match.
	if phase != Phase.FINISHED or placements.size() != player_count:
		return {}
	var out_players: Array = []
	for p in players:
		var placement: int = int(placements[p.index]) if placements.size() == player_count else 0
		out_players.append({
			"index": p.index,
			"score": p.score,
			"lines": p.lines,
			"height": p.board.locked_height(),
			"eliminated": p.eliminated,
			"placement": placement,
		})
	var duration: float = maxf(0.0, elapsed)
	if mode == ModeRules.Mode.TOWER:
		duration = maxf(0.0, minf(elapsed, ModeRules.TOWER_DURATION_SECONDS))
	return {
		"mode": mode,
		"winners": winners.duplicate(),
		"draw": winners.size() > 1,
		"placements": placements.duplicate(),
		"players": out_players,
		"duration": duration,
		"player_count": player_count,
		"garbage": garbage_enabled,
	}


# --------------------------------------------------------------- T-Spin

func _classify_tspin(p: PlayerState) -> int:
	# Guideline 3-corner rule around the T bounding box. Front corners are
	# the side the T faces; out-of-board coordinates count as occupied.
	var size: int = TetrominoData.box_size(T)
	var corners: Array[Vector2i] = [
		Vector2i(p.piece_x, p.piece_y),
		Vector2i(p.piece_x + size - 1, p.piece_y),
		Vector2i(p.piece_x + size - 1, p.piece_y + size - 1),
		Vector2i(p.piece_x, p.piece_y + size - 1),
	]
	var occupied: Array[bool] = []
	occupied.resize(4)
	for i in 4:
		occupied[i] = _corner_occupied(p, corners[i])
	var filled_count: int = 0
	for i in 4:
		if occupied[i]:
			filled_count += 1
	if filled_count < 3:
		return Scoring.TSpinGrade.NONE
	# Front pair per state: 0 up, 1 right, 2 down, 3 left.
	var front: Array = [[0, 1], [1, 2], [2, 3], [3, 0]][p.piece_state]
	var both_front: bool = occupied[front[0]] and occupied[front[1]]
	if both_front:
		return Scoring.TSpinGrade.FULL
	return Scoring.TSpinGrade.MINI


func _corner_occupied(p: PlayerState, cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= p.board.WIDTH or cell.y >= p.board.HEIGHT:
		return true  # walls and floor count as filled
	if cell.y < 0:
		return false  # open sky above the board
	return p.board.get_cell(cell.x, cell.y) != TetrominoData.EMPTY


# -------------------------------------------------------------------- testing
# Deterministic setup helpers for headless tests, mirroring CoreGame. They
# bypass the normal spawn/queue flow and must not be used by gameplay UI.

func debug_set_cell(player: int, x: int, y: int, value: int) -> void:
	players[player].board.set_cell(x, y, value)


func debug_get_cell(player: int, x: int, y: int) -> int:
	return players[player].board.get_cell(x, y)


func debug_spawn_piece(player: int, kind: int, box_x: int = -1, box_y: int = -1, state: int = 0) -> void:
	var p: PlayerState = players[player]
	p.piece_kind = kind
	p.piece_state = state
	var spawn: Vector2i = TetrominoData.spawn_box(kind)
	p.piece_x = spawn.x if box_x < 0 else box_x
	p.piece_y = spawn.y if box_y < 0 else box_y
	p.gravity_acc = 0.0
	p.lock_timer = 0.0
	p.lock_resets_used = 0
	p.spin_ready = false
	p.last_kick_index = -1
	p.hold_used = false
	_update_grounded(p)
	_tower_check_expand(p)


func clearing_rows(player: int) -> Array[int]:
	return players[player].clearing_rows.duplicate()


# ---------------------------------------------------------------- snapshots
# Host-authoritative online state transfer, mirroring CoopGame. `to_snapshot`
# captures the full mutable simulation into plain data; a client-side twin
# built with the same constructor arguments applies it with `apply_snapshot`
# and never ticks its own simulation. Structural identity (mode, roster
# size, garbage setting) must already match, and dynamic Tower geometry
# travels inside every player's board state so variable heights restore
# safely. A malformed or foreign snapshot is rejected, never force-applied.

func to_snapshot() -> Dictionary:
	var players_out: Array = []
	for p in players:
		var event_snap: Dictionary = {}
		if p.last_event != null:
			# The authoritative revision identifies the host event across
			# snapshot rebuilds; hard_drop lets client audio edges suppress
			# the plain lock after the drop sound already played.
			event_snap = {
				"lines": p.last_event.lines,
				"tspin": p.last_event.tspin,
				"tspin_mini_upgraded": p.last_event.tspin_mini_upgraded,
				"level": p.last_event.level,
				"base_points": p.last_event.base_points,
				"b2b_applied": p.last_event.b2b_applied,
				"combo": p.last_event.combo,
				"combo_points": p.last_event.combo_points,
				"perfect_clear": p.last_event.perfect_clear,
				"pc_points": p.last_event.pc_points,
				"total_points": p.last_event.total_points,
				"rev": p.last_event.rev,
				"hard_drop": p.last_event.hard_drop,
			}
		players_out.append({
			"index": p.index,
			"piece_kind": p.piece_kind,
			"piece_state": p.piece_state,
			"piece_x": p.piece_x,
			"piece_y": p.piece_y,
			"hold_kind": p.hold_kind,
			"hold_used": p.hold_used,
			"gravity_acc": p.gravity_acc,
			"soft_drop": p.soft_drop,
			"grounded": p.grounded,
			"lock_timer": p.lock_timer,
			"lock_resets_used": p.lock_resets_used,
			"spin_ready": p.spin_ready,
			"last_kick_index": p.last_kick_index,
			"combo": p.combo,
			"b2b_active": p.b2b_active,
			"score": p.score,
			"lines": p.lines,
			"level": p.level,
			"eliminated": p.eliminated,
			"eliminated_at_tick": p.eliminated_at_tick,
			"pending_garbage": p.pending_garbage,
			"clearing": p.clearing_rows.duplicate(),
			"clear_timer": p.clear_timer,
			"bag": p.bag.snapshot(),
			"event": event_snap,
			"board": p.board.snapshot_state(),
		})
	return {
		"v": SNAPSHOT_VERSION,
		"phase": phase,
		"mode": mode,
		"seed": seed,
		"garbage": garbage_enabled,
		"tick": tick_count,
		"elapsed": elapsed,
		"garbage_state": _garbage_state,
		"last_event_player": last_event_player,
		"winners": winners.duplicate(),
		"placements": placements.duplicate(),
		"players": players_out,
	}


func apply_snapshot(snap) -> bool:
	## Replace this simulation's mutable state with the host's snapshot.
	## Returns false (state untouched) unless the snapshot matches this
	## instance's structural identity (version, mode, roster size,
	## garbage setting) and every entry validates.
	if not (snap is Dictionary):
		return false
	var data: Dictionary = snap
	if int(data.get("v", -1)) != SNAPSHOT_VERSION:
		return false
	if int(data.get("mode", -1)) != mode:
		return false
	if bool(data.get("garbage", false)) != garbage_enabled:
		return false
	var raw_players = data.get("players", [])
	if not (raw_players is Array) or raw_players.size() != player_count:
		return false
	var raw_winners = data.get("winners", [])
	var raw_placements = data.get("placements", [])
	if not (raw_winners is Array) or not (raw_placements is Array):
		return false
	# Validate every entry before mutating anything so a malformed snapshot
	# never leaves a half-applied simulation behind.
	var checked: Array = []
	for entry in raw_players:
		if not (entry is Dictionary):
			return false
		var e: Dictionary = entry
		if int(e.get("index", -1)) < 0:
			return false
		if not (e.get("bag", {}) is Dictionary):
			return false
		if not (e.get("event", {}) is Dictionary):
			return false
		var board_state = e.get("board", null)
		if not (board_state is Dictionary):
			return false
		var h: int = int((board_state as Dictionary).get("h", -1))
		var cells = (board_state as Dictionary).get("cells", null)
		if h < BoardClass.DEFAULT_HEIGHT or not (cells is PackedInt32Array):
			return false
		if (cells as PackedInt32Array).size() != BOARD_WIDTH * h:
			return false
		if not (e.get("clearing", []) is Array):
			return false
		checked.append(e)
	for i in player_count:
		if int(checked[i].get("index", -1)) != i:
			return false

	phase = int(data.get("phase", Phase.ACTIVE))
	tick_count = int(data.get("tick", tick_count))
	elapsed = float(data.get("elapsed", elapsed))
	_garbage_state = int(data.get("garbage_state", _garbage_state)) & 0xFFFFFFFF
	last_event_player = int(data.get("last_event_player", -1))
	winners = []
	for value in raw_winners:
		winners.append(int(value))
	placements = []
	for value in raw_placements:
		placements.append(int(value))

	for i in player_count:
		var p: PlayerState = players[i]
		var e: Dictionary = checked[i]
		p.piece_kind = int(e.get("piece_kind", TetrominoData.EMPTY))
		p.piece_state = int(e.get("piece_state", 0))
		p.piece_x = int(e.get("piece_x", 0))
		p.piece_y = int(e.get("piece_y", 0))
		p.hold_kind = int(e.get("hold_kind", TetrominoData.EMPTY))
		p.hold_used = bool(e.get("hold_used", false))
		p.gravity_acc = float(e.get("gravity_acc", 0.0))
		p.soft_drop = bool(e.get("soft_drop", false))
		p.grounded = bool(e.get("grounded", false))
		p.lock_timer = float(e.get("lock_timer", 0.0))
		p.lock_resets_used = int(e.get("lock_resets_used", 0))
		p.spin_ready = bool(e.get("spin_ready", false))
		p.last_kick_index = int(e.get("last_kick_index", -1))
		p.combo = int(e.get("combo", -1))
		p.b2b_active = bool(e.get("b2b_active", false))
		p.score = int(e.get("score", 0))
		p.lines = int(e.get("lines", 0))
		p.level = int(e.get("level", 1))
		p.eliminated = bool(e.get("eliminated", false))
		p.eliminated_at_tick = int(e.get("eliminated_at_tick", -1))
		p.pending_garbage = maxi(0, int(e.get("pending_garbage", 0)))
		p.clear_timer = float(e.get("clear_timer", 0.0))
		var clearing: Array[int] = []
		for value in e.get("clearing", []):
			clearing.append(int(value))
		p.clearing_rows = clearing
		p.bag.restore(e.get("bag", {}))
		var event_snap: Dictionary = e.get("event", {})
		if event_snap.is_empty():
			p.last_event = null
		else:
			# Rebuild the event object carrying the host's authoritative
			# revision: the twin never ticks, so the HUD/audio edge
			# detectors identify host events by revision instead of local
			# instance ids.
			var event: Scoring.ClearEvent = Scoring.ClearEvent.new()
			event.lines = int(event_snap.get("lines", 0))
			event.tspin = int(event_snap.get("tspin", Scoring.TSpinGrade.NONE))
			event.tspin_mini_upgraded = bool(event_snap.get("tspin_mini_upgraded", false))
			event.level = int(event_snap.get("level", 1))
			event.base_points = int(event_snap.get("base_points", 0))
			event.b2b_applied = bool(event_snap.get("b2b_applied", false))
			event.combo = int(event_snap.get("combo", -1))
			event.combo_points = int(event_snap.get("combo_points", 0))
			event.perfect_clear = bool(event_snap.get("perfect_clear", false))
			event.pc_points = int(event_snap.get("pc_points", 0))
			event.total_points = int(event_snap.get("total_points", 0))
			event.rev = int(event_snap.get("rev", 0))
			event.hard_drop = bool(event_snap.get("hard_drop", false))
			p.last_event = event
			event_revision = maxi(event_revision, event.rev)
		if not p.board.restore_state(e.get("board", {})):
			return false
	return true
