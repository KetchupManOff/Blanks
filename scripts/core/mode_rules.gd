extends RefCounted
## Mode progression rules, the Guideline marathon gravity curve, and the
## stable mode identity/ranking metadata used by profile result histories.
## Modes are identified by stable string keys ("solo_marathon",
## "coop_sprint", ...) so persistence never depends on enum values; a new
## mode only registers a descriptor and reuses the same pipeline.

const PlayConfig = preload("res://scripts/core/constants.gd")

enum Mode { MARATHON, SPRINT }

## Ranking rules for finished runs: higher score wins or lower time wins.
const RANK_SCORE_DESC := "score_desc"
const RANK_TIME_ASC := "time_asc"


static func gravity_seconds(mode: int, level: int) -> float:
	# Seconds a piece takes to fall one row under natural gravity.
	if mode == Mode.SPRINT:
		# Sprint uses fixed level-1 style gravity; speed comes from soft/hard drop.
		return 1.0
	var clamped: int = clampi(level, 1, PlayConfig.MARATHON_MAX_LEVEL)
	return pow(0.8 - (clamped - 1) * 0.007, clamped - 1)


static func level_after_lines(mode: int, total_lines: int) -> int:
	if mode == Mode.SPRINT:
		return 1
	return clampi(1 + total_lines / PlayConfig.LINES_PER_LEVEL, 1, PlayConfig.MARATHON_MAX_LEVEL)


static func is_finished(mode: int, total_lines: int) -> bool:
	if mode == Mode.SPRINT:
		return total_lines >= PlayConfig.SPRINT_GOAL_LINES
	return false


static func coop_seed(base_seed: int, player_index: int) -> int:
	# Deterministic per-player seed derivation: the same base seed and player
	# index always produce the same value, and different player indices
	# diverge so sections never share a bag sequence by accident. Solo
	# construction never uses this path.
	var h: int = (base_seed + 0x9E3779B9) & 0xFFFFFFFF
	h = _mul32(h, 0x85EBCA6B)
	h = (h ^ ((player_index + 1) * 0x9E3779B9)) & 0xFFFFFFFF
	h = (h ^ (h >> 15)) & 0xFFFFFFFF
	h = _mul32(h, 0x27D4EB2F)
	h = (h ^ (h >> 13)) & 0xFFFFFFFF
	return h


# ------------------------------------------------------ mode identity

static func mode_key(mode: int, coop: bool) -> String:
	## Stable persistence key for a run variant: "solo_marathon",
	## "coop_sprint", etc. Result histories are stored under these keys.
	var prefix := "coop_" if coop else "solo_"
	return prefix + ("sprint" if mode == Mode.SPRINT else "marathon")


static func mode_label(mode: int) -> String:
	## Human-readable mode name for result histories.
	return "40-Line Sprint" if mode == Mode.SPRINT else "Marathon"


static func mode_display_name(mode: int) -> String:
	## Upper-case display name for menus and the coop lobby.
	return "40-LINE SPRINT" if mode == Mode.SPRINT else "MARATHON"


static func ranking(mode: int) -> String:
	## Which metric a finished run is ranked by within one mode key.
	return RANK_SCORE_DESC if mode != Mode.SPRINT else RANK_TIME_ASC


static func higher_score_wins(mode: int) -> bool:
	return ranking(mode) == RANK_SCORE_DESC


static func records_on_game_over(mode: int) -> bool:
	## Marathon runs record on the game-over transition; a sprint game
	## over is an abandoned goal attempt and records nothing.
	return mode != Mode.SPRINT


static func records_on_finish(mode: int) -> bool:
	## Sprint records only when the line goal is completed; marathon
	## never finishes (it ends on game over instead).
	return mode == Mode.SPRINT


static func descriptors() -> Array:
	## All known run variants with their stable keys, labels, and ranking
	## rules. A new mode registers itself here and everywhere else follows.
	var out: Array = []
	for mode in [Mode.MARATHON, Mode.SPRINT]:
		for coop in [false, true]:
			out.append({
				"key": mode_key(mode, coop),
				"mode": mode,
				"coop": coop,
				"label": ("Co-op " if coop else "") + mode_label(mode),
				"ranking": ranking(mode),
			})
	return out


static func descriptor(key: String) -> Dictionary:
	## Descriptor for a stable mode key, or {} for an unknown/future key.
	for entry in descriptors():
		if entry["key"] == key:
			return entry
	return {}


static func format_time(value: float) -> String:
	var minutes: int = int(value) / 60
	var seconds: float = value - minutes * 60
	return "%02d:%05.2f" % [minutes, seconds]


static func _mul32(a: int, b: int) -> int:
	# 32-bit multiply without 64-bit overflow: split a into 16-bit halves.
	var lo: int = ((a & 0xFFFF) * b) & 0xFFFFFFFF
	var hi: int = (((a >> 16) & 0xFFFF) * b) & 0xFFFF
	return (lo + (hi << 16)) & 0xFFFFFFFF
