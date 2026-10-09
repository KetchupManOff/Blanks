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
