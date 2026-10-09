extends "res://tests/test_lib.gd"
## End-to-end online session protocol tests: two OnlineService instances
## (host + client), each with its own custom MultiplayerAPI rooted at its
## node path, talking over the ENet dev harness (debug builds only). This
## exercises the REAL wire protocol - lobby handshake, roster broadcast,
## ready gate, match start, intents, chunked snapshots, results, return to
## lobby, and disconnect teardown - without EOSG or a network.
##
## Frames are pumped manually (poll each MultiplayerAPI + call _process on
## each service) because the test runner executes synchronously.

const CoopGameScript = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const ServiceScript = preload("res://scripts/online/online_service.gd")

const ACTIVE_PHASE = 0


## Minimal GameHost stand-in: implements every OnlineService hook against
## a real CoopGame so snapshot/intent semantics are exercised for real.
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

	func _build(config: Dictionary) -> void:
		config_seen = config
		coop = CoopGameScript.new(
			clampi(int(config.get("player_count", 1)), 1, 4),
			int(config.get("mode", ModeRules.Mode.MARATHON)),
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
		return coop != null and coop.phase == ACTIVE_PHASE

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
var _host_mp: SceneMultiplayer = null
var _client_mp: SceneMultiplayer = null


func setup() -> void:
	if not ServiceScript.dev_transport_allowed():
		push_warning("session tests skipped (release build without the dev harness)")
		return
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

	_host_mp = SceneMultiplayer.new()
	tree.set_multiplayer(_host_mp, NodePath("/root/HostSvc"))
	_client_mp = SceneMultiplayer.new()
	tree.set_multiplayer(_client_mp, NodePath("/root/ClientSvc"))


func teardown() -> void:
	if _host_svc != null and _host_svc.multiplayer.multiplayer_peer != null:
		_host_svc.multiplayer.multiplayer_peer.close()
	if _client_svc != null and _client_svc.multiplayer.multiplayer_peer != null:
		_client_svc.multiplayer.multiplayer_peer.close()
	if _host_svc != null:
		_host_svc.queue_free()
	if _client_svc != null:
		_client_svc.queue_free()
	if _host_stub != null:
		_host_stub.queue_free()
	if _client_stub != null:
		_client_stub.queue_free()


## Manual frame pump: poll each multiplayer domain (drives the ENet peer +
## packet dispatch, firing peer_connected/RPC handlers) and step each
## service (connect timeout bookkeeping). ENet's connect handshake needs
## real wall-clock time between service() calls, so every step burns a few
## real milliseconds; the loop is condition-driven so it settles as soon
## as the protocol advances (default budget ~2s).
func _pump_until(predicate: Callable, max_steps: int = 500) -> bool:
	for i in max_steps:
		if predicate.call():
			return true
		_step_frame()
	return predicate.call()


func _pump(steps: int = 25) -> void:
	for i in steps:
		_step_frame()


func _step_frame() -> void:
	OS.delay_msec(4)
	if _host_mp != null and _host_mp.multiplayer_peer != null:
		_host_mp.poll()
	if _client_mp != null and _client_mp.multiplayer_peer != null:
		_client_mp.poll()
	if _host_svc != null:
		_host_svc._process(0.016)
	if _client_svc != null:
		_client_svc._process(0.016)


func _in_match(service: Node) -> bool:
	return service != null and service.state == ServiceScript.State.IN_MATCH


func _in_lobby(service: Node) -> bool:
	return service != null and service.state == ServiceScript.State.LOBBY


# ---------------------------------------------------------------------- tests

## Reset any session left over from a previous test in this suite (the
## runner shares one setup() across tests).
func _reset_session() -> void:
	if _client_svc != null:
		_client_svc.leave_session()
	if _host_svc != null:
		_host_svc.leave_session()
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


func test_full_session_flow() -> void:
	## One full round: lobby create/join/handshake, ready gate, match start,
	## intents client->host, snapshots host->client, results, lobby return,
	## ready reset, disconnect teardown.
	if not ServiceScript.dev_transport_allowed():
		return
	_reset_session()

	check_true(await _host_svc.ensure_ready(), "host reaches READY in dev mode")
	check_true(await _client_svc.ensure_ready(), "client reaches READY in dev mode")

	# --- lobby create (host installs the dev transport) ---
	var lobby_ok: bool = await _host_svc.create_lobby()
	check_true(lobby_ok, "dev lobby created")
	check_eq(_host_svc.state, ServiceScript.State.LOBBY, "host in LOBBY")
	check_true(_host_svc.is_host, "host role set")
	check_eq(_host_svc.roster.size(), 1, "host rostered alone")
	check_eq(_host_svc.own_slot, 0, "host owns slot 0")
	var address: String = _host_svc.session_code()
	check_false(address.is_empty(), "dev lobby address exposed for joining")

	# --- join (client transport + handshake + roster broadcast) ---
	await _client_svc.join_lobby(address)
	check_eq(_client_svc.state, ServiceScript.State.CONNECTING, "client CONNECTING after join")
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client reaches LOBBY after handshake")
	if not _in_lobby(_client_svc):
		return
	check_eq(_client_svc.own_slot, 1, "client assigned slot 1")
	check_eq(_client_svc.roster.size(), 2, "client sees full roster")
	check_true(_pump_until(func() -> bool: return _host_svc.roster.size() == 2), "host roster includes client")
	check_eq(_host_svc.roster.size(), 2, "host roster includes client")

	# --- ready gate: start is blocked until the client is ready ---
	check_false(_host_svc.start_round(), "start blocked before client ready")
	_client_svc.set_ready(true)
	check_true(
		_pump_until(func() -> bool:
			return _host_svc.roster.size() == 2 and bool(_host_svc.roster[1]["ready"])),
		"host sees client ready"
	)
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
	# GameHost sends the authoritative initial state reliably at match start.
	_host_svc.host_match_frame(0.0, true)
	check_true(
		_pump_until(func() -> bool: return _client_stub.snapshots_applied >= 1),
		"initial reliable snapshot arrived"
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
	_pump(20)
	check_eq(_host_stub.intents.size(), 1, "client cannot act on foreign slots")

	# --- snapshots: structural reliable snapshot converges the twin ---
	_tick_host(30)
	_host_svc.host_match_frame(0.0, true)  # structural -> reliable
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

	# --- results: host broadcasts, both keep the lobby (EOS persists) ---
	_host_svc.host_round_finished({"title": "GAME OVER", "subtitle": "test round"})
	check_eq(_host_svc.state, ServiceScript.State.LOBBY, "host returns to LOBBY after the round")
	check_false(bool(_host_svc.roster[1]["ready"]), "ready flags reset after the round")
	check_true(
		_pump_until(func() -> bool: return _client_stub.results.size() == 1),
		"client received the result"
	)
	check_eq(_client_stub.results.size(), 1, "client received the result")
	if _client_stub.results.size() == 1:
		check_eq(String(_client_stub.results[0]["title"]), "GAME OVER", "result title preserved")

	# --- return to lobby: host command, broadcast, both teardown the run ---
	_host_svc.host_return_to_lobby()
	check_true(
		_pump_until(func() -> bool: return _client_stub.lobby_returns == 1),
		"client returned to the lobby with the host"
	)
	check_eq(_client_stub.lobby_returns, 1, "client returned to the lobby with the host")
	check_eq(_client_svc.lobby_phase, "lobby", "client lobby phase reset")

	# --- ready gate again for the next round ---
	_client_svc.set_ready(true)
	check_true(
		_pump_until(func() -> bool:
			return _host_svc.roster.size() == 2 and bool(_host_svc.roster[1]["ready"])),
		"ready toggles again in the persistent lobby"
	)
	check_true(_host_svc.start_round(), "second round starts from the same lobby")
	check_eq(_host_stub.begins, 2, "second round begins on the host")
	check_true(_pump_until(func() -> bool:
		return _in_match(_client_svc) and _client_stub.begins == 2), "second round begins on the client")
	check_eq(_client_stub.begins, 2, "second round begins on the client")

	# --- client leave: host roster shrinks, match continues ---
	_client_svc.leave_session()
	check_true(
		_pump_until(func() -> bool: return _host_svc.roster.size() == 1),
		"host roster shrinks after client leave"
	)
	check_eq(_client_svc.state, ServiceScript.State.OFFLINE, "client back OFFLINE after leave")
	check_eq(_client_stub.leaves, 1, "client host hook observed the leave")


func test_client_loses_host_mid_match() -> void:
	## Losing the host mid-match surfaces an actionable error and tears the
	## session down (no host migration).
	if not ServiceScript.dev_transport_allowed():
		return
	_reset_session()

	check_true(await _host_svc.ensure_ready(), "host READY")
	check_true(await _client_svc.ensure_ready(), "client READY")
	var lobby_ok: bool = await _host_svc.create_lobby()
	check_true(lobby_ok, "lobby created")
	var address: String = _host_svc.session_code()
	await _client_svc.join_lobby(address)
	check_true(_pump_until(func() -> bool: return _in_lobby(_client_svc)), "client joined")

	_client_svc.set_ready(true)
	check_true(
		_pump_until(func() -> bool:
			return _host_svc.roster.size() == 2 and bool(_host_svc.roster[1]["ready"])),
		"client ready"
	)
	check_true(_host_svc.start_round(), "round started")
	check_true(_pump_until(func() -> bool: return _in_match(_client_svc)), "client in match")
	check_eq(_client_svc.state, ServiceScript.State.IN_MATCH, "client in match")

	# Host vanishes: close the transport directly (simulate crash/quit).
	_host_svc.multiplayer.multiplayer_peer.close()
	_host_svc.multiplayer.multiplayer_peer = null
	check_true(
		_pump_until(func() -> bool: return _client_stub.errors.size() == 1),
		"client saw the host loss"
	)
	check_eq(_client_stub.errors.size(), 1, "client saw an actionable host-lost error")
	if _client_stub.errors.size() == 1:
		check(String(_client_stub.errors[0]).contains("HOST DISCONNECTED"), "error names the host")
	check_eq(_client_stub.leaves, 1, "client host hook observed the teardown")
	check_eq(_client_svc.state, ServiceScript.State.OFFLINE, "client session closed after host loss")


func _tick_host(steps: int) -> void:
	## Advance the authoritative sim the way GameHost would.
	if _host_stub == null or _host_stub.coop == null:
		return
	for i in steps:
		_host_stub.coop.tick(PlayConfig.FIXED_STEP)
		_host_svc.host_match_frame(0.05, false)