extends RefCounted
## Explicit tetromino geometry and Guideline SRS rotation data.
## Coordinates are box-local, x right, y DOWN. All four rotation states are
## stored explicitly (no matrix rotation at runtime).
## SRS kick tables are stored in y-DOWN form: the published Guideline tables
## use y-up, so the y component is negated here.

enum Kind { I, O, T, S, Z, J, L }

const EMPTY: int = -1

# Box size per kind (I uses 4x4, O uses 2x2, everything else 3x3).
const BOX_SIZE := {
	Kind.I: 4,
	Kind.O: 2,
	Kind.T: 3,
	Kind.S: 3,
	Kind.Z: 3,
	Kind.J: 3,
	Kind.L: 3,
}

# Spawn position of the bounding-box top-left corner on the board.
# Guideline: I and JLSTZ spawn "rounded left" (box x = 3), O is centered
# (box x = 4). Box y = 0 places pieces in the two hidden spawn rows.
const SPAWN_BOX := {
	Kind.I: Vector2i(3, 0),
	Kind.O: Vector2i(4, 0),
	Kind.T: Vector2i(3, 0),
	Kind.S: Vector2i(3, 0),
	Kind.Z: Vector2i(3, 0),
	Kind.J: Vector2i(3, 0),
	Kind.L: Vector2i(3, 0),
}

# Explicit per-state cells, box-local (x, y), y down.
const _CELLS := {
	Kind.I: [
		[Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)],
		[Vector2i(2, 0), Vector2i(2, 1), Vector2i(2, 2), Vector2i(2, 3)],
		[Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3)],
	],
	Kind.O: [
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	],
	Kind.T: [
		[Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1)],
		[Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)],
		[Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)],
	],
	Kind.S: [
		[Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 2)],
		[Vector2i(0, 2), Vector2i(1, 2), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 2)],
	],
	Kind.Z: [
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(2, 0), Vector2i(2, 1), Vector2i(1, 1), Vector2i(1, 2)],
		[Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 2)],
		[Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 0), Vector2i(1, 1)],
	],
	Kind.J: [
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1), Vector2i(1, 2)],
		[Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 2)],
		[Vector2i(0, 2), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)],
	],
	Kind.L: [
		[Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 2)],
		[Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(0, 2)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)],
	],
}

# Guideline SRS kick tables, y-down form (published y-up values negated).
# Keys: "<from><to>" with states 0, 1 (R), 2, 3 (L).
const _KICKS_JLSTZ := {
	"01": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
	"10": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
	"12": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
	"21": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
	"23": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
	"32": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
	"30": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
	"03": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
}

const _KICKS_I := {
	"01": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, 1), Vector2i(1, -2)],
	"10": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, -1), Vector2i(-1, 2)],
	"12": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, -2), Vector2i(2, 1)],
	"21": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, 2), Vector2i(-2, -1)],
	"23": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, -1), Vector2i(-1, 2)],
	"32": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, 1), Vector2i(1, -2)],
	"30": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, 2), Vector2i(-2, -1)],
	"03": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, -2), Vector2i(2, 1)],
}

const _KICKS_O := {
	"01": [Vector2i(0, 0)],
	"10": [Vector2i(0, 0)],
	"12": [Vector2i(0, 0)],
	"21": [Vector2i(0, 0)],
	"23": [Vector2i(0, 0)],
	"32": [Vector2i(0, 0)],
	"30": [Vector2i(0, 0)],
	"03": [Vector2i(0, 0)],
}


static func box_size(kind: int) -> int:
	return BOX_SIZE[kind]


static func spawn_box(kind: int) -> Vector2i:
	return SPAWN_BOX[kind]


static func cells(kind: int, state: int) -> Array:
	# Returns a fresh array of box-local cells for the given rotation state.
	var row: Array = _CELLS[kind]
	return row[wrapi(state, 0, 4)].duplicate()


static func kicks(kind: int, from_state: int, dir: int) -> Array:
	# dir: +1 clockwise, -1 counter-clockwise. Returns kick offsets to try in
	# order, in (dx, dy) board form with y down.
	var to_state: int = wrapi(from_state + dir, 0, 4)
	var key: String = "%d%d" % [from_state, to_state]
	if kind == Kind.O:
		return _KICKS_O[key].duplicate()
	if kind == Kind.I:
		return _KICKS_I[key].duplicate()
	return _KICKS_JLSTZ[key].duplicate()


static func board_cells(kind: int, state: int, box_x: int, box_y: int) -> Array:
	# Returns a fresh array of Vector2i absolute board cells.
	var local: Array = cells(kind, state)
	var out: Array = []
	out.resize(local.size())
	for i in local.size():
		var c: Vector2i = local[i]
		out[i] = Vector2i(box_x + c.x, box_y + c.y)
	return out
