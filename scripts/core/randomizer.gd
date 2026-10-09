extends RefCounted
## Seeded 7-bag randomizer with a preview queue.
## Uses a self-contained xorshift32 PRNG so piece order is reproducible from
## a seed on every platform, independent of engine RNG implementation.

const BAG_SIZE: int = 7

var _state: int = 0
var _queue: Array[int] = []


func _init(seed_value: int = 0) -> void:
	# xorshift32 state must be non-zero.
	_state = (seed_value * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF
	if _state == 0:
		_state = 0x1F123BB5
	_ensure(BAG_SIZE * 3)


func _next_u32() -> int:
	var x := _state
	x ^= (x << 13) & 0xFFFFFFFF
	x &= 0xFFFFFFFF
	x ^= x >> 17
	x ^= (x << 5) & 0xFFFFFFFF
	x &= 0xFFFFFFFF
	_state = x
	return x


func _shuffled_bag() -> Array[int]:
	var bag: Array[int] = []
	bag.resize(BAG_SIZE)
	for i in BAG_SIZE:
		bag[i] = i
	# Fisher-Yates, deterministic from the seeded state.
	for i in range(BAG_SIZE - 1, 0, -1):
		var j: int = _next_u32() % (i + 1)
		var tmp: int = bag[i]
		bag[i] = bag[j]
		bag[j] = tmp
	return bag


func _ensure(count: int) -> void:
	while _queue.size() < count:
		var bag := _shuffled_bag()
		for kind in bag:
			_queue.append(kind)


func next_piece() -> int:
	_ensure(1)
	return _queue.pop_front() as int


func peek(offset: int) -> int:
	_ensure(offset + 1)
	return _queue[offset] as int


func preview(count: int) -> Array[int]:
	_ensure(count)
	var out: Array[int] = []
	for i in count:
		out.append(_queue[i] as int)
	return out


# --------------------------------------------------------------- snapshots
# Deterministic capture/restore of the PRNG state and pending queue so a
# seeded bag can cross a network boundary without replaying history. The
# xorshift32 state alone is not enough: already-drawn pieces live in the
# queue and were produced by earlier states, so both parts must travel.

func snapshot() -> Dictionary:
	return {
		"state": _state,
		"queue": _queue.duplicate(),
	}


func restore(snap: Dictionary) -> bool:
	if not (snap is Dictionary):
		return false
	var state: int = int(snap.get("state", 0)) & 0xFFFFFFFF
	if state == 0:
		# xorshift32 state must be non-zero.
		state = 0x1F123BB5
	_state = state
	var queue: Array[int] = []
	var raw_queue = snap.get("queue", [])
	if raw_queue is Array:
		for value in raw_queue:
			queue.append(int(value))
	_queue = queue
	return true
