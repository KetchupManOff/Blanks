extends RefCounted
## Cooperative team rules engine for 1-4 local players on one shared board
## (ten columns per player). Each player has an independent bag, active
## piece, hold, and scoring chains; the team shares score, line count,
## level/gravity, timer, and one result. Rows complete and clear globally,
## freezing every player during the shared clear delay. Runs without any
## scene-tree dependency exactly like CoreGame: the presentation layer
## advances it with fixed tick() steps and reads its state.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const BoardClass = preload("res://scripts/core/board.gd")
const BagRandomizer = preload("res://scripts/core/randomizer.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

enum Phase { ACTIVE, CLEARING, GAME_OVER, FINISHED }

const T = TetrominoData.Kind.T
const SECTION_WIDTH: int = 10
const MAX_PLAYERS: int = 4


class PlayerState:
	extends RefCounted
	## Per-player simulation state: one bag, one active piece, hold, and
	## scoring chains. The shared engine owns the board and team totals.
	var index: int = 0
	var section_x0: int = 0
	var bag = null  # BagRandomizer, untyped to keep dynamic calls working
	var piece_kind: int = -1  # TetrominoData.EMPTY while waiting for a post-clear spawn
	var piece_state: int = 0
	var piece_x: int = 0  # bounding box origin, absolute board coordinates
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

	func _init(player_index: int, section_offset: int) -> void:
		index = player_index
		section_x0 = section_offset


var mode: int = ModeRules.Mode.MARATHON
var seed: int = 0
var player_count: int = 1
var board: BoardClass = null
var players: Array = []
var phase: int = Phase.ACTIVE
var elapsed: float = 0.0
var tick_count: int = 0

# --- Shared clearing phase ---
var _clearing_rows: Array[int] = []
var _clear_timer: float = 0.0

# --- Team totals ---
var score: int = 0
var lines: int = 0
var level: int = 1
var last_event_player: int = -1
# Authoritative event revision: advances exactly when a lock event is
# created. Snapshot rebuilds on clients carry it inside every event so
# audio/HUD edge detection identifies host events without comparing local
# instance ids (a rebuilt twin event never looks fresh).
var event_revision: int = 0


func _init(game_player_count: int = 1, game_mode: int = ModeRules.Mode.MARATHON, game_seed: int = 0) -> void:
	player_count = clampi(game_player_count, 1, MAX_PLAYERS)
	mode = game_mode
	seed = game_seed
	board = BoardClass.new(SECTION_WIDTH * player_count)
	for i in player_count:
		var p := PlayerState.new(i, SECTION_WIDTH * i)
		p.bag = BagRandomizer.new(ModeRules.coop_seed(game_seed, i))
		players.append(p)
	level = 1
	for p in players:
		_spawn_from_queue(p, true)


# ---------------------------------------------------------------- simulation

func tick(delta: float) -> void:
	if phase == Phase.GAME_OVER or phase == Phase.FINISHED:
		return
	elapsed += delta
	tick_count += 1
	if phase == Phase.CLEARING:
		_clear_timer -= delta
		if _clear_timer <= 0.0:
			_finish_clearing()
		return
	# Phase.ACTIVE: players resolve in index order; the first lock that starts
	# a clear or ends the run freezes the rest for this step.
	for i in player_count:
		if phase != Phase.ACTIVE:
			break
		var p: PlayerState = players[i]
		_apply_gravity(p, delta)
		if p.grounded:
			p.lock_timer += delta
			if p.lock_timer >= PlayConfig.LOCK_DELAY:
				_lock_piece(p)


func _apply_gravity(p: PlayerState, delta: float) -> void:
	var interval: float = ModeRules.gravity_seconds(mode, level)
	if p.soft_drop:
		interval = interval / PlayConfig.SOFT_DROP_FACTOR
	p.gravity_acc += delta
	while p.gravity_acc >= interval:
		p.gravity_acc -= interval
		if _can_move_to(p, p.piece_x, p.piece_y + 1):
			p.piece_y += 1
			p.spin_ready = false
			if p.soft_drop:
				score += PlayConfig.SOFT_DROP_POINTS_PER_CELL
			_update_grounded(p)
			if not p.grounded:
				p.lock_timer = 0.0
		else:
			p.gravity_acc = 0.0
			break
	_update_grounded(p)


func _update_grounded(p: PlayerState) -> void:
	if p.piece_kind == TetrominoData.EMPTY:
		p.grounded = false
		return
	p.grounded = not _can_move_to(p, p.piece_x, p.piece_y + 1)


# ------------------------------------------------------------------ queries

func current_cells(player: int) -> Array:
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
		return []
	return TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, p.piece_y)


func ghost_y(player: int) -> int:
	var p: PlayerState = players[player]
	var y: int = p.piece_y
	while _can_move_to(p, p.piece_x, y + 1):
		y += 1
	return y


func ghost_cells(player: int) -> Array:
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
		return []
	return TetrominoData.board_cells(p.piece_kind, p.piece_state, p.piece_x, ghost_y(player))


func preview_kinds(player: int) -> Array[int]:
	return players[player].bag.preview(PlayConfig.PREVIEW_COUNT)


func _can_move_to(p: PlayerState, box_x: int, box_y: int) -> bool:
	if phase != Phase.ACTIVE:
		return false
	if p.piece_kind == TetrominoData.EMPTY:
		return false
	return board.can_place_within(
		TetrominoData.board_cells(p.piece_kind, p.piece_state, box_x, box_y),
		p.section_x0,
		p.section_x0 + SECTION_WIDTH - 1
	)


# ------------------------------------------------------------------ actions
# All action methods are no-ops unless the game is in the ACTIVE phase, and
# failed actions leave state fully unchanged.

func try_move(player: int, dx: int) -> bool:
	if phase != Phase.ACTIVE:
		return false
	var p: PlayerState = players[player]
	if not _can_move_to(p, p.piece_x + dx, p.piece_y):
		return false
	p.piece_x += dx
	p.spin_ready = false
	_after_successful_shift(p)
	return true


func rotate(player: int, dir: int) -> bool:
	# dir: +1 clockwise, -1 counter-clockwise. Kick candidates are validated
	# against the player's section in addition to the board.
	if phase != Phase.ACTIVE:
		return false
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
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
		if board.can_place_within(candidate, p.section_x0, p.section_x0 + SECTION_WIDTH - 1):
			p.piece_x += kick.x
			p.piece_y += kick.y
			p.piece_state = to_state
			p.spin_ready = true
			p.last_kick_index = i
			_after_successful_shift(p)
			return true
	return false


func hard_drop(player: int) -> bool:
	if phase != Phase.ACTIVE:
		return false
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY:
		return false
	var target_y: int = ghost_y(player)
	var distance: int = target_y - p.piece_y
	if distance > 0:
		p.piece_y = target_y
		score += distance * PlayConfig.HARD_DROP_POINTS_PER_CELL
		p.spin_ready = false
	_lock_piece(p, true)
	return true


func set_soft_drop(player: int, active: bool) -> void:
	if player >= 0 and player < player_count:
		players[player].soft_drop = active


func hold(player: int) -> bool:
	if phase != Phase.ACTIVE:
		return false
	var p: PlayerState = players[player]
	if p.piece_kind == TetrominoData.EMPTY or p.hold_used:
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
	# Re-place the current piece kind at its section spawn position and state.
	var spawn: Vector2i = TetrominoData.spawn_box(p.piece_kind)
	p.piece_state = 0
	p.piece_x = p.section_x0 + spawn.x
	p.piece_y = spawn.y
	p.gravity_acc = 0.0
	p.lock_timer = 0.0
	p.lock_resets_used = 0
	p.spin_ready = false
	p.last_kick_index = -1
	_update_grounded(p)


# -------------------------------------------------------------------- spawn

func _spawn_from_queue(p: PlayerState, reset_hold: bool) -> void:
	p.piece_kind = p.bag.next_piece()
	if reset_hold:
		p.hold_used = false
	_reset_piece_state(p)
	# Block out: a spawn overlapping existing blocks ends the team run.
	if not board.can_place_within(current_cells(p.index), p.section_x0, p.section_x0 + SECTION_WIDTH - 1):
		phase = Phase.GAME_OVER


# --------------------------------------------------------------------- lock

func _lock_piece(p: PlayerState, from_hard_drop: bool = false) -> void:
	var cells: Array = current_cells(p.index)
	var kind: int = p.piece_kind
	board.place(cells, kind)

	# Lock out: piece locked entirely above the visible field.
	var lock_out: bool = true
	for c in cells:
		if c.y >= board.HIDDEN_ROWS:
			lock_out = false
			break

	# T-Spin classification happens before line removal (corners checked with
	# the stack intact).
	var tspin: int = Scoring.TSpinGrade.NONE
	var upgraded: bool = false
	if kind == T and p.spin_ready:
		tspin = _classify_tspin(p)
		if tspin == Scoring.TSpinGrade.MINI and p.last_kick_index == 4:
			# Guideline "mini upgrade": final-kick T-Spins count as full.
			tspin = Scoring.TSpinGrade.FULL
			upgraded = true

	# Full rows span the whole shared board: a row clears only when every
	# section contributes all ten cells.
	var cleared: Array = board.full_rows()
	var event: Scoring.ClearEvent = Scoring.ClearEvent.new()
	event.lines = cleared.size()
	event.tspin = tspin
	event.tspin_mini_upgraded = upgraded
	event.level = level
	event.rev = event_revision + 1
	event.hard_drop = from_hard_drop
	event_revision += 1

	if not cleared.is_empty():
		var difficult: bool = Scoring.is_difficult(tspin, cleared.size())
		event.base_points = Scoring.base_points(tspin, cleared.size(), level)
		event.b2b_applied = difficult and p.b2b_active
		if event.b2b_applied:
			event.base_points = int(round(event.base_points * PlayConfig.B2B_MULTIPLIER))
		p.combo += 1
		event.combo = p.combo
		event.combo_points = Scoring.combo_points(p.combo, level)
		event.perfect_clear = board.is_area_empty_of_blocks_outside_rows(cleared)
		if event.perfect_clear:
			event.pc_points = Scoring.perfect_clear_points(cleared.size(), level)
		# Difficult clears continue or start this player's back-to-back
		# chain; ordinary clears break it. Locks without clears leave it.
		p.b2b_active = difficult
	else:
		if tspin != Scoring.TSpinGrade.NONE:
			event.base_points = Scoring.base_points(tspin, 0, level)
		# Locks without clears reset this player's combo chain.
		p.combo = -1
		event.combo = -1

	event.total_points = event.base_points + event.combo_points + event.pc_points
	score += event.total_points
	p.last_event = event
	last_event_player = p.index

	lines += cleared.size()
	level = ModeRules.level_after_lines(mode, lines)

	if lock_out:
		phase = Phase.GAME_OVER
		return
	if not cleared.is_empty():
		if ModeRules.is_finished(mode, lines):
			phase = Phase.FINISHED
			return
		phase = Phase.CLEARING
		_clearing_rows.clear()
		for y in cleared:
			_clearing_rows.append(y)
		_clear_timer = PlayConfig.LINE_CLEAR_DELAY
		# The locking player awaits its next spawn after the collapse; every
		# player freezes until then.
		p.piece_kind = TetrominoData.EMPTY
	else:
		_spawn_from_queue(p, true)


func _finish_clearing() -> void:
	var cleared: Array = _clearing_rows.duplicate()
	_clearing_rows = []
	board.clear_rows(cleared)
	phase = Phase.ACTIVE
	# Surviving pieces follow the collapse: each shifts down by the number of
	# cleared rows strictly below its lowest cell, exactly like the stack.
	for p in players:
		if p.piece_kind == TetrominoData.EMPTY:
			continue
		_shift_piece_after_collapse(p, cleared)
	# Players that locked before the clear spawn their next piece now.
	for p in players:
		if p.piece_kind == TetrominoData.EMPTY:
			_spawn_from_queue(p, true)


func _shift_piece_after_collapse(p: PlayerState, cleared_rows: Array) -> void:
	var lowest: int = p.piece_y
	for c in current_cells(p.index):
		lowest = maxi(lowest, c.y)
	var shift: int = 0
	for y in cleared_rows:
		if y > lowest:
			shift += 1
	if shift > 0:
		p.piece_y += shift
		# Defensive: a collapse never overlaps a piece with the shifted stack,
		# but if an unexpected state appears, lift the piece until it fits.
		var guard: int = 0
		while not _can_move_to(p, p.piece_x, p.piece_y) and guard < 24:
			p.piece_y -= 1
			guard += 1
		p.gravity_acc = 0.0
	_update_grounded(p)
	if not p.grounded:
		p.lock_timer = 0.0


# --------------------------------------------------------------- T-Spin

func _classify_tspin(p: PlayerState) -> int:
	# Guideline 3-corner rule around the T bounding box. Front corners are the
	# side the T faces; out-of-board coordinates count as occupied.
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
		occupied[i] = _corner_occupied(corners[i])
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


func _corner_occupied(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= board.WIDTH or cell.y >= board.HEIGHT:
		return true  # walls and floor count as filled
	if cell.y < 0:
		return false  # open sky above the board
	return board.get_cell(cell.x, cell.y) != TetrominoData.EMPTY


# -------------------------------------------------------------------- testing
# Deterministic setup helpers for headless tests, mirroring CoreGame. They
# bypass the normal spawn/queue flow and must not be used by gameplay UI.

func debug_set_cell(x: int, y: int, value: int) -> void:
	board.set_cell(x, y, value)


func debug_spawn_piece(player: int, kind: int, box_x: int = -1, box_y: int = -1, state: int = 0) -> void:
	# box coordinates are section-local (0..9 within the player's section).
	var p: PlayerState = players[player]
	p.piece_kind = kind
	p.piece_state = state
	var spawn: Vector2i = TetrominoData.spawn_box(kind)
	p.piece_x = p.section_x0 + (spawn.x if box_x < 0 else box_x)
	p.piece_y = spawn.y if box_y < 0 else box_y
	p.gravity_acc = 0.0
	p.lock_timer = 0.0
	p.lock_resets_used = 0
	p.spin_ready = false
	p.last_kick_index = -1
	p.hold_used = false
	_update_grounded(p)


func clearing_rows() -> Array[int]:
	return _clearing_rows.duplicate()


# ---------------------------------------------------------------- snapshots
# Host-authoritative online state transfer. `to_snapshot` captures the full
# mutable simulation into plain data (Dictionary + PackedInt32Array); a
# client-side twin built with the same constructor arguments applies it with
# `apply_snapshot` and never ticks its own simulation. Structural identity
# (player count / board geometry / mode) must already match: a snapshot from
# a different configuration is rejected, never force-applied.

const SNAPSHOT_VERSION: int = 1


func to_snapshot() -> Dictionary:
	var players_out: Array = []
	for p in players:
		var event_snap: Dictionary = {}
		if p.last_event != null:
			# Plain-data copy of the scoring ClearEvent: clients render the
			# same event/combo HUD lines from it. The authoritative revision
			# identifies the host event across snapshot rebuilds; hard_drop
			# lets client audio edges suppress the plain lock after the drop
			# sound already played optimistically.
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
			"bag": p.bag.snapshot(),
			"event": event_snap,
		})
	return {
		"v": SNAPSHOT_VERSION,
		"phase": phase,
		"mode": mode,
		"seed": seed,
		"tick": tick_count,
		"elapsed": elapsed,
		"score": score,
		"lines": lines,
		"level": level,
		"last_event_player": last_event_player,
		"clearing": _clearing_rows.duplicate(),
		"clear_timer": _clear_timer,
		"board": board.snapshot_cells(),
		"players": players_out,
	}


func apply_snapshot(snap) -> bool:
	## Replace this simulation's mutable state with the host's snapshot.
	## Returns false (state untouched) unless the snapshot matches this
	## instance's structural identity (version, player count, mode).
	if not (snap is Dictionary):
		return false
	if int((snap as Dictionary).get("v", -1)) != SNAPSHOT_VERSION:
		return false
	if int((snap as Dictionary).get("mode", -1)) != mode:
		return false
	var raw_players = (snap as Dictionary).get("players", [])
	if not (raw_players is Array) or raw_players.size() != player_count:
		return false
	var raw_board = snap.get("board", PackedInt32Array())
	if not (raw_board is PackedInt32Array) or raw_board.size() != board.WIDTH * board.HEIGHT:
		return false
	var cells: PackedInt32Array = raw_board
	var raw_clearing = snap.get("clearing", [])
	if not (raw_clearing is Array):
		return false
	# Validate every entry before mutating anything so a malformed snapshot
	# never leaves a half-applied simulation behind.
	for entry in raw_players:
		if not (entry is Dictionary) or int((entry as Dictionary).get("index", -1)) < 0:
			return false
		if not ((entry as Dictionary).get("bag", {}) is Dictionary):
			return false
		if not ((entry as Dictionary).get("event", {}) is Dictionary):
			return false

	phase = int(snap.get("phase", Phase.ACTIVE))
	tick_count = int(snap.get("tick", tick_count))
	elapsed = float(snap.get("elapsed", elapsed))
	score = int(snap.get("score", 0))
	lines = int(snap.get("lines", 0))
	level = int(snap.get("level", 1))
	last_event_player = int(snap.get("last_event_player", -1))
	_clear_timer = float(snap.get("clear_timer", 0.0))
	var clearing: Array[int] = []
	for value in raw_clearing:
		clearing.append(int(value))
	_clearing_rows = clearing

	for i in player_count:
		var p: PlayerState = players[i]
		var entry: Dictionary = raw_players[i]
		if int(entry.get("index", -1)) != i:
			return false
		p.piece_kind = int(entry.get("piece_kind", TetrominoData.EMPTY))
		p.piece_state = int(entry.get("piece_state", 0))
		p.piece_x = int(entry.get("piece_x", 0))
		p.piece_y = int(entry.get("piece_y", 0))
		p.hold_kind = int(entry.get("hold_kind", TetrominoData.EMPTY))
		p.hold_used = bool(entry.get("hold_used", false))
		p.gravity_acc = float(entry.get("gravity_acc", 0.0))
		p.soft_drop = bool(entry.get("soft_drop", false))
		p.grounded = bool(entry.get("grounded", false))
		p.lock_timer = float(entry.get("lock_timer", 0.0))
		p.lock_resets_used = int(entry.get("lock_resets_used", 0))
		p.spin_ready = bool(entry.get("spin_ready", false))
		p.last_kick_index = int(entry.get("last_kick_index", -1))
		p.combo = int(entry.get("combo", -1))
		p.b2b_active = bool(entry.get("b2b_active", false))
		p.bag.restore(entry.get("bag", {}))
		var event_snap: Dictionary = entry.get("event", {})
		if event_snap.is_empty():
			p.last_event = null
		else:
			# Rebuild the event object carrying the host's authoritative
			# revision: the twin never ticks, so its event ids stay stable
			# and the HUD/audio edge detectors identify host events by
			# revision instead of local instance ids.
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

	return board.restore_cells(cells)
