extends "res://tests/test_lib.gd"
## Online co-op core unit tests: deterministic snapshots (bag/board/event
## state), snapshot validation, input intent validation, and the transport
## chunking helper. Pure headless: no EOSG, no network.

const CoopGameScript = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const InputIntent = preload("res://scripts/online/input_intent.gd")
const ServiceScript = preload("res://scripts/online/online_service.gd")
const Credentials = preload("res://scripts/online/online_credentials.gd")

const MARATHON = ModeRules.Mode.MARATHON

var _next_seed: int = 424242


func _new_coop(count: int = 2, mode: int = MARATHON) -> RefCounted:
	_next_seed += 7
	return CoopGameScript.new(count, mode, _next_seed)


func _tick(game: RefCounted, steps: int) -> void:
	for i in steps:
		game.tick(PlayConfig.FIXED_STEP)


# ---------------------------------------------------------------- snapshots

func test_snapshot_round_trip_identity() -> void:
	## A snapshot applied to a fresh same-configuration twin reproduces the
	## exact same wire state. (Mode/seed/player count are structural
	## identity: the twin must be constructed with them.)
	var game := _new_coop(2, MARATHON)
	_tick(game, 120)
	var snap: Dictionary = game.to_snapshot()
	var twin := CoopGameScript.new(2, MARATHON, game.seed)
	check_true(twin.apply_snapshot(snap), "twin accepts snapshot")
	check_eq(twin.to_snapshot(), snap, "applied twin serializes identically")


func test_snapshot_continues_deterministically() -> void:
	## After a snapshot transfer, host and client evolve identically from
	## the same state (the bag queue and PRNG state crossed the boundary).
	var host := _new_coop(3, MARATHON)
	_tick(host, 75)
	var snap: Dictionary = host.to_snapshot()
	var client := CoopGameScript.new(3, MARATHON, host.seed)
	check_true(client.apply_snapshot(snap), "client accepts host snapshot")
	_tick(host, 60)
	_tick(client, 60)
	check_eq(client.to_snapshot(), host.to_snapshot(), "post-snapshot evolution matches")


func test_snapshot_rejects_mode_mismatch() -> void:
	## Mode is structural identity: a snapshot from another mode is
	## rejected instead of force-applied.
	var game := _new_coop(2, MARATHON)
	_tick(game, 10)
	var snap: Dictionary = game.to_snapshot()
	var twin := CoopGameScript.new(2, ModeRules.Mode.SPRINT, game.seed)
	check_false(twin.apply_snapshot(snap), "marathon snapshot rejected by sprint twin")


func test_snapshot_rejects_version_mismatch() -> void:
	var game := _new_coop(2, MARATHON)
	_tick(game, 10)
	var snap: Dictionary = game.to_snapshot()
	var before: Dictionary = game.to_snapshot()
	snap["v"] = 9999
	check_false(game.apply_snapshot(snap), "bad version rejected")
	check_eq(game.to_snapshot(), before, "state untouched on reject")


func test_snapshot_rejects_player_count_mismatch() -> void:
	var game := _new_coop(4, MARATHON)
	_tick(game, 10)
	var snap: Dictionary = game.to_snapshot()
	var twin := CoopGameScript.new(2, MARATHON, 999999)
	check_false(twin.apply_snapshot(snap), "4-player snapshot rejected by 2-player twin")


func test_snapshot_rejects_malformed_payloads() -> void:
	var game := _new_coop(2, MARATHON)
	_tick(game, 10)
	check_false(game.apply_snapshot("not a dictionary"), "non-dictionary rejected")
	check_false(game.apply_snapshot({}), "empty dictionary rejected")

	var snap: Dictionary = game.to_snapshot()
	var before: Dictionary = game.to_snapshot()
	var players: Array = snap["players"]
	players[0] = "garbage"
	check_false(game.apply_snapshot(snap), "malformed player entry rejected")
	check_eq(game.to_snapshot(), before, "state untouched on malformed entry")

	snap = game.to_snapshot()
	snap["board"] = PackedInt32Array()
	check_false(game.apply_snapshot(snap), "wrong board size rejected")


# ------------------------------------------------------------------- intents

func test_intent_validator_accepts_owned_sequence() -> void:
	var guard = InputIntent.make_guard()
	var slot_of_peer := {100: 1}
	var verdict: int = InputIntent.validate(
		guard, 100, slot_of_peer, 1, 1, "move", -1, true, Time.get_ticks_msec()
	)
	check_eq(verdict, InputIntent.Verdict.OK, "first intent accepted")
	verdict = InputIntent.validate(
		guard, 100, slot_of_peer, 1, 2, "rotate", 1, true, Time.get_ticks_msec()
	)
	check_eq(verdict, InputIntent.Verdict.OK, "second intent accepted")


func test_intent_validator_rejects_replays_and_gaps() -> void:
	var guard = InputIntent.make_guard()
	var slot_of_peer := {100: 1}
	var now := Time.get_ticks_msec()
	InputIntent.validate(guard, 100, slot_of_peer, 1, 1, "move", -1, true, now)
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 1, 1, "move", -1, true, now),
		InputIntent.Verdict.STALE_SEQ, "replayed sequence rejected"
	)
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 1, 2 + InputIntent.MAX_SEQ_GAP, "move", -1, true, now),
		InputIntent.Verdict.GAP_SEQ, "large sequence gap rejected"
	)


func test_intent_validator_rejects_wrong_owner() -> void:
	var guard = InputIntent.make_guard()
	var slot_of_peer := {100: 1}
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 0, 1, "move", -1, true, Time.get_ticks_msec()),
		InputIntent.Verdict.WRONG_SLOT, "foreign slot rejected"
	)
	check_eq(
		InputIntent.validate(guard, 0, slot_of_peer, 1, 1, "move", -1, true, Time.get_ticks_msec()),
		InputIntent.Verdict.NOT_ROSTERED, "unrostered sender rejected"
	)


func test_intent_validator_rejects_bad_actions_and_phase() -> void:
	var guard = InputIntent.make_guard()
	var slot_of_peer := {100: 1}
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 1, 1, "explode", 0, true, Time.get_ticks_msec()),
		InputIntent.Verdict.BAD_ACTION, "unknown action rejected"
	)
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 1, 2, "move", 7, true, Time.get_ticks_msec()),
		InputIntent.Verdict.BAD_ACTION, "out-of-range move argument rejected"
	)
	check_eq(
		InputIntent.validate(guard, 100, slot_of_peer, 1, 3, "move", -1, false, Time.get_ticks_msec()),
		InputIntent.Verdict.BAD_PHASE, "intent outside ACTIVE phase rejected"
	)


func test_intent_validator_rate_limits() -> void:
	var guard = InputIntent.make_guard(2.0, 3.0)
	var slot_of_peer := {100: 1}
	var now := Time.get_ticks_msec()
	var accepted: int = 0
	for i in 10:
		var verdict: int = InputIntent.validate(
			guard, 100, slot_of_peer, 1, i + 1, "move", -1, true, now + i
		)
		if verdict == InputIntent.Verdict.OK:
			accepted += 1
	check_eq(accepted, 3, "burst bucket bounds accepted intents")


# ---------------------------------------------------------------- chunking

func test_snapshot_chunking() -> void:
	## The service splits wire payloads into transport-safe chunks.
	var service = ServiceScript.new()
	var small := PackedByteArray()
	small.resize(64)
	for i in 64:
		small[i] = i
	var chunks: Array = service._chunk(small)
	check_eq(chunks.size(), 1, "small payload is one chunk")

	var big := PackedByteArray()
	big.resize(ServiceScript.SNAPSHOT_CHUNK_BYTES * 2 + 100)
	chunks = service._chunk(big)
	check_eq(chunks.size(), 3, "oversize payload splits per chunk size")
	var total: int = 0
	for chunk in chunks:
		check(chunk is PackedByteArray, "chunks are byte arrays")
		check((chunk as PackedByteArray).size() <= ServiceScript.SNAPSHOT_CHUNK_BYTES, "chunk bounded")
		total += (chunk as PackedByteArray).size()
	check_eq(total, big.size(), "chunks reassemble to the original size")
	service.free()


# ------------------------------------------------------------ credentials

func test_credentials_example_is_committable() -> void:
	## The committed example template parses and yields every expected key,
	## with placeholder (non-secret) values.
	var creds: Dictionary = Credentials.load_credentials()
	check_eq(String(creds.get("_source", "")), "", "no local credentials file in test environment")
	for key in ["product_name", "product_version", "product_id", "sandbox_id", "deployment_id", "client_id", "client_secret", "encryption_key", "auth_mode"]:
		check(creds.has(key), "credentials defaults include %s" % key)
	check_false(Credentials.is_configured(creds), "placeholder defaults never count as configured")