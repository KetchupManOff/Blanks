extends Node
## Relay envelope codec and dispatcher for the online session.
##
## One instance per service, added as the child named "Net" of the
## OnlineService node. Game traffic over the relay uses a single
## versioned envelope shape:
##   {"t": <message type>, "v": <protocol version>, "d": <payload>}
## serialized with var_to_bytes. Payloads are primitives, arrays,
## dictionaries, and PackedByteArray only - bytes_to_var never decodes
## objects, so a hostile frame cannot smuggle one in. Outbound envelopes
## are size-bounded before sending; inbound envelopes are shape, size,
## and version checked before dispatch.
##
## This layer stays deliberately dumb: the sender id comes from the
## relay-stamped transport header (never the payload), and every _net_*
## handler in OnlineService re-validates sender, role, and state before
## touching anything. Nothing here trusts envelope content.


const MAX_ENVELOPE_BYTES: int = 16384

const MSG_CLIENT_HELLO: String = "client_hello"
const MSG_SET_READY: String = "set_ready"
const MSG_INTENT: String = "intent"
const MSG_LOBBY_STATE: String = "lobby_state"
const MSG_MATCH_STARTED: String = "match_started"
const MSG_ROUND_FINISHED: String = "round_finished"
const MSG_RETURN_TO_LOBBY: String = "return_to_lobby"
const MSG_SNAPSHOT: String = "snapshot"

var service: Node = null


func setup(owner_service: Node) -> void:
	service = owner_service


## Encode one outbound envelope.
static func encode(msg_type: String, version: int, data: Variant) -> PackedByteArray:
	return var_to_bytes({"t": msg_type, "v": version, "d": data})


## Decode + validate one inbound envelope. Returns {} for anything
## malformed, oversized, or carrying an unexpected shape; callers treat
## an empty dictionary as "ignore the frame".
static func decode(payload: PackedByteArray) -> Dictionary:
	# Below 4 bytes there is not even a variant type tag to decode.
	if payload.size() < 4 or payload.size() > MAX_ENVELOPE_BYTES:
		return {}
	var obj = bytes_to_var(payload)  # objects are never decoded
	if obj is not Dictionary:
		return {}
	var version = obj.get("v")
	var msg_type = obj.get("t")
	if typeof(version) != TYPE_INT or int(version) <= 0:
		return {}
	if typeof(msg_type) != TYPE_STRING or String(msg_type).is_empty():
		return {}
	if not obj.has("d"):
		return {}
	return obj


## Dispatch one relay-forwarded envelope to the owning service.
## `sender` is the relay-stamped peer id supplied by the transport,
## never a value taken from the payload.
func receive(sender: int, payload: PackedByteArray) -> void:
	if service == null:
		return
	var envelope := decode(payload)
	if envelope.is_empty():
		return  # malformed/oversized envelope: silently ignore
	if int(envelope["v"]) != service.PROTOCOL_VERSION:
		return  # wrong protocol version: reject before any handler runs
	var data = envelope["d"]
	match String(envelope["t"]):
		MSG_CLIENT_HELLO:
			service._net_client_hello(sender, data)
		MSG_SET_READY:
			service._net_set_ready(sender, data)
		MSG_INTENT:
			service._net_submit_intent(sender, data)
		MSG_LOBBY_STATE:
			service._net_lobby_state(sender, data)
		MSG_MATCH_STARTED:
			service._net_match_started(sender, data)
		MSG_ROUND_FINISHED:
			service._net_round_finished(sender, data)
		MSG_RETURN_TO_LOBBY:
			service._net_return_to_lobby(sender)
		MSG_SNAPSHOT:
			service._net_snapshot(sender, data)
		_:
			push_warning("online: ignoring unknown message type '%s'" % envelope["t"])
