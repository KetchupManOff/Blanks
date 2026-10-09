extends "res://tests/test_lib.gd"
## Seeded 7-bag randomizer tests: invariants and determinism.

const BagRandomizer = preload("res://scripts/core/randomizer.gd")
const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")


func _is_bag_permutation(sequence: Array, start: int) -> bool:
	var seen := {}
	for i in range(start, start + 7):
		var kind: int = sequence[i]
		if seen.has(kind):
			return false
		seen[kind] = true
	return seen.size() == 7


func test_every_seven_pieces_is_a_permutation() -> void:
	var bag := BagRandomizer.new(42)
	var sequence: Array = []
	for i in 70:
		sequence.append(bag.next_piece())
	for group in 10:
		check(_is_bag_permutation(sequence, group * 7), "bag %d is a permutation of all 7 kinds" % group)


func test_same_seed_same_sequence() -> void:
	var a := BagRandomizer.new(987654321)
	var b := BagRandomizer.new(987654321)
	for i in 70:
		var pa: int = a.next_piece()
		var pb: int = b.next_piece()
		if pa != pb:
			check(false, "piece %d differs between same-seed bags" % i)
			return
	check(true, "same seed reproduces 70-piece sequence")


func test_different_seed_differs() -> void:
	var a := BagRandomizer.new(1)
	var b := BagRandomizer.new(2)
	var differs: bool = false
	for i in 70:
		if a.next_piece() != b.next_piece():
			differs = true
			break
	check(differs, "different seeds produce different sequences")


func test_peek_does_not_consume() -> void:
	var bag := BagRandomizer.new(7)
	var first: int = bag.peek(0)
	var previews: Array = bag.preview(5)
	check_eq(bag.peek(0), first, "preview does not consume")
	check_eq(previews.size(), 5, "preview returns requested count")
	for i in 5:
		check_eq(bag.peek(i), previews[i], "preview matches peek at %d" % i)
	var consumed: int = bag.next_piece()
	check_eq(consumed, previews[0], "consumed piece was the first preview")


func test_seed_zero_is_valid() -> void:
	var bag := BagRandomizer.new(0)
	var pieces: Array = []
	for i in 14:
		pieces.append(bag.next_piece())
	check(_is_bag_permutation(pieces, 0), "seed zero produces valid first bag")
	check(_is_bag_permutation(pieces, 7), "seed zero produces valid second bag")


func test_game_previews_match_seed() -> void:
	var a: RefCounted = CoreGame.new(ModeRules.Mode.MARATHON, 555)
	var b: RefCounted = CoreGame.new(ModeRules.Mode.MARATHON, 555)
	var pa: Array = a.preview_kinds()
	var pb: Array = b.preview_kinds()
	check_eq(pa.size(), 5, "five previews exposed")
	check_eq(pb, pa, "same seed gives same preview queue in game")
