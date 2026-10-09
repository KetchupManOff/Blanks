extends Node
## RPC I/O layer for the online session.
##
## One instance per network domain, added as the child named "Net" of the
## OnlineService node. In production that is the /root/OnlineService
## autoload (so the RPC node path resolves identically on every peer); in
## tests two service instances live under different SceneTree nodes, each
## with its own custom MultiplayerAPI, and the identical child path keeps
## RPC routing symmetric.
##
## This layer is deliberately dumb: it forwards raw calls with sender ids
## to the service and exposes send helpers. Every host-side handler
## re-validates the sender; nothing here trusts the payload.

var service: Node = null


func setup(owner_service: Node) -> void:
	service = owner_service


func _sender() -> int:
	## Peer id of the remote peer that caused the currently executing RPC.
	return multiplayer.get_remote_sender_id()


# ----------------------------------------------------------------- receive
# Host -> client: authority RPCs (only the host, multiplayer authority 1,
# may trigger them; SceneMultiplayer enforces that plus the explicit
# sender check in the service).

@rpc("authority", "reliable")
func rpc_lobby_state(state: Dictionary) -> void:
	if service != null:
		service._net_lobby_state(_sender(), state)


@rpc("authority", "reliable")
func rpc_match_started(config: Dictionary) -> void:
	if service != null:
		service._net_match_started(_sender(), config)


@rpc("authority", "reliable")
func rpc_round_finished(result: Dictionary) -> void:
	if service != null:
		service._net_round_finished(_sender(), result)


@rpc("authority", "reliable")
func rpc_return_to_lobby() -> void:
	if service != null:
		service._net_return_to_lobby(_sender())


# Client -> host: any-peer RPCs; the host validates slot ownership,
# sequence freshness, and rate before applying anything.

@rpc("any_peer", "reliable")
func rpc_client_hello(protocol: int, display_name: String) -> void:
	if service != null:
		service._net_client_hello(_sender(), protocol, display_name)


@rpc("any_peer", "reliable")
func rpc_set_ready(ready: bool) -> void:
	if service != null:
		service._net_set_ready(_sender(), ready)


@rpc("any_peer", "reliable")
func rpc_submit_intent(slot: int, seq: int, action: String, arg: int) -> void:
	if service != null:
		service._net_submit_intent(_sender(), slot, seq, action, arg)


# Host -> clients: state snapshots, split into transport-safe chunks.
# Periodic frames ride the unreliable variant (loss = skip a frame);
# structural frames (start/lock/phase transitions) ride the reliable one.

@rpc("authority", "unreliable")
func rpc_snapshot_u(snap_id: int, part: int, count: int, bytes: PackedByteArray) -> void:
	if service != null:
		service._net_snapshot(_sender(), snap_id, part, count, bytes)


@rpc("authority", "reliable")
func rpc_snapshot_r(snap_id: int, part: int, count: int, bytes: PackedByteArray) -> void:
	if service != null:
		service._net_snapshot(_sender(), snap_id, part, count, bytes)


# -------------------------------------------------------------------- send

func send_client_hello(protocol: int, display_name: String) -> void:
	## Client -> host (peer 1): announce protocol + name.
	rpc_id(1, "rpc_client_hello", protocol, display_name)


func send_set_ready(ready: bool) -> void:
	rpc_id(1, "rpc_set_ready", ready)


func send_intent(slot: int, seq: int, action: String, arg: int) -> void:
	rpc_id(1, "rpc_submit_intent", slot, seq, action, arg)


func send_lobby_state(state: Dictionary) -> void:
	rpc("rpc_lobby_state", state)


func send_match_started(config: Dictionary) -> void:
	rpc("rpc_match_started", config)


func send_round_finished(result: Dictionary) -> void:
	rpc("rpc_round_finished", result)


func send_return_to_lobby() -> void:
	rpc("rpc_return_to_lobby")


func send_snapshot(method: String, snap_id: int, chunks: Array) -> void:
	## Host -> all peers: one RPC per chunk, identical call signature.
	for i in chunks.size():
		rpc(method, snap_id, i, chunks.size(), chunks[i])