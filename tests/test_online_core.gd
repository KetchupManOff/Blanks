extends "res://tests/test_lib.gd"
## Online co-op core unit tests: deterministic snapshots (bag/board/event
## state), snapshot validation, input intent validation, the transport
## chunking helper, the relay envelope codec, room-code rules, and
## service-level validation of inbound envelopes (sender/role/version/
## size). Pure headless: the only transport is the in-memory relay hub,
## never a network.

const CoopGameScript = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const InputIntent = preload("res://scripts/online/input_intent.gd")
const ServiceScript = preload("res://scripts/online/online_service.gd")
const NetScript = preload("res://scripts/online/online_net.gd")
const RelayContract = preload("res://scripts/online/relay_connection.gd")
const RelayMemory = preload("res://scripts/online/relay_memory.gd")

const MARATHON = ModeRules.Mode.MARATHON

var _next_seed: int = 424242
var _service: Node = null


func _new_coop(count: int = 2, mode: int = MARATHON) -> RefCounted:
	_next_seed += 7
	return CoopGameScript.new(count, mode, _next_seed)


func _tick(game: RefCounted, steps: int) -> void:
	for i in steps:
		game.tick(PlayConfig.FIXED_STEP)


## One in-tree service with a fresh in-memory relay hub, ready for room
## flows or direct envelope dispatch.
func _ensure_service() -> Node:
	if _service == null or not is_instance_valid(_service):
		_service = ServiceScript.new()
		_service.name = "OnlineCoreSvc"
		tree.root.add_child(_service)
	_service.leave_session()
	_service.use_memory_relay(RelayMemory.new())
	return _service


func teardown() -> void:
	if _service != null:
		_service.queue_free()
		_service = null


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


func test_lock_events_carry_stable_revisions() -> void:
	## Every lock event carries the engine's revision counter; snapshot
	## rebuilds on a twin restore the same revision so audio/HUD edges
	## identify host events without comparing object instances.
	var game := _new_coop(2, MARATHON)
	check_eq(game.event_revision, 0, "fresh game carries no event revision")
	var twin := CoopGameScript.new(2, MARATHON, game.seed)
	game.hard_drop(0)
	check_eq(game.event_revision, 1, "lock advances the event revision")
	var snap: Dictionary = game.to_snapshot()
	var event_snap: Dictionary = snap["players"][0]["event"]
	check_eq(event_snap["rev"], 1, "event payload carries the revision")
	check_eq(event_snap["hard_drop"], true, "hard-drop locks are flagged")
	check_true(twin.apply_snapshot(snap), "twin accepts the snapshot")
	check_eq(twin.event_revision, 1, "twin restores the revision counter")
	check_eq(twin.players[0].last_event.rev, 1, "rebuilt twin event carries the same revision")
	check_eq(twin.players[0].last_event.hard_drop, true, "rebuilt twin event keeps the flag")


func test_natural_locks_advance_revisions_unflagged() -> void:
	## Lock-delay expiry creates events without the hard-drop flag; the
	## revision advances exactly once per lock.
	var game := _new_coop(2, MARATHON)
	# Fill the bottom row: spawned pieces descend onto it (soft drop keeps
	# the descent fast), ground out, and lock through the lock delay.
	for x in game.board.WIDTH:
		game.debug_set_cell(x, game.board.HEIGHT - 1, TetrominoData.Kind.J)
	game.set_soft_drop(0, true)
	game.set_soft_drop(1, true)
	_tick(game, 600)
	check_true(game.players[0].last_event != null, "player 0 locked naturally on the filled row")
	check_eq(game.players[0].last_event.hard_drop, false, "natural locks carry no hard-drop flag")
	check_true(game.event_revision >= 1, "natural lock advanced the revision")
	var rev_before: int = game.event_revision
	var snap: Dictionary = game.to_snapshot()
	var twin := CoopGameScript.new(2, MARATHON, game.seed)
	check_true(twin.apply_snapshot(snap), "twin accepts the snapshot")
	check_eq(twin.event_revision, rev_before, "twin revision matches the host")
	check_eq(twin.players[0].last_event.hard_drop, false, "twin natural lock carries no flag")


func test_repeated_snapshot_apply_is_idempotent() -> void:
	## Applying an identical snapshot repeatedly never advances event
	## identity: the twin keeps the same revision (fresh objects per apply,
	## same authoritative revision) and audio edges stay quiet.
	var game := _new_coop(2, MARATHON)
	game.hard_drop(0)
	var snap: Dictionary = game.to_snapshot()
	var twin := CoopGameScript.new(2, MARATHON, game.seed)
	check_true(twin.apply_snapshot(snap), "first apply")
	var rev: int = twin.event_revision
	var event_rev: int = twin.players[0].last_event.rev
	var event_hard_drop: bool = twin.players[0].last_event.hard_drop
	for i in 5:
		check_true(twin.apply_snapshot(snap), "repeated apply %d accepted" % (i + 1))
		check_eq(twin.event_revision, rev, "revision unchanged by identical snapshots")
		check_eq(twin.players[0].last_event.rev, event_rev, "same host event revision observed")
		check_eq(twin.players[0].last_event.hard_drop, event_hard_drop, "event identity stable across rebuilds")
	check_eq(twin.to_snapshot(), snap, "twin state still identical")


# ------------------------------------------------------------- display names

func test_normalize_display_name() -> void:
	## The protocol-safe normalizer: one line, collapsed whitespace, no
	## control characters, bounded length, deterministic fallback.
	check_eq(ServiceScript.normalize_display_name("  Alice \n\t Quin  ", "FB"), "Alice Quin", "whitespace runs collapse and trim")
	check_eq(ServiceScript.normalize_display_name("Line1\r\nLine2", "FB"), "Line1 Line2", "newlines collapse to a single space")
	check_eq(ServiceScript.normalize_display_name("A  B C  D", "FB"), "A B C D", "multiple spaces collapse")
	check_eq(ServiceScript.normalize_display_name("AB".repeat(40), "FB"), "AB".repeat(8), "length capped to 16 characters")
	check_eq(ServiceScript.normalize_display_name("", "FB"), "FB", "empty falls back")
	check_eq(ServiceScript.normalize_display_name("   ", "FB"), "FB", "whitespace-only falls back")
	check_eq(ServiceScript.normalize_display_name(null, "FB"), "FB", "null falls back")
	check_eq(ServiceScript.normalize_display_name(7, "FB"), "7", "numbers stringify")
	check_eq(ServiceScript.normalize_display_name("\u0007Beep\u0007", "FB"), "Beep", "control characters excluded")
	var name := ServiceScript.normalize_display_name("  A  ", "")
	check_true(name.length() >= 1, "fallback itself never yields an empty name")


func test_pause_envelope_validation() -> void:
	## Pause replication is host-only and in-match only: clients ignore
	## peer/stale senders and malformed payloads, and the host never
	## applies a client frame.
	var host_stub := _pause_recording_host()
	var service := _ensure_service()
	service.game_host = host_stub
	service.is_host = false
	service.roster = [{"peer_id": 1, "name": "H", "ready": true, "slot": 0, "connected": true}]
	service._set_state(ServiceScript.State.IN_MATCH)
	# Non-host sender and malformed payloads are dropped.
	service._net.receive(2, NetScript.encode(NetScript.MSG_PAUSE_STATE, 2, {"paused": true, "rev": 3}))
	check_eq(host_stub.pause_applies.size(), 0, "client sender ignored")
	service._net.receive(1, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": "yes", "rev": 3}))
	check_eq(host_stub.pause_applies.size(), 0, "malformed paused ignored")
	service._net.receive(1, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": true, "rev": 1.5}))
	check_eq(host_stub.pause_applies.size(), 0, "float revision ignored")
	service._net.receive(1, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": true}))
	check_eq(host_stub.pause_applies.size(), 0, "missing revision ignored")
	# The host itself ignores pause frames entirely.
	service.is_host = true
	service._net.receive(2, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": true, "rev": 3}))
	check_eq(host_stub.pause_applies.size(), 0, "host never applies client pause frames")
	# Out-of-match frames are dropped even from the host.
	service.is_host = false
	service._set_state(ServiceScript.State.LOBBY)
	service._net.receive(1, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": true, "rev": 3}))
	check_eq(host_stub.pause_applies.size(), 0, "out-of-match pause ignored")
	# A valid frame applies through the GameHost hook.
	service._set_state(ServiceScript.State.IN_MATCH)
	service._net.receive(1, NetScript.encode(NetScript.MSG_PAUSE_STATE, 1, {"paused": true, "rev": 3}))
	check_eq(host_stub.pause_applies, [[true, 3]], "valid pause applied by revision")
	service.leave_session()
	service.game_host = null
	host_stub.free()


class PauseRecordingHost:
	extends Node
	var pause_applies: Array = []

	func online_set_paused(paused: bool, rev: int) -> void:
		pause_applies.append([paused, rev])


func _pause_recording_host() -> Node:
	return PauseRecordingHost.new()


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


# ---------------------------------------------------------------- envelopes

func test_envelope_round_trip() -> void:
	var net := NetScript.new()
	var payload := net.encode(NetScript.MSG_LOBBY_STATE, 1, {"mode": 2, "phase": "lobby"})
	var envelope := net.decode(payload)
	check_eq(String(envelope.get("t")), NetScript.MSG_LOBBY_STATE, "message type preserved")
	check_eq(int(envelope.get("v")), 1, "protocol version preserved")
	check_eq(envelope.get("d"), {"mode": 2, "phase": "lobby"}, "payload preserved")


func test_envelope_round_trip_with_bytes() -> void:
	var net := NetScript.new()
	var blob := PackedByteArray([1, 2, 3, 250])
	var payload := net.encode(
		NetScript.MSG_SNAPSHOT, 1, {"id": 1, "part": 0, "count": 1, "bytes": blob}
	)
	var envelope := net.decode(payload)
	var data: Dictionary = envelope.get("d")
	check_eq(data.get("bytes"), blob, "packed bytes preserved")
	check_eq(int(data.get("count")), 1, "nested integers preserved")


func test_envelope_rejects_malformed_payloads() -> void:
	var net := NetScript.new()
	check_eq(net.decode(PackedByteArray()), {}, "empty payload rejected")
	var garbage := PackedByteArray()
	garbage.resize(40)
	for i in 40:
		garbage[i] = (i * 7) % 256
	check_eq(net.decode(garbage), {}, "garbage bytes rejected")
	check_eq(net.decode(var_to_bytes([1, 2, 3])), {}, "non-dictionary rejected")
	check_eq(net.decode(var_to_bytes({"v": 1, "d": {}})), {}, "missing type rejected")
	check_eq(net.decode(var_to_bytes({"t": "", "v": 1, "d": {}})), {}, "empty type rejected")
	check_eq(net.decode(var_to_bytes({"t": "x", "v": 0, "d": {}})), {}, "bad version rejected")
	check_eq(net.decode(var_to_bytes({"t": "x", "v": 1})), {}, "missing data rejected")


func test_envelope_rejects_oversized_payloads() -> void:
	var net := NetScript.new()
	var big := PackedByteArray()
	big.resize(NetScript.MAX_ENVELOPE_BYTES + 1)
	check_eq(net.decode(big), {}, "oversized envelope rejected before dispatch")


# -------------------------------------------------------------- room codes

func test_room_code_rules() -> void:
	check_eq(RelayContract.normalize_room_code("  ab c-d "), "ABCD", "case/spacing/dashes normalized")
	check_eq(RelayContract.normalize_room_code("K7QPZM2"), "K7QPZM2", "already-clean code unchanged")
	check_true(RelayContract.is_valid_room_code("ABCDEFG"), "7-letter code valid")
	check_true(RelayContract.is_valid_room_code("ABCD"), "short code valid (relay is authoritative on length)")
	check_false(RelayContract.is_valid_room_code("ABC"), "too short rejected")
	check_false(RelayContract.is_valid_room_code("ABCDEFGHIJKLMNOPQ"), "too long rejected")
	check_false(RelayContract.is_valid_room_code("ABC1"), "digit rejected")
	check_false(RelayContract.is_valid_room_code("ABCI"), "ambiguous I rejected")
	check_false(RelayContract.is_valid_room_code("ABCO"), "ambiguous O rejected")
	check_false(RelayContract.is_valid_room_code("ABCU"), "ambiguous U rejected")


func test_join_rejects_invalid_codes_locally() -> void:
	var service := _ensure_service()
	check_true(service.ensure_ready(), "service READY with the test endpoint")
	service.join_lobby("12!!")
	check_eq(service.state, ServiceScript.State.ERROR, "invalid code rejected before any relay round trip")
	check_true(
		String(service.status_text).contains("Invalid room code"),
		"invalid code surfaces an actionable status"
	)
	# ERROR is retryable: a well-formed-but-unknown code starts a fresh
	# flow and the in-memory relay answers not_found.
	service.join_lobby("ZZZZZZZ")
	check_eq(service.state, ServiceScript.State.ERROR, "unknown code surfaces the relay rejection")
	check_true(
		String(service.status_text).contains("Room not found"),
		"unknown code surfaces an actionable status"
	)
	service.leave_session()
	check_eq(service.state, ServiceScript.State.READY, "leave returns to READY")


# --------------------------------------------------- inbound frame validation

func test_host_ignores_host_only_messages_from_non_host() -> void:
	## Host-only broadcasts (lobby state, match start, results, return)
	## are ignored unless the relay-stamped sender is the host (peer 1).
	var service := _ensure_service()
	check_true(service.ensure_ready(), "READY")
	check_true(service.create_lobby(), "room created")
	var mode_before: int = service.lobby_mode
	service._net.receive(3, NetScript.encode(
		NetScript.MSG_LOBBY_STATE, 1, {"mode": 99, "phase": "match", "roster": []}
	))
	service._net.receive(3, NetScript.encode(
		NetScript.MSG_MATCH_STARTED, 1, {"mode": 99, "seed": 1, "player_count": 1, "roster": []}
	))
	service._net.receive(3, NetScript.encode(
		NetScript.MSG_ROUND_FINISHED, 1, {"title": "X", "subtitle": ""}
	))
	service._net.receive(3, NetScript.encode(NetScript.MSG_RETURN_TO_LOBBY, 1, {}))
	check_eq(service.roster.size(), 1, "roster untouched by non-host state")
	check_eq(service.state, ServiceScript.State.LOBBY, "host stays in LOBBY")
	check_eq(service.lobby_mode, mode_before, "mode untouched")
	service.leave_session()


func test_host_rejects_unrostered_and_wrong_version_hellos() -> void:
	var service := _ensure_service()
	check_true(service.ensure_ready(), "READY")
	check_true(service.create_lobby(), "room created")
	# Wrong protocol version: rejected before any handler runs.
	service._net.receive(2, NetScript.encode(NetScript.MSG_CLIENT_HELLO, 999, {"name": "Rogue"}))
	check_eq(service.roster.size(), 1, "wrong-version hello never rosters")
	# The host itself can never be rostered as a client.
	service._net.receive(1, NetScript.encode(NetScript.MSG_CLIENT_HELLO, 1, {"name": "Twin"}))
	check_eq(service.roster.size(), 1, "host never rosters itself")
	# Malformed payloads are ignored entirely.
	service._net.receive(2, PackedByteArray([1, 2, 3]))
	check_eq(service.roster.size(), 1, "garbage frame ignored")
	service._net.receive(2, var_to_bytes([1, 2, 3]))
	check_eq(service.roster.size(), 1, "non-dictionary envelope ignored")
	# Unknown message types are dropped with a warning, never dispatched.
	service._net.receive(2, NetScript.encode("bogus_type", 1, {}))
	check_eq(service.roster.size(), 1, "unknown message type ignored")
	service.leave_session()


func test_client_ignores_client_only_messages() -> void:
	## Client-only messages (hello, ready, intents) are ignored by a client
	## no matter who sent them.
	var service := _ensure_service()
	service.is_host = false
	service.roster = [{"peer_id": 1, "name": "H", "ready": true, "slot": 0, "connected": true}]
	service._set_state(ServiceScript.State.LOBBY)
	service._net.receive(1, NetScript.encode(NetScript.MSG_CLIENT_HELLO, 1, {"name": "X"}))
	service._net.receive(1, NetScript.encode(NetScript.MSG_SET_READY, 1, {"ready": true}))
	service._net.receive(1, NetScript.encode(
		NetScript.MSG_INTENT, 1, {"slot": 0, "seq": 1, "action": "move", "arg": -1}
	))
	check_eq(service.roster.size(), 1, "client ignores client-only messages (no roster change)")
	service.leave_session()


# ------------------------------------------------------------- size limits

func test_send_refuses_oversized_envelopes() -> void:
	var service := _ensure_service()
	check_true(service.ensure_ready(), "READY")
	check_true(service.create_lobby(), "room created")
	var blob := PackedByteArray()
	blob.resize(NetScript.MAX_ENVELOPE_BYTES)
	check_false(
		service._send_envelope(NetScript.MSG_LOBBY_STATE, {"blob": blob}),
		"oversized payload refused before the transport"
	)
	var huge := PackedByteArray()
	huge.resize(RelayMemory.MAX_FRAME_BYTES + 1)
	check_false(
		service._relay.send(huge),
		"transport rejects frames past the relay packet limit"
	)
	service.leave_session()
