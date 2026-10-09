# ONLINE_SETUP.md - Relay-Backed Online Co-op

This project ships host-authoritative online co-op over a
**self-hosted WebSocket relay** (`relay/`). Players need **no
account, no launcher, no credentials file, no IP address, and no router
configuration**: the host creates a room, shares the room code, and
everyone else joins with it.

Everything online lives behind the `OnlineService` autoload
(`scripts/online/online_service.gd`); gameplay code (GameHost,
InputController, UI) never touches transport internals.

## Architecture

```
relay/                              Node.js relay service (forwarding only):
                                    private rooms, relay-stamped sender ids
scripts/online/online_service.gd   autoload: state machine, rooms, match
scripts/online/relay_connection.gd  transport contract (connect/create/
                                    join/send/poll/close + lifecycle signals)
scripts/online/relay_connection_websocket.gd  production WebSocketPeer transport
scripts/online/relay_connection_memory.gd    in-memory transport (tests only)
scripts/online/relay_memory.gd     in-memory relay hub mirroring relay/
scripts/online/online_net.gd      envelope codec + dispatcher
scripts/online/input_intent.gd    intent DTO + host-side validation
                                    (ownership, phase, sequence, rate)
```

Authoritative model: only the host ticks `CoopGame` and broadcasts
snapshot chunks; clients render the latest snapshot and submit bounded
input intents, which the host validates (relay sender identity, slot
ownership, ACTIVE phase, monotonic sequence, token bucket) before
applying. The relay forwards frames only - host to all clients,
clients to host - and stamps sender identity itself, so a payload can
never claim a sender. Rooms persist between rounds: the round ends,
everyone returns to the lobby (host command), ready flags reset, and
the host can change mode and start the next round. Losing the host
ends the session (no host migration); a client leaving just frees its
slot.

## Player flow (no player-side setup)

1. `ONLINE CO-OP -> CREATE ROOM` - the host receives a room code
   (shown prominently in the lobby, e.g. `K7QPZM2`).
2. Share the code with friends.
3. They run `ONLINE CO-OP -> JOIN ROOM`, type the code, press Enter.
4. Clients toggle READY; the host picks the mode and starts the round.

Status text covers the failure cases explicitly: unreachable relay,
room not found (expired or closed), full room, invalid code, and
host-disconnected mid-match.

## Operator guide (deploying the relay)

Requirements: one host with Docker (or Node 20+), a domain, and ports
80/443 open. Players connect outbound only.

```sh
cd relay
cp .env.example .env       # optional: tune limits/ports (no secrets exist)
docker compose up -d --build
curl http://127.0.0.1:8080/healthz   # -> ok
```

Terminate TLS in front so players connect via `wss://` (the game
refuses plain `ws://` in release builds):

- **Caddy** (recommended - automatic Let's Encrypt certificates):
  edit `relay/Caddyfile.example` (set your relay domain) and run
  `docker compose --profile tls up -d --build`. Ports/domain: 443 for
  players, 80 for the ACME challenge.
- **nginx**: see the example site block in `relay/README.md` (WebSocket
  upgrade headers + long read/send timeouts), certificate via
  certbot or your CA.

Operational notes:

- Health check `GET /healthz` on the relay port (the Dockerfile ships a
  HEALTHCHECK).
- Rooms are unlisted and high-entropy; the relay caps room size
  (default 4 peers), frame size, per-socket rate, connections per IP,
  and expires idle rooms. These are abuse limits, not a security
  boundary against someone who *has* a room code.
- The relay logs aggregate operational errors only - never room
  payloads or player data.
- The relay is a single availability dependency: if it is down, online
  shows an unreachable status; offline play is unaffected.

## Configuring the game's relay URL

The endpoint is one non-secret product setting, with an environment
override for development and staging:

- **Release**: set `[online] relay_url` in `project.godot` to your
  deployed `wss://` URL before exporting (a release build refuses a
  plain `ws://` endpoint).
- **Development/staging**: launch with `TYE_RELAY_URL` set, e.g.
  `TYE_RELAY_URL=ws://127.0.0.1:8080` against a locally running relay
  (`cd relay && npm install && npm start`). Plain `ws://` is accepted
  only in debug/editor builds; unset or invalid endpoints leave online
  unavailable with an actionable status line.

No credentials exist anywhere client-side; there is nothing to
configure for players.

## Validation checklist

Run through this order after any online change:

1. `godot --headless --script tests/run_tests.gd` - offline/online unit
   and protocol suites. The online session suite runs the full
   host<->client flow (hello handshake, ready gate, intents, chunked
   snapshots, results, disconnect teardown) through an in-memory relay
   hub - no editor, no network (see AGENTS.md).
2. `cd relay && npm test` - relay behavior suite (room lifecycle,
   forwarding direction, spoofing resistance, limits, cleanup) on an
   ephemeral local port.
3. Manual, two release exports against the deployed `wss://` relay:
   create room, join by code, ready gate, both playable modes, a full
   round plus a repeat round from the persistent lobby, leave from the
   lobby, leave mid-match, host quit mid-match (clients must see the
   disconnect error), malformed/expired/full code handling, and two
   unrelated rooms coexisting.
4. Verify packaged exports contain no EOSG libraries, EOS SDK files,
   credentials, or EOS setup text, and that the game rejects non-TLS
   relay URLs in release builds.
