extends RefCounted
## Online input intents and their host-side validation.
##
## Clients never mutate CoopGame. Each client polls only its own assigned
## slot and converts local edges into bounded intent records (a small DTO:
## slot, monotonic sequence number, action name, argument). The intent
## travels to the host over a reliable RPC; the host validates sender
## identity, slot ownership, sequence freshness, action shape, and rate
## before executing it against its own authoritative CoopGame.
##
## Everything here is pure data + logic with no network or scene-tree
## dependencies so the abuse limits are unit-testable headlessly.

const MAX_SLOT: int = 3
const MAX_SEQ_GAP: int = 32  # forward jumps beyond this are rejected as abuse


enum Verdict {
	OK,
	NOT_ROSTERED,  # sender has not completed the lobby handshake
	WRONG_SLOT,  # sender does not own the claimed slot
	STALE_SEQ,  # replayed or reordered intent
	GAP_SEQ,  # sequence jumped suspiciously far forward
	RATE,  # token bucket exhausted
	BAD_ACTION,  # unknown action or invalid argument
	BAD_PHASE,  # intent arrived outside the ACTIVE match phase
}


## Actions a client may request for its own slot, with argument ranges.
## Movement actions take a direction, soft drop takes a pressed state,
## the rest are edge-only.
const ACTIONS := {
	"move": {"arg": "dir", "min": -1, "max": 1},
	"rotate": {"arg": "dir", "min": -1, "max": 1},
	"soft_drop": {"arg": "state", "min": 0, "max": 1},
	"hard_drop": {"arg": "none", "min": 0, "max": 0},
	"hold": {"arg": "none", "min": 0, "max": 0},
}


## Per-peer validator state: last accepted sequence number plus a simple
## token bucket (tokens refill per second up to burst; each intent costs
## one token). The defaults allow sustained DAS/ARR movement plus edge
## bursts with generous headroom while bounding floods.
class IntentGuard:
	var last_seq: int = -1
	var tokens: float = 0.0
	var last_frame: int = -1
	var refill_per_second: float = 120.0
	var burst: float = 160.0


static func make_guard(refill_per_second: float = 120.0, burst: float = 160.0) -> IntentGuard:
	var guard := IntentGuard.new()
	guard.refill_per_second = refill_per_second
	guard.burst = burst
	guard.tokens = burst
	return guard


## Refill a guard's token bucket from the current tick time (msec from
## Time.get_ticks_msec) - one call per received intent is enough.
static func tick_guard(guard: IntentGuard, now_msec: int) -> void:
	if guard.last_frame < 0:
		guard.last_frame = now_msec
		return
	var elapsed_ms: int = now_msec - guard.last_frame
	if elapsed_ms <= 0:
		return
	guard.tokens = minf(guard.burst, guard.tokens + guard.refill_per_second * float(elapsed_ms) / 1000.0)
	guard.last_frame = now_msec


## Validate one inbound intent against a sender's guard.
## `slot_of_peer` maps the sender's relay peer id to its assigned
## player slot (-1 when the sender owns no slot). `phase_active` gates the
## whole path: no intents apply outside the ACTIVE phase.
static func validate(
	guard: IntentGuard,
	sender_peer: int,
	slot_of_peer: Dictionary,
	slot: int,
	seq: int,
	action: String,
	arg: int,
	phase_active: bool,
	now_msec: int
) -> int:
	if sender_peer <= 0:
		return Verdict.NOT_ROSTERED
	if slot_of_peer.get(sender_peer, -1) != slot:
		return Verdict.WRONG_SLOT
	if not phase_active:
		return Verdict.BAD_PHASE
	if seq <= guard.last_seq:
		return Verdict.STALE_SEQ
	if seq > guard.last_seq + MAX_SEQ_GAP:
		return Verdict.GAP_SEQ
	if not ACTIONS.has(action):
		return Verdict.BAD_ACTION
	var spec: Dictionary = ACTIONS[action]
	if spec["arg"] == "none":
		if arg != 0:
			return Verdict.BAD_ACTION
	else:
		if arg < int(spec["min"]) or arg > int(spec["max"]):
			return Verdict.BAD_ACTION
	tick_guard(guard, now_msec)
	if guard.tokens < 1.0:
		return Verdict.RATE
	guard.tokens -= 1.0
	guard.last_seq = seq
	return Verdict.OK


## Human-readable log/context line for a rejected intent.
static func verdict_text(verdict: int) -> String:
	match verdict:
		Verdict.NOT_ROSTERED: return "sender not rostered"
		Verdict.WRONG_SLOT: return "sender does not own this slot"
		Verdict.STALE_SEQ: return "stale/replayed sequence"
		Verdict.GAP_SEQ: return "sequence gap too large"
		Verdict.RATE: return "intent rate exceeded"
		Verdict.BAD_ACTION: return "unknown action/argument"
		Verdict.BAD_PHASE: return "not in ACTIVE phase"
		_: return "unknown verdict"