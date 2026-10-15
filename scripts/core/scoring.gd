extends RefCounted
## Guideline-style scoring math. Pure functions plus a result record that the
## game state machine fills in per lock.

const PlayConfig = preload("res://scripts/core/constants.gd")

enum TSpinGrade { NONE, MINI, FULL }


class ClearEvent:
	extends RefCounted
	var lines: int = 0
	var tspin: int = TSpinGrade.NONE
	var base_points: int = 0
	var b2b_applied: bool = false
	var combo: int = -1
	var combo_points: int = 0
	var perfect_clear: bool = false
	var pc_points: int = 0
	var total_points: int = 0
	var level: int = 1
	var tspin_mini_upgraded: bool = false
	## Authoritative event revision: assigned by the owning engine from a
	## counter that advances exactly when a lock event is created. Stable
	## across the wire so snapshot rebuilds on clients identify the same
	## host event (fresh local instance ids never compare equal).
	var rev: int = 0
	## True when the lock came from a hard drop: lets the audio-edge layer
	## suppress the plain lock sound after the drop already played.
	var hard_drop: bool = false

	func label() -> String:
		var text: String = ""
		if tspin == TSpinGrade.FULL:
			text += "T-SPIN "
		elif tspin == TSpinGrade.MINI:
			text += "T-SPIN MINI "
		match lines:
			1:
				text += "SINGLE"
			2:
				text += "DOUBLE"
			3:
				text += "TRIPLE"
			4:
				text += "BLANKS"
		if lines == 0 and tspin == TSpinGrade.NONE:
			return ""
		if b2b_applied:
			text = "B2B " + text
		return text


static func is_difficult(tspin: int, lines: int) -> bool:
	# Back-to-back chain covers BLANKS and T-Spin line clears.
	return lines >= 1 and (lines == 4 or tspin != TSpinGrade.NONE)


static func base_points(tspin: int, lines: int, level: int) -> int:
	var base: int = 0
	if tspin == TSpinGrade.FULL:
		match lines:
			0:
				base = PlayConfig.SCORE_TSPIN_ZERO
			1:
				base = PlayConfig.SCORE_TSPIN_SINGLE
			2:
				base = PlayConfig.SCORE_TSPIN_DOUBLE
			3:
				base = PlayConfig.SCORE_TSPIN_TRIPLE
			_:
				base = PlayConfig.SCORE_BLANKS
	elif tspin == TSpinGrade.MINI:
		match lines:
			0:
				base = PlayConfig.SCORE_MINI_ZERO
			1:
				base = PlayConfig.SCORE_MINI_SINGLE
			_:
				base = PlayConfig.SCORE_MINI_DOUBLE
	else:
		match lines:
			1:
				base = PlayConfig.SCORE_SINGLE
			2:
				base = PlayConfig.SCORE_DOUBLE
			3:
				base = PlayConfig.SCORE_TRIPLE
			_:
				base = PlayConfig.SCORE_BLANKS
	return base * level


static func combo_points(combo: int, level: int) -> int:
	# combo counts consecutive clears minus one: 0 on the first clear of a
	# chain, so no bonus is awarded for it.
	if combo <= 0:
		return 0
	return PlayConfig.COMBO_BONUS_PER_LEVEL * combo * level


static func perfect_clear_points(lines: int, level: int) -> int:
	var base: int = 0
	match lines:
		1:
			base = PlayConfig.PC_SINGLE
		2:
			base = PlayConfig.PC_DOUBLE
		3:
			base = PlayConfig.PC_TRIPLE
		_:
			base = PlayConfig.PC_BLANKS
	return base * level
