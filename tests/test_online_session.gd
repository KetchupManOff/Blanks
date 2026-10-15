extends "res://tests/test_lib.gd"
## End-to-end online session protocol tests: two OnlineService instances
## (host + client), each attached to a shared in-memory relay hub
## (relay_memory.gd) that mirrors the deployed relay's semantics. This
## exercises the REAL wire protocol - room create/join, hello handshake,
## roster broadcast, ready gate, match start, intents, chunked
## snapshots, results, return to lobby, and disconnect teardown -
## without a network: sends land synchronously in the receiver's inbox
## and frames are pumped by stepping each service's _process.

const CoopGameScript = preload("res://scripts/core/coop_game.gd")
const CompetitiveGameScript = preload("res://scripts/core/competitive_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const ServiceScript = preload("res://scripts/online/online_service.gd")
const NetScript = preload("res://scripts/online/online_net.gd")
const RelayMemory = preload("res://scripts/online/relay_memory.gd")
const RelayMemoryConnection = preload("res://scripts/online/relay_connection_memory.gd")

const ACTIVE_PHASE = 0


## Minimal GameHost stand-in: implements every OnlineService hook against
## a real CoopGame so snapshot/intent semantics are exercised for real. The
## stubs are named (settable profile names) and pause-aware (a paused flag
## gating phase activity plus recorded pause applies) so identity refresh
## and host-authoritative pause flows can be driven from the protocol.
class StubHost:
	extends Node

	var coop: RefCounted = null
	var config_seen: Dictionary = {}
	var begins: int = 0
	var intents: Array = []
	var snapshots_applied: int = 0
	var results: Array = []
	var lobby_returns: int = 0
	var leaves: int = 0
	var errors: Array = []
	var profile_name_value: String = "Stub"
	var paused: bool = false
	var pause_states: Array = []
	var _pause_state: bool = false
	var _pause_rev: int = 0

	func _build(config: Dictionary) -> void:
		config_seen = config
		var mode := int(config.get("mode", ModeRules.Mode.MARATHON))
		if ModeRules.is_competitive(mode):
			coop = CompetitiveGameScript.new(
				mode,
				int(config.get("seed", 0)),
				clampi(int(config.get("player_count", 1)), 1, 4),
				bool(config.get("garbage", false))
			)
		else:
			coop = CoopGameScript.new(
				clampi(int(config.get("player_count", 1)), 1, 4),
				mode,
				int(config.get("seed", 0))
			)

	func online_begin_host_match(config: Dictionary) -> void:
		begins += 1
		_build(config)

	func online_begin_client_match(config: Dictionary) -> void:
		begins += 1
		_build(config)

	func online_snapshot() -> Dictionary:
		if coop == null:
			return {}
		return coop.to_snapshot()

	func online_phase_active() -> bool:
		## The authoritative paused state gates intent acceptance exactly
		## like GameHost does (before any sequence bookkeeping).
		return coop != null and coop.phase == ACTIVE_PHASE and not paused

	func online_set_paused(paused_now: bool, rev: int) -> void:
		## Mirrors GameHost: an older revision never overwrites a newer
		## state and a duplicate never re-applies.
		if rev < _pause_rev:
			return
		if rev == _pause_rev and paused_now == _pause_state:
			return
		_pause_state = paused_now
		_pause_rev = rev
		pause_states.append([paused_now, rev])

	func active_profile_name() -> String:
		return profile_name_value

	func online_apply_intent(slot: int, action: String, arg: int) -> void:
		intents.append({"slot": slot, "action": action, "arg": arg})
		if coop == null:
			return
		match action:
			"move":
				coop.try_move(slot, arg)
			"rotate":
				coop.rotate(slot, arg)
			"soft_drop":
				coop.set_soft_drop(slot, arg != 0)
			"hard_drop":
				coop.hard_drop(slot)
			"hold":
				coop.hold(slot)

	func online_apply_snapshot(snapshot) -> void:
		if snapshot is Dictionary and coop != null and coop.apply_snapshot(snapshot):
			snapshots_applied += 1

	func online_show_results(result: Dictionary) -> void:
		results.append(result)

	func online_return_to_lobby() -> void:
		lobby_returns += 1

	func online_leave_session(_was_in_match: bool) -> void:
		leaves += 1

	func online_session_error(text: String) -> void:
		errors.append(text)


var _host_svc: Node = null
var _client_svc: Node = null
var _host_stub: StubHost = null
var _client_stub: StubHost = null
var _hub: RelayMemory = null
var _extras: Array = []


func setup() -> void:
	_host_stub = StubHost.new()
	tree.root.add_child(_host_stub)
	_client_stub = StubHost.new()
	tree.root.add_child(_client_stub)

	_host_svc = ServiceScript.new()
	_host_svc.name = "HostSvc"
	tree.root.add_child(_host_svc)
	_host_svc.game_host = _host_stub

	_client_svc = ServiceScript.new()
	_client_svc.name = "ClientSvc"
	tree.root.add_child(_client_svc)
	_client_svc.game_host = _client_stub

	_reset_session()


func teardown() -> void:
	if _host_svc != null:
		_host_svc.leave_session()
		_host_svc.queue_free()
	if _client_svc != null:
		_client_svc.leave_session()
		_client_svc.queue_free()
	for svc in _extras:
		svc.leave_session()
		svc.queue_free()
	_extras = []
	if _host_stub != null:
		_host_stub.queue_free()
	if _client_stub != null:
		_client_stub.queue_free()


## Reset any session left over from a previous test in this suite (the
## runner shares one setup() across tests) and pair both services with
## a fresh in-memory relay hub.
func _reset_session() -> void:
	if _client_svc != null:
		_client_svc.leave_session()
	if _host_svc != null:
		_host_svc.leave_session()
	_hub = RelayMemory.new()
	_host_svc.use_memory_relay(_hub)
	_client_svc.use_memory_relay(_hub)
	_host_stub.coop = null
	_client_stub.coop = null
	_host_stub.intents = []
	_host_stub.begins = 0
	_client_stub.begins = 0
	_client_stub.snapshots_applied = 0
	_client_stub.results = []
	_client_stub.lobby_returns = 0
	_client_stub.leaves = 0
	_client_stub.errors = []
	_host_stub.paused = false
	_host_stub.pause_states = []
	_client_stub.pause_states = []
	_host_stub._pause_state = false
	_host_stub._pause_rev = 0
	_client_stub._pause_state = false
	_client_stub._pause_rev = 0


## Extra client services for multi-client tests, freed in teardown.
func _make_client_service(service_name: String) -> Node:
	var svc: Node = ServiceScript.new()
	svc.name = service_name
	tree.root.add_child(svc)
	_extras.append(svc)
	return svc


## Manual frame pump: each step polls both services; the in-memory
## relay delivers synchronously into receiver inboxes, so host->client
## or client->host round trips complete within a step or two and the
## loop is purely logic-driven (no wall-clock waiting).
func _pump_until(predicate: Callable, max_steps: int = 200) -> bool:
	for i in max_steps:
		if predicate.call():
			return true
		_step_frame()
	return predicate.call()


func _pump(steps: int = 10) -> void:
	for i in steps:
		_step_frame()


func _step_frame() -> void:
	if _host_svc != null:
		_host_svc._process(0.016)
	if _client_svc != null:
		_client_svc._process(0.016)


func _in_match(service: Node) -> bool:
	return service != null and service.state == ServiceScript.State.IN_MATCH


func _in_lobby(service: Node) -> bool:
	return service != null and service.state == ServiceScript.State.LOBBY


func _client_ready() -> bool:
	return _host_svc.roster.size() == 2 and bool(_host_svc.roster[1]["ready"])


# ---------------------------------------------------------------------- tests

func test_full_session_flow() -> void:
	## One full round: room create/join/handshake, ready gate, match
	## start, intents client->host, snapshots host->client, results,
	## lobby return, ready reset, second round, client leave teardown.
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host reaches READY")
	check_true(_client_svc.ensure_ready(), "client reaches READY")

	# --- room create (host connects to the relay and becomes peer 1) ---
	check_true(_host_svc.create_lobby(), "room create flow completed")
	check_eq(_host_svc.state, ServiceScript.State.LOBBY, "host in LOBBY")
	check_true(_host_svc.is_host, "host role set")
	check_eq(_host_svc.roster.size(), 1, "host rostered alone")
	check_eq(_host_svc.own_slot, 0, "host owns slot 0")
	var code: String = _host_svc.session_code()
	check_false(code.is_empty(), "room code exposed for joining")
	check_eq(code.length(), 7, "room code uses the 7-character relay format")
	check_eq(_host_svc.local_peer_id(), 1, "host is relay peer 1")

	# --- join + hello handshake + roster broadcast ---
	_client_svc.join_lobby(code)
	check_eq(_client_svc.state, ServiceScript.State.CONNECTING, "client CONNECTING after join")
	check_eq(_client_svc.local_peer_id(), 2, "client assigned relay peer 2")
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client reaches LOBBY after handshake")
	if not _in_lobby(_client_svc):
		return
	check_eq(_client_svc.own_slot, 1, "client assigned slot 1")
	check_eq(_client_svc.session_code(), code, "client retains the canonical room code")
	check_eq(_client_svc.roster.size(), 2, "client sees full roster")
	check_eq(_host_svc.roster.size(), 2, "host roster includes client")
	check_eq(int(_host_svc.roster[1]["peer_id"]), 2, "host rostered the relay-stamped peer id")

	# --- ready gate: start is blocked until the client is ready ---
	check_false(_host_svc.start_round(), "start blocked before client ready")
	_client_svc.set_ready(true)
	check_true(_pump_until(_client_ready), "host sees client ready")
	check_true(bool(_host_svc.roster[1]["ready"]), "host sees client ready")

	# --- match start (config broadcast, role split) ---
	check_true(_host_svc.start_round(), "host starts the round")
	check_eq(_host_svc.state, ServiceScript.State.IN_MATCH, "host IN_MATCH")
	check_eq(_host_stub.begins, 1, "host stub began the authoritative match")
	check_eq(_host_stub.coop.player_count, 2, "match built for the roster size")
	check_true(_pump_until(func() -> bool:
		return _in_match(_client_svc) and _client_stub.begins == 1), "client begins the twin match")
	check_eq(_client_svc.state, ServiceScript.State.IN_MATCH, "client IN_MATCH")
	check_eq(_client_stub.begins, 1, "client stub began the twin match")
	check_eq(_client_stub.coop.player_count, 2, "twin built for the same roster size")
	check_eq(_client_stub.coop.mode, _host_stub.coop.mode, "mode travels in match config")
	check_eq(_client_stub.coop.seed, _host_stub.coop.seed, "seed travels in match config")
	# GameHost sends the authoritative initial state immediately at match start.
	_host_svc.host_match_frame(0.0, true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied >= 1),
		"initial snapshot arrived"
	)

	# --- intents: client moves its own slot, host validates + applies ---
	_client_svc.submit_intent(1, "move", -1)
	check_true(
		_pump_until(func() -> bool: return _host_stub.intents.size() == 1),
		"host applied the client intent"
	)
	check_eq(_host_stub.intents.size(), 1, "host applied exactly one intent")
	if _host_stub.intents.size() == 1:
		check_eq(int(_host_stub.intents[0]["slot"]), 1, "intent routed to the owning slot")
		check_eq(String(_host_stub.intents[0]["action"]), "move", "intent action preserved")
	# Foreign slots never even send (client-side ownership guard).
	_client_svc.submit_intent(0, "move", -1)
	_pump(10)
	check_eq(_host_stub.intents.size(), 1, "client cannot act on foreign slots")

	# --- snapshots: structural snapshot converges the twin ---
	_tick_host(30)
	_host_svc.host_match_frame(0.0, true)  # structural -> immediate
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied >= 2),
		"further snapshots applied"
	)
	check_true(_client_stub.snapshots_applied >= 2, "further snapshots applied")
	if _host_stub.coop != null and _client_stub.coop != null:
		check_eq(
			(_client_stub.coop.to_snapshot() as Dictionary).get("board"),
			(_host_stub.coop.to_snapshot() as Dictionary).get("board"),
			"client board converged to the host board"
		)
	# Advance the first round beyond the fresh guard's allowed sequence gap.
	# The second round must restart both the sender and validator sequences.
	for i in 40:
		_client_svc.submit_intent(1, "move", -1 if i % 2 == 0 else 1)
	check_true(
		_pump_until(func() -> bool: return _host_stub.intents.size() == 41),
		"first-round intent sequence advances beyond the gap threshold"
	)

	# --- results: host broadcasts, both keep the room (relay persists) ---
	_host_svc.host_round_finished({"title": "GAME OVER", "subtitle": "test round"})
	check_eq(_host_svc.state, ServiceScript.State.LOBBY, "host returns to LOBBY after the round")
	check_false(bool(_host_svc.roster[1]["ready"]), "ready flags reset after the round")
	check_true(
		_pump_until(func() -> bool: return _client_stub.results.size() == 1),
		"client received the result"
	)
	check_eq(_client_stub.results.size(), 1, "client received the result")
	check_eq(_client_svc.state, ServiceScript.State.LOBBY, "client enters LOBBY when results arrive")
	check_false(bool(_client_svc.roster[1]["ready"]), "client mirrors the next-round ready reset")
	if _client_stub.results.size() == 1:
		check_eq(String(_client_stub.results[0]["title"]), "GAME OVER", "result title preserved")

	# --- return to lobby: clients can close results independently; the host
	# broadcast remains safe and idempotent after that local transition. ---
	_client_svc.client_return_to_lobby()
	check_eq(_client_stub.lobby_returns, 1, "client can return locally without waiting for the host screen")
	_host_svc.host_return_to_lobby()
	check_true(
		_pump_until(func() -> bool: return _client_stub.lobby_returns == 2),
		"client returned to the lobby with the host"
	)
	check_eq(_client_stub.lobby_returns, 2, "host return remains harmless after the client returned locally")
	check_eq(_client_svc.lobby_phase, "lobby", "client lobby phase reset")

	# --- ready gate again for the next round ---
	_client_svc.set_ready(true)
	check_true(
		_pump_until(_client_ready),
		"ready toggles again in the persistent room"
	)
	check_true(_host_svc.start_round(), "second round starts from the same room")
	check_eq(_host_stub.begins, 2, "second round begins on the host")
	check_true(_pump_until(func() -> bool:
		return _in_match(_client_svc) and _client_stub.begins == 2), "second round begins on the client")
	check_eq(_client_stub.begins, 2, "second round begins on the client")
	var intents_before_second_round := _host_stub.intents.size()
	_client_svc.submit_intent(1, "move", -1)
	check_true(
		_pump_until(func() -> bool: return _host_stub.intents.size() == intents_before_second_round + 1),
		"second-round client input reaches the host after sequence reset"
	)
	if _host_stub.intents.size() == intents_before_second_round + 1:
		check_eq(int(_host_stub.intents[-1]["slot"]), 1, "second-round input keeps client board ownership")

	# --- client leave: host roster shrinks, match continues ---
	_client_svc.leave_session()
	check_true(
		_pump_until(func() -> bool: return _host_svc.roster.size() == 1),
		"host roster shrinks after client leave"
	)
	check_eq(_client_svc.state, ServiceScript.State.READY, "client back at READY after leave")
	check_eq(_client_stub.leaves, 1, "client host hook observed the leave")
	check_eq(_host_svc.state, ServiceScript.State.IN_MATCH, "host match continues after the leave")


func test_competitive_versus_round_flow() -> void:
	## A Classic Versus round through the same protocol: the lobby carries
	## the mode and the host garbage setting, the match config travels both,
	## twin CompetitiveGames converge through snapshots, and the results
	## broadcast ends the round.
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_client_svc.ensure_ready(), "client READY")
	check_true(_host_svc.create_lobby(), "room created")
	_host_svc.set_mode(ModeRules.Mode.CLASSIC_VERSUS)
	_host_svc.set_garbage(false)
	var code: String = _host_svc.session_code()
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")
	check_eq(_client_svc.lobby_mode, ModeRules.Mode.CLASSIC_VERSUS, "mode broadcast to the client lobby")
	check_eq(_client_svc.lobby_garbage, false, "garbage setting broadcast to the client lobby")

	_client_svc.set_ready(true)
	check_true(_pump_until(_client_ready), "client ready")
	check_true(_host_svc.start_round(), "competitive round starts")
	check_eq(_host_stub.begins, 1, "host began the authoritative match")
	check_true(_host_stub.coop is CompetitiveGameScript, "host runs the competitive core")
	check_eq(_host_stub.coop.garbage_enabled, false, "garbage choice traveled in the config")

	check_true(_pump_until(func() -> bool:
		return _in_match(_client_svc) and _client_stub.begins == 1), "client began the twin match")
	check_true(_client_stub.coop is CompetitiveGameScript, "client runs the competitive twin")
	check_eq(_client_stub.coop.player_count, 2, "twin built for the roster size")
	check_eq(_client_stub.coop.seed, _host_stub.coop.seed, "seed travels in the match config")
	check_eq(bool(_client_stub.config_seen.get("garbage", true)), false, "garbage travels in the match config")

	# Authoritative initial state, then intents and snapshots.
	_host_svc.host_match_frame(0.0, true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied >= 1),
		"initial competitive snapshot arrived"
	)
	_client_svc.submit_intent(1, "move", -1)
	check_true(
		_pump_until(func() -> bool: return _host_stub.intents.size() == 1),
		"host applied the client intent to the versus board"
	)
	_tick_host(30)
	_host_svc.host_match_frame(0.0, true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied >= 2),
		"further competitive snapshots applied"
	)
	check_true(_host_stub.coop != null and _client_stub.coop != null, "both competitive cores alive")
	if _host_stub.coop != null and _client_stub.coop != null:
		var host_boards: Array = (_host_stub.coop.to_snapshot() as Dictionary)["players"]
		var client_boards: Array = (_client_stub.coop.to_snapshot() as Dictionary)["players"]
		for i in host_boards.size():
			check_eq(
				(client_boards[i]["board"] as Dictionary)["cells"],
				(host_boards[i]["board"] as Dictionary)["cells"],
				"client board %d converged to the host board" % i
			)

	# Results end the round the same way as co-op.
	_host_svc.host_round_finished({"title": "PLAYER 1 WINS!", "subtitle": "Classic Versus - 2P"})
	check_eq(_host_svc.state, ServiceScript.State.LOBBY, "host back to LOBBY")
	check_true(
		_pump_until(func() -> bool: return _client_stub.results.size() == 1),
		"client received the versus result"
	)
	if _client_stub.results.size() == 1:
		check_eq(String(_client_stub.results[0]["title"]), "PLAYER 1 WINS!", "versus title preserved")


func test_client_rejects_malformed_competitive_config() -> void:
	## A malformed competitive match config (garbage forced on Tower, or a
	## one-player Versus) fails closed into the session error path instead
	## of building a match the client cannot validate.
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_client_svc.ensure_ready(), "client READY")
	check_true(_host_svc.create_lobby(), "room created")
	var code: String = _host_svc.session_code()
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")

	# Forge a host broadcast with Tower plus garbage: rejected, torn down.
	_client_svc._net.receive(1, NetScript.encode(NetScript.MSG_MATCH_STARTED, 1, {
		"mode": ModeRules.Mode.TOWER,
		"seed": 1,
		"player_count": 2,
		"garbage": true,
		"roster": [{"name": "A"}, {"name": "B"}],
	}))
	check_eq(_client_stub.begins, 0, "no match built from the malformed config")
	check_eq(_client_stub.errors.size(), 1, "the client surfaced an actionable error")
	if _client_stub.errors.size() == 1:
		check_true(String(_client_stub.errors[0]).contains("REJECTED"), "error names the rejection")
	check_eq(_client_svc.state, ServiceScript.State.READY, "session torn down after the rejection")

	# A one-player Versus config is equally invalid after rejoining.
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client rejoined")
	_client_svc._net.receive(1, NetScript.encode(NetScript.MSG_MATCH_STARTED, 1, {
		"mode": ModeRules.Mode.CLASSIC_VERSUS,
		"seed": 2,
		"player_count": 1,
		"garbage": false,
		"roster": [{"name": "A"}],
	}))
	check_eq(_client_stub.begins, 0, "no match built from the one-player versus config")
	check_eq(_client_stub.errors.size(), 2, "the second rejection surfaced too")
	check_eq(_client_svc.state, ServiceScript.State.READY, "session torn down again")

	# A well-formed Tower config still begins the twin.
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client rejoined (2)")
	_client_svc._net.receive(1, NetScript.encode(NetScript.MSG_MATCH_STARTED, 1, {
		"mode": ModeRules.Mode.TOWER,
		"seed": 3,
		"player_count": 2,
		"garbage": false,
		"roster": [{"name": "A"}, {"name": "B"}],
	}))
	check_eq(_client_stub.begins, 1, "valid tower config begins the twin match")
	if _client_stub.begins == 1:
		check_true(_client_stub.coop is CompetitiveGameScript, "tower twin built")
		check_false(_client_stub.coop.garbage_enabled, "tower twin never carries garbage")
	_client_svc.leave_session()


func test_client_loses_host_mid_match() -> void:
	## Losing the host mid-match surfaces an actionable error and tears the
	## session down (no host migration).
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_client_svc.ensure_ready(), "client READY")
	check_true(_host_svc.create_lobby(), "room created")
	var code: String = _host_svc.session_code()
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")

	_client_svc.set_ready(true)
	check_true(_pump_until(_client_ready), "client ready")
	check_true(_host_svc.start_round(), "round started")
	check_true(_pump_until(func() -> bool: return _in_match(_client_svc)), "client in match")
	check_eq(_client_svc.state, ServiceScript.State.IN_MATCH, "client in match")

	# Host vanishes: close the transport directly (simulate crash/quit).
	_host_svc._relay.close()
	check_true(
		_pump_until(func() -> bool: return _client_stub.errors.size() == 1),
		"client saw the host loss"
	)
	check_eq(_client_stub.errors.size(), 1, "client saw an actionable host-lost error")
	if _client_stub.errors.size() == 1:
		check(String(_client_stub.errors[0]).contains("HOST DISCONNECTED"), "error names the host")
	check_eq(_client_stub.leaves, 1, "client host hook observed the teardown")
	check_eq(_client_svc.state, ServiceScript.State.READY, "client session closed after host loss")


func test_unknown_room_code_is_actionable() -> void:
	_reset_session()

	check_true(_client_svc.ensure_ready(), "client READY")
	_client_svc.join_lobby("ZZZZZZZ")
	check_eq(_client_svc.state, ServiceScript.State.ERROR, "unknown code ends in ERROR")
	check_true(
		String(_client_svc.status_text).contains("Room not found"),
		"unknown code surfaces an actionable status"
	)
	# ERROR is retryable: the same service can still join a real room.
	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_host_svc.create_lobby(), "room created")
	_client_svc.join_lobby(_host_svc.session_code())
	check_eq(_client_svc.state, ServiceScript.State.CONNECTING, "retry from ERROR starts a fresh join")
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined on retry")


func test_room_capacity_is_enforced() -> void:
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_host_svc.create_lobby(), "room created")
	var code: String = _host_svc.session_code()
	for i in 3:
		var svc: Node = _make_client_service("CapClient%d" % i)
		svc.use_memory_relay(_hub)
		check_true(svc.ensure_ready(), "extra client %d READY" % i)
		svc.join_lobby(code)
		var expected: int = 2 + i
		check_eq(svc.state, ServiceScript.State.CONNECTING, "client %d joined the room" % i)
		check_eq(svc.local_peer_id(), expected, "relay peer ids run 2..4")
		var roster_size: int = 2 + i
		check_true(
			_pump_until(func() -> bool: return _host_svc.roster.size() == roster_size),
			"host rostered client %d" % i
		)
	check_eq(_host_svc.roster.size(), 4, "room at capacity (host + 3 clients)")

	# The relay refuses a fifth member; the service surfaces it.
	var overflow: Node = _make_client_service("CapOverflow")
	overflow.use_memory_relay(_hub)
	check_true(overflow.ensure_ready(), "overflow client READY")
	overflow.join_lobby(code)
	check_eq(overflow.state, ServiceScript.State.ERROR, "overflow join rejected")
	check_true(String(overflow.status_text).contains("full"), "actionable full-room status")
	check_eq(_host_svc.roster.size(), 4, "roster never exceeds four players")


func test_sender_identity_comes_from_the_relay() -> void:
	## A rogue connection identifies itself only by joining; the payload
	## carries no identity, so roster identity must come from the relay's
	## stamped sender id. A forged sender header inside the payload merely
	## corrupts the envelope and is ignored.
	_reset_session()

	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_host_svc.create_lobby(), "room created")
	var code: String = _host_svc.session_code()

	var rogue: RelayMemoryConnection = RelayMemoryConnection.new(_hub)
	check_true(rogue.join_room("memory://local", code), "rogue joined the room")
	check_eq(rogue.peer_id, 2, "relay assigned the rogue peer 2")
	rogue.send(NetScript.encode(NetScript.MSG_CLIENT_HELLO, 1, {"name": "Rogue"}))
	check_true(_pump_until(func() -> bool: return _host_svc.roster.size() == 2), "host rosters the rogue")
	if _host_svc.roster.size() == 2:
		check_eq(int(_host_svc.roster[1]["peer_id"]), 2, "roster id is the relay stamp, not payload content")

	# Forged sender bytes (a fake "peer 1" header) survive only as
	# payload garbage: the envelope no longer decodes, so the host
	# ignores the frame entirely.
	rogue.send(PackedByteArray([1, 0, 0, 0]) + NetScript.encode(NetScript.MSG_CLIENT_HELLO, 1, {"name": "Ghost"}))
	_pump(10)
	check_eq(_host_svc.roster.size(), 2, "forged-header frame ignored")
	check_eq(String(_host_svc.roster[1]["name"]), "Rogue", "roster untouched by the forged frame")
	rogue.close()


## Runs a joined, started two-player match: ready the client, start the
## round, pump the client twin alive, and let the initial snapshot land.
func _begin_two_player_match() -> bool:
	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_client_svc.ensure_ready(), "client READY")
	check_true(_host_svc.create_lobby(), "room created")
	_client_svc.join_lobby(_host_svc.session_code())
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")
	_client_svc.set_ready(true)
	check_true(_pump_until(_client_ready), "client ready")
	check_true(_host_svc.start_round(), "round started")
	check_true(
		_pump_until(func() -> bool: return _in_match(_client_svc) and _client_stub.begins == 1),
		"client began the twin match"
	)
	_host_svc.host_match_frame(0.0, true)
	return _pump_until(func() -> bool: return _client_stub.snapshots_applied >= 1)


func test_display_name_refreshes_after_ready() -> void:
	## Profile renames after ensure_ready never leak the stale cached name:
	## room creation and the client hello re-read the active profile, and
	## the wire names are protocol-safe (one line, no controls, bounded).
	_reset_session()

	_host_stub.profile_name_value = "First Host"
	_client_stub.profile_name_value = "First Client"
	check_true(_host_svc.ensure_ready(), "host READY")
	check_true(_client_svc.ensure_ready(), "client READY")
	# The active profiles change between READY and the room flow.
	_host_stub.profile_name_value = "Renamed Host"
	_client_stub.profile_name_value = "Second\n  Client"
	check_true(_host_svc.create_lobby(), "room created")
	check_eq(String(_host_svc.roster[0]["name"]), "Renamed Host", "room creation used the fresh host name")
	var code: String = _host_svc.session_code()
	_client_svc.join_lobby(code)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")
	check_eq(_client_svc.display_name, "Second Client", "hello sent the fresh normalized name")
	check_eq(_client_svc.roster.size(), 2, "client sees the roster")
	# The host rosters the sanitized hello name: controls collapsed, one line.
	check_eq(String(_host_svc.roster[1]["name"]), "Second Client", "host rosters the sanitized name")
	# A rogue hello with hostile text never rosters a hostile name.
	var rogue: RelayMemoryConnection = RelayMemoryConnection.new(_hub)
	check_true(rogue.join_room("memory://local", code), "rogue joined")
	rogue.send(NetScript.encode(NetScript.MSG_CLIENT_HELLO, 1, {"name": "  Bad\u0007\nGuy  With\tTab  "}))
	check_true(_pump_until(func() -> bool: return _host_svc.roster.size() == 3), "host rosters the rogue")
	if _host_svc.roster.size() == 3:
		check_eq(String(_host_svc.roster[2]["name"]), "Bad Guy With Tab", "rogue name sanitized for the roster")
	rogue.close()


func test_host_pause_replicates_and_gates_intents() -> void:
	## Host pause is authoritative and global: the envelope applies on the
	## client by revision, client-side pause attempts are inert, intents
	## are rejected while paused without poisoning sequence state, and the
	## resume restores control.
	_reset_session()
	check_true(_begin_two_player_match(), "two-player match running")

	# A client can never broadcast pause: the API refuses non-hosts.
	_client_svc.broadcast_pause_state(true, 99)
	_pump(5)
	check_eq(_client_stub.pause_states.size(), 0, "client pause attempt never left the client")

	# Host pause: envelope + structural snapshot, applied by revision.
	_host_stub.paused = true
	_host_svc.broadcast_pause_state(true, 1)
	_host_svc.send_snapshot(true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.pause_states.size() == 1),
		"client applied the host pause"
	)
	if _client_stub.pause_states.size() == 1:
		check_eq(_client_stub.pause_states[0], [true, 1], "pause applied with its revision")

	# Duplicate pause frames are idempotent (the structural snapshot carries
	# the same revision: nothing re-applies).
	_host_svc.broadcast_pause_state(true, 1)
	_pump(5)
	check_eq(_client_stub.pause_states.size(), 1, "duplicate pause frame ignored")

	# Intents while paused: rejected by the phase gate, sequence untouched.
	var intents_before: int = _host_stub.intents.size()
	_client_svc.submit_intent(1, "move", -1)
	_pump(10)
	check_eq(_host_stub.intents.size(), intents_before, "intent rejected while the host is paused")
	check_eq(_host_svc._intent_guards[2].last_seq, -1, "rejected intents never poison the sequence state")

	# Host resume: control recovers and the next intent applies.
	_host_stub.paused = false
	_host_svc.broadcast_pause_state(false, 2)
	_host_svc.send_snapshot(true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.pause_states.size() == 2),
		"client applied the host resume"
	)
	if _client_stub.pause_states.size() == 2:
		check_eq(_client_stub.pause_states[1], [false, 2], "resume applied with its revision")
	_client_svc.submit_intent(1, "move", -1)
	check_true(
		_pump_until(func() -> bool: return _host_stub.intents.size() == intents_before + 1),
		"control recovered after the resume"
	)
	if _host_stub.intents.size() == intents_before + 1:
		check_eq(int(_host_stub.intents[0]["slot"]), 1, "recovered intent routed to the owning slot")


func test_stale_pause_snapshot_never_reopens_input() -> void:
	## Pause envelopes and structural snapshots can arrive interleaved:
	## applying them idempotently by revision means an older snapshot
	## never flips a newer pause state.
	_reset_session()
	check_true(_begin_two_player_match(), "two-player match running")

	_host_stub.paused = true
	_host_svc.broadcast_pause_state(true, 5)
	_host_svc.send_snapshot(true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.pause_states.size() == 1),
		"pause applied"
	)
	# A forged envelope with the older (pre-resume) revision arrives late.
	_host_stub.paused = false
	_host_svc.broadcast_pause_state(false, 6)
	_host_svc.send_snapshot(true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.pause_states.size() == 2),
		"resume applied"
	)
	_host_svc.broadcast_pause_state(true, 5)
	_pump(10)
	check_eq(_client_stub.pause_states.size(), 2, "stale pause revision never re-applied")


func test_periodic_snapshots_coalesce_to_newest() -> void:
	## Held delivery batches several periodic snapshots into one client
	## drain: only the newest complete state applies (one apply per client
	## frame), structural frames still apply promptly, and the twin tick
	## converges once delivery resumes.
	_reset_session()
	check_true(_begin_two_player_match(), "two-player match running")

	var applied_before: int = _client_stub.snapshots_applied
	var applied_id_before: int = _client_svc.applied_snapshot_id()
	# Hold delivery, then let the host run and emit periodic frames.
	_hub.hold_delivery = true
	_tick_host(10)
	_pump(5)
	check_eq(_client_stub.snapshots_applied, applied_before, "held frames never applied mid-hold")
	# Release every held frame in order; the drain coalesces to the newest.
	_hub.flush_held_frames()
	check_true(
		_pump_until(func() -> bool: return _client_svc.applied_snapshot_id() > applied_id_before),
		"newest held snapshot applied after the flush"
	)
	# Several periodic snapshots completed inside one drain: exactly one
	# apply per client frame.
	check_eq(_client_stub.snapshots_applied, applied_before + 1, "coalesced to a single newest apply")
	# The twin converged to the host tick.
	check_true(_host_stub.coop != null and _client_stub.coop != null, "cores alive")
	if _host_stub.coop != null and _client_stub.coop != null:
		check_eq(
			int((_client_stub.coop.to_snapshot() as Dictionary).get("tick")),
			int((_host_stub.coop.to_snapshot() as Dictionary).get("tick")),
			"twin tick converged after delivery resumed"
		)
	_hub.hold_delivery = false


func test_structural_snapshots_apply_promptly() -> void:
	## A structural frame completing after a periodic one supersedes the
	## pending periodic state immediately instead of coalescing behind it.
	_reset_session()
	check_true(_begin_two_player_match(), "two-player match running")

	var applied_before: int = _client_stub.snapshots_applied
	_hub.hold_delivery = true
	_tick_host(3)
	# A structural frame rides behind the periodic ones.
	_host_stub.coop.hard_drop(0)
	_host_svc.send_snapshot(true)
	_pump(3)
	_hub.flush_held_frames()
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied > applied_before),
		"held snapshots applied after the flush"
	)
	# The structural (lock-event) state won: exactly one apply for the drain,
	# carrying the lock.
	check_eq(_client_stub.snapshots_applied, applied_before + 1, "one apply covered the whole batch")
	check_true(_host_stub.coop != null and _client_stub.coop != null, "cores alive")
	if _host_stub.coop != null and _client_stub.coop != null:
		check_eq(
			int((_client_stub.coop.to_snapshot() as Dictionary).get("tick")),
			int((_host_stub.coop.to_snapshot() as Dictionary).get("tick")),
			"twin converged to the structural state"
		)
	_hub.hold_delivery = false


func test_stale_and_duplicate_snapshots_dropped() -> void:
	## Old ids cannot overwrite current state: a frame with an already-seen
	## id is dropped at reassembly or on completion, and a regressed tick
	## never regresses the twin.
	_reset_session()
	check_true(_begin_two_player_match(), "two-player match running")
	_tick_host(5)
	check_true(
		_pump_until(func() -> bool: return _client_svc.applied_snapshot_id() >= 2),
		"client applied several snapshots"
	)

	var twin_before: Dictionary = _client_stub.coop.to_snapshot()
	var newest_id: int = _client_svc.applied_snapshot_id()
	var payload := var_to_bytes(twin_before)
	# An id older than everything seen: dropped during reassembly.
	_client_svc._net.receive(1, NetScript.encode(NetScript.MSG_SNAPSHOT, 1, {
		"id": newest_id - 5, "part": 0, "count": 1, "rel": false, "bytes": payload,
	}))
	# An id equal to the newest applied frame: duplicate, dropped complete.
	_client_svc._net.receive(1, NetScript.encode(NetScript.MSG_SNAPSHOT, 1, {
		"id": newest_id, "part": 0, "count": 1, "rel": true, "bytes": payload,
	}))
	# A regressed tick with a fresh id: dropped at delivery.
	var regressed: Dictionary = twin_before.duplicate(true)
	regressed["tick"] = 0
	_client_svc._deliver_snapshot(regressed, newest_id + 50)
	_pump(3)
	check_eq(_client_stub.coop.to_snapshot(), twin_before, "stale and duplicate frames never regress the twin")


func _tick_host(steps: int) -> void:
	## Advance the authoritative sim the way GameHost would.
	if _host_stub == null or _host_stub.coop == null:
		return
	for i in steps:
		_host_stub.coop.tick(PlayConfig.FIXED_STEP)
		_host_svc.host_match_frame(0.05, false)
