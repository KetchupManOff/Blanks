extends RefCounted
## Mode progression rules, the Guideline marathon gravity curve, and the
## stable mode identity/ranking metadata used by profile result histories.
## Modes are identified by stable string keys ("solo_marathon",
## "coop_sprint", ...) so persistence never depends on enum values; a new
## mode only registers a descriptor and reuses the same pipeline.
const PlayConfig = preload("res://scripts/core/constants.gd")

enum Mode { MARATHON, SPRINT, CLASSIC_VERSUS, TOWER }

## Ranking rules for finished runs: higher score wins or lower time wins.
const RANK_SCORE_DESC := "score_desc"
const RANK_TIME_ASC := "time_asc"
## Solo Tower ranks by stack height ascending, then score descending.
const RANK_HEIGHT_ASC := "height_asc"

## Tower is a fixed-duration mode; the shared match clock counts down
## from this value.
const TOWER_DURATION_SECONDS: float = 180.0

## Versus garbage attack table: base lines per clear type. Combos and
## back-to-back difficult clears add bonuses at attack time.
const ATTACK_SINGLE: int = 0
const ATTACK_DOUBLE: int = 1
const ATTACK_TRIPLE: int = 2
const ATTACK_BLANKS: int = 4
const ATTACK_TSPIN_SINGLE: int = 2
const ATTACK_TSPIN_DOUBLE: int = 4
const ATTACK_TSPIN_TRIPLE: int = 6


static func is_competitive(mode: int) -> bool:
	## Independent-board competitive modes (versus / tower) run on
	## CompetitiveGame instead of the solo/coop cores.
	return mode == Mode.CLASSIC_VERSUS or mode == Mode.TOWER


static func valid_competitive_match(mode: int, player_count: int, garbage_enabled: bool) -> bool:
	## Match configurations the competitive core accepts: Classic Versus
	## needs 2-4 players and may run with or without garbage; Tower allows
	## 1-4 players and never garbage.
	if mode == Mode.CLASSIC_VERSUS:
		return player_count >= 2 and player_count <= 4
	if mode == Mode.TOWER:
		return player_count >= 1 and player_count <= 4 and not garbage_enabled
	return false


static func gravity_seconds(mode: int, level: int) -> float:
	# Seconds a piece takes to fall one row under natural gravity.
	if mode == Mode.SPRINT or mode == Mode.CLASSIC_VERSUS or mode == Mode.TOWER:
		# Sprint and the competitive modes use fixed level-1 style
		# gravity; speed comes from soft/hard drop.
		return 1.0
	var clamped: int = clampi(level, 1, PlayConfig.MARATHON_MAX_LEVEL)
	return pow(0.8 - (clamped - 1) * 0.007, clamped - 1)


static func level_after_lines(mode: int, total_lines: int) -> int:
	if mode != Mode.MARATHON:
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
	## Competitive modes never route multiplayer outcomes through here:
	## solo Tower records under "solo_tower" and every multiplayer
	## competitive outcome goes to the separate match history instead.
	var prefix := "coop_" if coop else "solo_"
	match mode:
		Mode.SPRINT:
			return prefix + "sprint"
		Mode.TOWER:
			return prefix + "tower"
		Mode.CLASSIC_VERSUS:
			return "classic_versus"
		_:
			return prefix + "marathon"


static func match_mode_key(mode: int) -> String:
	## Stable mode identity inside multiplayer match-history records.
	return "classic_versus" if mode == Mode.CLASSIC_VERSUS else "tower"


static func mode_label(mode: int) -> String:
	## Human-readable mode name for result histories.
	match mode:
		Mode.SPRINT:
			return "40-Line Sprint"
		Mode.CLASSIC_VERSUS:
			return "Classic Versus"
		Mode.TOWER:
			return "Tower"
		_:
			return "Marathon"


static func mode_display_name(mode: int) -> String:
	## Upper-case display name for menus and the coop lobby.
	match mode:
		Mode.SPRINT:
			return "40-LINE SPRINT"
		Mode.CLASSIC_VERSUS:
			return "CLASSIC VERSUS"
		Mode.TOWER:
			return "TOWER"
		_:
			return "MARATHON"


static func ranking(mode: int) -> String:
	## Which metric a finished run is ranked by within one mode key.
	match mode:
		Mode.SPRINT:
			return RANK_TIME_ASC
		Mode.TOWER:
			return RANK_HEIGHT_ASC
		_:
			return RANK_SCORE_DESC


static func higher_score_wins(mode: int) -> bool:
	return ranking(mode) == RANK_SCORE_DESC


static func records_on_game_over(mode: int) -> bool:
	## Marathon runs record on the game-over transition; a sprint game
	## over is an abandoned goal attempt and records nothing. Competitive
	## modes record through their own result paths, never these hooks.
	return mode == Mode.MARATHON


static func records_on_finish(mode: int) -> bool:
	## Sprint records only when the line goal is completed; marathon
	## never finishes (it ends on game over instead). Competitive modes
	## record through their own result paths, never these hooks.
	return mode == Mode.SPRINT


static func descriptors() -> Array:
	## All known run variants with their stable keys, labels, and ranking
	## rules. A new mode registers itself here and everywhere else follows.
	## The trailing competitive entries describe the multiplayer
	## match-history modes (marked "match_history") so display code can
	## find their labels; their outcomes never enter the best-run tables.
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
	out.append({
		"key": "solo_tower",
		"mode": Mode.TOWER,
		"coop": false,
		"label": mode_label(Mode.TOWER),
		"ranking": RANK_HEIGHT_ASC,
	})
	out.append({
		"key": match_mode_key(Mode.CLASSIC_VERSUS),
		"mode": Mode.CLASSIC_VERSUS,
		"coop": true,
		"label": mode_label(Mode.CLASSIC_VERSUS),
		"ranking": RANK_SCORE_DESC,
		"match_history": true,
	})
	out.append({
		"key": match_mode_key(Mode.TOWER),
		"mode": Mode.TOWER,
		"coop": true,
		"label": mode_label(Mode.TOWER),
		"ranking": RANK_HEIGHT_ASC,
		"match_history": true,
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
