extends "res://tests/test_lib.gd"
## Board model tests: bounds, occupancy, placement, line detection, clearing.

const Board = preload("res://scripts/core/board.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")


func test_new_board_is_empty() -> void:
	var b := Board.new()
	check_eq(b.WIDTH, 10, "board width")
	check_eq(b.HEIGHT, 22, "board height")
	check_eq(b.HIDDEN_ROWS, 2, "hidden rows")
	check_eq(b.VISIBLE_ROWS, 20, "visible rows")
	for y in b.HEIGHT:
		for x in b.WIDTH:
			check_eq(b.get_cell(x, y), TetrominoData.EMPTY, "cell %d,%d starts empty" % [x, y])
	check_true(b.is_completely_empty(), "fresh board reports completely empty")


func test_outside_coordinates() -> void:
	var b := Board.new()
	check_eq(b.is_inside(-1, 0), false, "x -1 outside")
	check_eq(b.is_inside(10, 0), false, "x 10 outside")
	check_eq(b.is_inside(0, -1), false, "y -1 outside")
	check_eq(b.is_inside(0, 22), false, "y 22 outside")
	check_eq(b.is_inside(0, 21), true, "bottom-right corner inside")
	check_eq(b.is_inside(9, 21), true, "corner 9,21 inside")


func test_walls_floor_block_sky_open() -> void:
	var b := Board.new()
	check_true(b.is_blocked(-1, 5), "left wall blocks")
	check_true(b.is_blocked(10, 5), "right wall blocks")
	check_true(b.is_blocked(5, 22), "below floor blocks")
	check_false(b.is_blocked(5, 21), "empty in-board cell does not block")
	check_false(b.is_blocked(4, -1), "open sky above board does not block")
	check_false(b.is_blocked(4, -50), "far above board does not block")


func test_sky_is_open() -> void:
	var b := Board.new()
	check_false(b.is_blocked(4, -1), "y -1 above board is open sky")
	check_false(b.is_blocked(4, -50), "far above board is open sky")


func test_set_get_and_occupancy() -> void:
	var b := Board.new()
	b.set_cell(4, 20, TetrominoData.Kind.T)
	check_eq(b.get_cell(4, 20), TetrominoData.Kind.T, "set/get round trip")
	check_true(b.is_blocked(4, 20), "occupied cell blocks")
	check_false(b.is_blocked(5, 20), "other cell still free")
	b.set_cell(4, 20, TetrominoData.EMPTY)
	check_false(b.is_blocked(4, 20), "clearing a cell unblocks it")


func test_can_place_and_place() -> void:
	var b := Board.new()
	var cells: Array = [Vector2i(0, 21), Vector2i(1, 21), Vector2i(2, 21)]
	check_true(b.can_place(cells), "empty board accepts bottom row cells")
	b.place(cells, TetrominoData.Kind.J)
	check_true(b.is_blocked(0, 21), "placed cell now blocks")
	var overlap: Array = [Vector2i(1, 21), Vector2i(1, 20)]
	check_false(b.can_place(overlap), "overlapping placement rejected")
	var outside: Array = [Vector2i(0, 22)]
	check_false(b.can_place(outside), "below floor rejected")
	var sky: Array = [Vector2i(0, -1), Vector2i(1, -1)]
	check_true(b.can_place(sky), "cells above the board are placeable")


func test_row_full_detection() -> void:
	var b := Board.new()
	for x in 10:
		b.set_cell(x, 20, TetrominoData.Kind.I)
	check_true(b.is_row_full(20), "filled row detected")
	check_false(b.is_row_full(21), "other row not full")
	b.set_cell(4, 20, TetrominoData.EMPTY)
	check_false(b.is_row_full(20), "one gap means not full")


func test_full_rows_listing() -> void:
	var b := Board.new()
	for x in 10:
		b.set_cell(x, 20, 1)
		b.set_cell(x, 21, 1)
	var rows: Array = b.full_rows()
	check_eq(rows, [20, 21], "full rows listed ascending")


func test_clear_rows_collapses_above() -> void:
	var b := Board.new()
	# Row 20 and 21 complete; a lone block sits at (2, 18).
	for x in 10:
		b.set_cell(x, 20, 1)
		b.set_cell(x, 21, 2)
	b.set_cell(2, 18, 3)
	b.clear_rows([20, 21])
	check_eq(b.get_cell(2, 18), TetrominoData.EMPTY, "cleared area above shifts down")
	check_eq(b.get_cell(2, 20), 3, "block above cleared rows moved down by two")
	check_eq(b.get_cell(2, 21), TetrominoData.EMPTY, "bottom row empty after clear")


func test_clear_single_middle_row() -> void:
	var b := Board.new()
	# Fill row 19 completely, plus a block at (5, 10).
	for x in 10:
		b.set_cell(x, 19, 1)
	b.set_cell(5, 10, 2)
	b.clear_rows([19])
	check_eq(b.get_cell(5, 11), 2, "block above single cleared row shifted by one")
	var occupied: int = 0
	for y in b.HEIGHT:
		for x in b.WIDTH:
			if b.get_cell(x, y) != TetrominoData.EMPTY:
				occupied += 1
	check_eq(occupied, 1, "exactly one block remains")


func test_clear_hidden_row_allowed() -> void:
	var b := Board.new()
	for x in 10:
		b.set_cell(x, 0, 1)
	b.clear_rows([0])
	check_eq(b.get_cell(5, 0), TetrominoData.EMPTY, "hidden row can be cleared")
	check_true(b.is_completely_empty(), "board empty after hidden row clear")


func test_perfect_clear_helpers() -> void:
	var b := Board.new()
	check_true(b.is_area_empty_of_blocks_outside_rows([21]), "empty board passes PC check")
	for x in 10:
		b.set_cell(x, 21, 1)
	b.set_cell(4, 5, 2)
	check_false(b.is_area_empty_of_blocks_outside_rows([21]), "stray block fails PC check")
	b.set_cell(4, 5, TetrominoData.EMPTY)
	check_true(b.is_area_empty_of_blocks_outside_rows([21]), "PC check passes with only the clearing row filled")
	check_false(b.is_completely_empty(), "clearing row itself still counts as occupied")


# --------------------------------------------------------- dynamic geometry

func test_prepend_rows_preserves_cells_and_floor() -> void:
	var b := Board.new()
	b.set_cell(4, 21, TetrominoData.Kind.T)
	b.set_cell(0, 2, TetrominoData.Kind.I)
	check_eq(b.locked_height(), 20, "height before growth spans to the visible top")
	b.prepend_rows(10)
	check_eq(b.HEIGHT, 32, "height grows by the prepended rows")
	check_eq(b.get_cell(4, 31), TetrominoData.Kind.T, "floor content shifts down with the floor")
	check_eq(b.get_cell(0, 12), TetrominoData.Kind.I, "former visible top row keeps its content")
	check_eq(b.get_cell(0, 2), TetrominoData.EMPTY, "new rows at the top start empty")
	check_eq(b.locked_height(), 20, "height is invariant under growth")
	check_true(b.is_blocked(4, 31), "the shifted cell blocks at its new position")
	check_true(b.is_blocked(4, 32), "the new floor still blocks below the content")


func test_prepend_rows_repeated_and_clear_afterwards() -> void:
	var b := Board.new()
	for i in 3:
		b.prepend_rows(10)
	check_eq(b.HEIGHT, 52, "repeated expansion accumulates")
	for x in 10:
		b.set_cell(x, 51, TetrominoData.Kind.J)
	b.clear_rows([51])
	check_eq(b.get_cell(5, 51), TetrominoData.EMPTY, "rows clear at runtime height after growth")
	check_true(b.is_completely_empty(), "board empty again")


func test_insert_garbage_rows_shifts_stack_and_holes() -> void:
	var b := Board.new()
	b.set_cell(4, 21, TetrominoData.Kind.T)
	b.insert_garbage_rows(2, [3, 7], 7)
	check_eq(b.HEIGHT, 22, "garbage keeps the fixed height")
	check_eq(b.get_cell(4, 21), 7, "the old bottom row is now garbage territory")
	check_eq(b.get_cell(3, 21), TetrominoData.EMPTY, "hole_columns[0] opens the bottom row")
	check_eq(b.get_cell(7, 20), TetrominoData.EMPTY, "hole_columns[1] opens the row above")
	for x in 10:
		if x != 3:
			check_eq(b.get_cell(x, 21), 7, "garbage fills the row except the hole")
		if x != 7:
			check_eq(b.get_cell(x, 20), 7, "garbage fills the row except the hole (2)")
	check_eq(b.get_cell(4, 19), TetrominoData.Kind.T, "the stack shifted up by the count")
	check_eq(b.locked_height(), 3, "stack plus garbage spans three rows")


func test_insert_garbage_discards_rows_pushed_off_the_top() -> void:
	var b := Board.new()
	b.set_cell(0, 3, TetrominoData.Kind.I)  # would land above the top after the shift
	b.set_cell(0, 5, TetrominoData.Kind.J)
	b.set_cell(0, 6, TetrominoData.Kind.L)
	b.insert_garbage_rows(4, [1, 1, 1, 1], 7)
	var survivors: int = 0
	for y in b.HEIGHT:
		for x in b.WIDTH:
			if b.get_cell(x, y) == TetrominoData.Kind.I:
				survivors += 1
	check_eq(survivors, 0, "cells pushed above the top are discarded")
	check_eq(b.get_cell(0, 1), TetrominoData.Kind.J, "hidden-row cell shifted up by the count")
	check_eq(b.get_cell(0, 2), TetrominoData.Kind.L, "the next cell follows the same shift")
	check_eq(b.get_cell(1, 21), TetrominoData.EMPTY, "bottom garbage row hole at the given column")
	check_eq(b.get_cell(0, 21), 7, "garbage fills the rest of the row")


func test_locked_height_metric() -> void:
	var b := Board.new()
	check_eq(b.locked_height(), 0, "empty board has zero height")
	b.set_cell(9, 21, TetrominoData.Kind.O)
	check_eq(b.locked_height(), 1, "single bottom-row block counts one row")
	b.set_cell(0, 5, TetrominoData.Kind.L)
	check_eq(b.locked_height(), 17, "height spans from the floor to the highest block")
	b.clear_rows([21])
	check_eq(b.locked_height(), 16, "clearing the bottom row lowers the height")


func test_dynamic_snapshot_round_trip() -> void:
	var b := Board.new()
	b.set_cell(4, 21, TetrominoData.Kind.T)
	b.prepend_rows(10)
	var state: Dictionary = b.snapshot_state()
	check_eq(int(state["h"]), 32, "snapshot carries the runtime height")
	var twin := Board.new()
	check_true(twin.restore_state(state), "twin accepts the larger geometry")
	check_eq(twin.HEIGHT, 32, "twin height resized on restore")
	check_eq(twin.get_cell(4, 31), TetrominoData.Kind.T, "cells restored at the shifted position")
	check_false(twin.restore_state({"h": 22, "cells": PackedInt32Array()}), "wrong cell count rejected")
	check_false(twin.restore_state({"h": 10, "cells": twin.snapshot_cells()}), "height below the default rejected")
	check_false(twin.restore_state("nope"), "non-dictionary rejected")
	check_eq(twin.HEIGHT, 32, "rejected restores leave the geometry untouched")
