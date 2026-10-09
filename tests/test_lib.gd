extends RefCounted
## Minimal assertion base class for headless tests. No external framework.


var checks: int = 0
var failures: int = 0
var messages: Array[String] = []
var tree: SceneTree = null


func setup_tree(owning_tree: SceneTree) -> void:
	tree = owning_tree


func setup() -> void:
	pass


func teardown() -> void:
	pass


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		messages.append("    FAIL: " + message)


func check_eq(actual: Variant, expected: Variant, message: String) -> void:
	checks += 1
	if actual != expected:
		failures += 1
		messages.append(
			"    FAIL: %s\n      expected: %s\n      actual:   %s"
			% [message, str(expected), str(actual)]
		)


func check_true(condition: bool, message: String) -> void:
	check(condition, message)


func check_false(condition: bool, message: String) -> void:
	check(not condition, message)


func fill_rect(game: RefCounted, x0: int, y0: int, x1: int, y1: int, value: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			game.debug_set_cell(x, y, value)


func fill_row_except(game: RefCounted, y: int, except_cols: Array, value: int) -> void:
	for x in range(0, 10):
		if not except_cols.has(x):
			game.debug_set_cell(x, y, value)
