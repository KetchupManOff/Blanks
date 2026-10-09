extends RefCounted
## Playfield model, default 10x22: two hidden spawn rows on top of a 10x20
## visible field. The width can be supplied at construction for coop boards
## (ten columns per player); row detection and clearing always span the whole
## board. Stores locked cells as tetromino kind ints (-1 = empty).
## Pure data model with no engine dependencies beyond Vector2i.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")

const DEFAULT_WIDTH: int = 10
const HEIGHT: int = 22
const HIDDEN_ROWS: int = 2
const VISIBLE_ROWS: int = 20

var WIDTH: int = DEFAULT_WIDTH
var _cells := PackedInt32Array()


func _init(width: int = DEFAULT_WIDTH) -> void:
	if width >= 1:
		WIDTH = width
	_cells.resize(WIDTH * HEIGHT)
	_cells.fill(TetrominoData.EMPTY)


func index(x: int, y: int) -> int:
	return y * WIDTH + x


func is_inside(x: int, y: int) -> bool:
	return x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT


func get_cell(x: int, y: int) -> int:
	# Returns EMPTY for coordinates outside the board. Collision handling is
	# done by is_blocked(), not by get_cell().
	if not is_inside(x, y):
		return TetrominoData.EMPTY
	return _cells[index(x, y)]


func set_cell(x: int, y: int, value: int) -> void:
	assert(is_inside(x, y), "set_cell outside board: %d,%d" % [x, y])
	_cells[index(x, y)] = value


func is_blocked(x: int, y: int) -> bool:
	# True when the coordinate cannot be occupied by a piece cell.
	# Walls and floor block; the open sky above the board (y < 0) does not.
	if x < 0 or x >= WIDTH or y >= HEIGHT:
		return true
	if y < 0:
		return false
	return _cells[index(x, y)] != TetrominoData.EMPTY


func can_place(cells: Array) -> bool:
	for c in cells:
		if is_blocked(c.x, c.y):
			return false
	return true


func can_place_within(cells: Array, x_min: int, x_max: int) -> bool:
	# Placement validation with an inclusive horizontal window, used by coop
	# sections: cells outside [x_min, x_max] are rejected like walls even in
	# the open sky above the board. Walls/floor/stack rules match can_place().
	for c in cells:
		if c.x < x_min or c.x > x_max:
			return false
		if is_blocked(c.x, c.y):
			return false
	return true


func place(cells: Array, value: int) -> void:
	# Cells above the board (open sky) cannot be stored: a piece locking
	# while poking above the buffer simply drops those cells instead of
	# corrupting storage. Walls/floor are never placeable to begin with.
	for c in cells:
		if c.y < 0:
			continue
		set_cell(c.x, c.y, value)


func is_row_full(y: int) -> bool:
	var row_start: int = y * WIDTH
	for x in WIDTH:
		if _cells[row_start + x] == TetrominoData.EMPTY:
			return false
	return true


func full_rows() -> Array:
	var rows: Array = []
	for y in HEIGHT:
		if is_row_full(y):
			rows.append(y)
	return rows


func clear_rows(rows: Array) -> void:
	# Removes the given rows (must be sorted ascending) and shifts everything
	# above them down, inserting empty rows at the top.
	if rows.is_empty():
		return
	# Rebuild by copying non-cleared rows bottom-up.
	var out := PackedInt32Array()
	out.resize(WIDTH * HEIGHT)
	out.fill(TetrominoData.EMPTY)
	var write_row: int = HEIGHT - 1
	var y: int = HEIGHT - 1
	# rows is sorted ascending; walking y bottom-up matches from the list end.
	var rows_idx: int = rows.size() - 1
	while y >= 0:
		if rows_idx >= 0 and rows[rows_idx] == y:
			rows_idx -= 1
			y -= 1
			continue
		var src_start: int = y * WIDTH
		var dst_start: int = write_row * WIDTH
		for x in WIDTH:
			out[dst_start + x] = _cells[src_start + x]
		write_row -= 1
		y -= 1
	_cells = out


func is_completely_empty() -> bool:
	for i in _cells.size():
		if _cells[i] != TetrominoData.EMPTY:
			return false
	return true


# --------------------------------------------------------------- snapshots
# Raw cell-array capture/restore for host-authoritative online play. The
# array is exactly WIDTH * HEIGHT entries; a restore with mismatched
# geometry is rejected instead of corrupting the board.

func snapshot_cells() -> PackedInt32Array:
	return _cells.duplicate()


func restore_cells(cells: PackedInt32Array) -> bool:
	if cells.size() != WIDTH * HEIGHT:
		return false
	_cells = cells.duplicate()
	return true


func is_area_empty_of_blocks_outside_rows(rows: Array) -> bool:
	# True when every cell not belonging to the given rows is empty.
	# Used for perfect-clear detection at lock time.
	for y in HEIGHT:
		if rows.has(y):
			continue
		var row_start: int = y * WIDTH
		for x in WIDTH:
			if _cells[row_start + x] != TetrominoData.EMPTY:
				return false
	return true
