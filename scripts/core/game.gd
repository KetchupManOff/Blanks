extends RefCounted
## Core rules engine. Runs without any scene tree dependency: the presentation
## layer advances it with fixed tick() steps and reads its state. All gameplay
## decisions live here; rendering never mutates game state.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const BoardClass = preload("res://scripts/core/board.gd")
const BagRandomizer = preload("res://scripts/core/randomizer.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")

enum Phase { ACTIVE, CLEARING, GAME_OVER, FINISHED }

const T = TetrominoData.Kind.T

var mode: int = ModeRules.Mode.MARATHON
var seed: int = 0
var board: BoardClass = null
var bag: BagRandomizer = null
var phase: int = Phase.ACTIVE
var elapsed: float = 0.0
var tick_count: int = 0

# --- Active piece ---
var piece_kind: int = TetrominoData.EMPTY
var piece_state: int = 0
var piece_x: int = 0  # bounding box origin on the board
var piece_y: int = 0

# --- Hold ---
var hold_kind: int = TetrominoData.EMPTY
var hold_used: bool = false

# --- Timing ---
var _gravity_acc: float = 0.0
var soft_drop: bool = false
var grounded: bool = false
var lock_timer: float = 0.0
var lock_resets_used: int = 0

# --- Spin tracking ---
var _spin_ready: bool = false  # last successful action before lock was a rotation
var last_kick_index: int = -1

# --- Clearing phase ---
var _clearing_rows: Array[int] = []
var _clear_timer: float = 0.0

# --- Scoring / progression ---
var score: int = 0
var lines: int = 0
var level: int = 1
var combo: int = -1  # -1 = no active chain, else consecutive clears - 1
var b2b_active: bool = false
var last_event: Scoring.ClearEvent = null
# Local event revision: identifies each lock event so HUD/audio edge
# detection compares revisions, not object instances.
var _event_revision: int = 0


func _init(game_mode: int = ModeRules.Mode.MARATHON, game_seed: int = 0) -> void:
	mode = game_mode
	seed = game_seed
	board = BoardClass.new()
	bag = BagRandomizer.new(game_seed)
	level = 1
	_spawn_from_queue(true)


# ---------------------------------------------------------------- simulation

func tick(delta: float) -> void:
	if phase == Phase.GAME_OVER or phase == Phase.FINISHED:
		return
	elapsed += delta
	tick_count += 1
	if phase == Phase.CLEARING:
		_clear_timer -= delta
		if _clear_timer <= 0.0:
			board.clear_rows(_clearing_rows)
			_clearing_rows = []
			phase = Phase.ACTIVE
			_spawn_from_queue(true)
		return
	# Phase.ACTIVE
	_apply_gravity(delta)
	if grounded:
		lock_timer += delta
		if lock_timer >= PlayConfig.LOCK_DELAY:
			_lock_piece()


func _apply_gravity(delta: float) -> void:
	var interval: float = ModeRules.gravity_seconds(mode, level)
	if soft_drop:
		interval = interval / PlayConfig.SOFT_DROP_FACTOR
	_gravity_acc += delta
	while _gravity_acc >= interval:
		_gravity_acc -= interval
		if _can_move_to(piece_x, piece_y + 1):
			piece_y += 1
			_spin_ready = false
			if soft_drop:
				score += PlayConfig.SOFT_DROP_POINTS_PER_CELL
			_update_grounded()
			if not grounded:
				lock_timer = 0.0
		else:
			_gravity_acc = 0.0
			break
	_update_grounded()


func _update_grounded() -> void:
	grounded = not _can_move_to(piece_x, piece_y + 1)


# ------------------------------------------------------------------ queries

func current_cells() -> Array:
	return TetrominoData.board_cells(piece_kind, piece_state, piece_x, piece_y)


func ghost_y() -> int:
	var y: int = piece_y
	while _can_move_to(piece_x, y + 1):
		y += 1
	return y


func ghost_cells() -> Array:
	return TetrominoData.board_cells(piece_kind, piece_state, piece_x, ghost_y())


func preview_kinds() -> Array[int]:
	return bag.preview(PlayConfig.PREVIEW_COUNT)


func _can_move_to(box_x: int, box_y: int) -> bool:
	if phase != Phase.ACTIVE:
		return false
	return board.can_place(TetrominoData.board_cells(piece_kind, piece_state, box_x, box_y))


# ------------------------------------------------------------------ actions
# All action methods are no-ops unless the game is in the ACTIVE phase, and
# failed actions leave state fully unchanged.

func try_move(dx: int) -> bool:
	if not _can_move_to(piece_x + dx, piece_y):
		return false
	piece_x += dx
	_spin_ready = false
	_after_successful_shift()
	return true


func rotate(dir: int) -> bool:
	# dir: +1 clockwise, -1 counter-clockwise.
	if phase != Phase.ACTIVE:
		return false
	var from_state: int = piece_state
	var to_state: int = wrapi(from_state + dir, 0, 4)
	var kicks: Array = TetrominoData.kicks(piece_kind, from_state, dir)
	var base_cells: Array = TetrominoData.board_cells(piece_kind, to_state, 0, 0)
	for i in kicks.size():
		var kick: Vector2i = kicks[i]
		var candidate: Array = []
		for c in base_cells:
			candidate.append(Vector2i(c.x + piece_x + kick.x, c.y + piece_y + kick.y))
		if board.can_place(candidate):
			piece_x += kick.x
			piece_y += kick.y
			piece_state = to_state
			_spin_ready = true
			last_kick_index = i
			_after_successful_shift()
			return true
	return false


func hard_drop() -> bool:
	if phase != Phase.ACTIVE:
		return false
	var target_y: int = ghost_y()
	var distance: int = target_y - piece_y
	if distance > 0:
		piece_y = target_y
		score += distance * PlayConfig.HARD_DROP_POINTS_PER_CELL
		_spin_ready = false
	_lock_piece(true)
	return true


func set_soft_drop(active: bool) -> void:
	soft_drop = active


func hold() -> bool:
	if phase != Phase.ACTIVE or hold_used:
		return false
	hold_used = true
	var previous: int = piece_kind
	if hold_kind == TetrominoData.EMPTY:
		_spawn_from_queue(false)
	else:
		piece_kind = hold_kind
		_reset_piece_state()
	hold_kind = previous
	return true


func _after_successful_shift() -> void:
	_update_grounded()
	if grounded and lock_resets_used < PlayConfig.MAX_LOCK_RESETS:
		lock_timer = 0.0
		lock_resets_used += 1


func _reset_piece_state() -> void:
	# Re-place the current piece kind at its spawn position and state.
	var spawn: Vector2i = TetrominoData.spawn_box(piece_kind)
	piece_state = 0
	piece_x = spawn.x
	piece_y = spawn.y
	_gravity_acc = 0.0
	lock_timer = 0.0
	lock_resets_used = 0
	_spin_ready = false
	last_kick_index = -1
	_update_grounded()


# -------------------------------------------------------------------- spawn

func _spawn_from_queue(reset_hold: bool) -> void:
	piece_kind = bag.next_piece()
	if reset_hold:
		hold_used = false
	_reset_piece_state()
	# Block out: spawn overlapping existing blocks ends the game.
	if not board.can_place(current_cells()):
		phase = Phase.GAME_OVER


# --------------------------------------------------------------------- lock

func _lock_piece(from_hard_drop: bool = false) -> void:
	var cells: Array = current_cells()
	var kind: int = piece_kind
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
	if kind == T and _spin_ready:
		tspin = _classify_tspin()
		if tspin == Scoring.TSpinGrade.MINI and last_kick_index == 4:
			# Guideline "mini upgrade": final-kick T-Spins count as full.
			tspin = Scoring.TSpinGrade.FULL
			upgraded = true

	var cleared: Array = board.full_rows()
	var event: Scoring.ClearEvent = Scoring.ClearEvent.new()
	event.lines = cleared.size()
	event.tspin = tspin
	event.tspin_mini_upgraded = upgraded
	event.level = level
	event.rev = _event_revision + 1
	event.hard_drop = from_hard_drop
	_event_revision += 1

	if not cleared.is_empty():
		var difficult: bool = Scoring.is_difficult(tspin, cleared.size())
		event.base_points = Scoring.base_points(tspin, cleared.size(), level)
		event.b2b_applied = difficult and b2b_active
		if event.b2b_applied:
			event.base_points = int(round(event.base_points * PlayConfig.B2B_MULTIPLIER))
		combo += 1
		event.combo = combo
		event.combo_points = Scoring.combo_points(combo, level)
		event.perfect_clear = board.is_area_empty_of_blocks_outside_rows(cleared)
		if event.perfect_clear:
			event.pc_points = Scoring.perfect_clear_points(cleared.size(), level)
		# Difficult clears continue or start the back-to-back chain; ordinary
		# clears break it. Locks without clears leave it untouched.
		b2b_active = difficult
	else:
		if tspin != Scoring.TSpinGrade.NONE:
			event.base_points = Scoring.base_points(tspin, 0, level)
		# Locks without clears reset the combo chain but never break back-to-back.
		combo = -1
		event.combo = -1

	event.total_points = event.base_points + event.combo_points + event.pc_points
	score += event.total_points
	last_event = event

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
	else:
		_spawn_from_queue(true)


# --------------------------------------------------------------- T-Spin

func _classify_tspin() -> int:
	# Guideline 3-corner rule around the T bounding box. Front corners are the
	# side the T faces; out-of-board coordinates count as occupied.
	var size: int = TetrominoData.box_size(T)
	var corners: Array[Vector2i] = [
		Vector2i(piece_x, piece_y),
		Vector2i(piece_x + size - 1, piece_y),
		Vector2i(piece_x + size - 1, piece_y + size - 1),
		Vector2i(piece_x, piece_y + size - 1),
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
	var front: Array = [[0, 1], [1, 2], [2, 3], [3, 0]][piece_state]
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


# ------------------------------------------------------------------ testing
# Deterministic setup helpers for headless tests and future practice mode.
# They bypass the normal spawn/queue flow and must not be used by gameplay UI.

func debug_set_cell(x: int, y: int, value: int) -> void:
	board.set_cell(x, y, value)


func debug_spawn_piece(kind: int, box_x: int = -1, box_y: int = -1, state: int = 0) -> void:
	piece_kind = kind
	piece_state = state
	var spawn: Vector2i = TetrominoData.spawn_box(kind)
	piece_x = spawn.x if box_x < 0 else box_x
	piece_y = spawn.y if box_y < 0 else box_y
	_gravity_acc = 0.0
	lock_timer = 0.0
	lock_resets_used = 0
	_spin_ready = false
	last_kick_index = -1
	hold_used = false
	_update_grounded()


func clearing_rows() -> Array[int]:
	return _clearing_rows.duplicate()
