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

Authoritative model: only the host ticks the match core (`CoopGame` for
shared-board co-op, `CompetitiveGame` for Classic Versus and Tower) and
broadcasts snapshot chunks; clients render the latest snapshot and submit
bounded input intents, which the host validates (relay sender identity,
slot ownership, ACTIVE phase, monotonic sequence, token bucket) before
applying. Pause is host-authoritative and global: the host's pause key
toggles the match for everyone (a pause envelope plus a structural
snapshot carrying the same revision), clients see a passive overlay and
their own pause keys are ignored, and intents sent while paused are
rejected without poisoning the client's sequence state. Snapshot streams
are latest-only: clients coalesce periodic snapshots to the newest
complete state (one apply per client frame), apply structural frames
promptly, and drop stale, duplicate, or regressed frames so world state
never moves backwards; board renderers interpolate only the active-piece
position and flash clock between authoritative samples. The relay
forwards frames only - host to all clients, clients to host - and stamps
sender identity itself, so a payload can never claim a sender. Display
names are refreshed from the active profile at room creation and the
client hello and normalized to protocol-safe one-line strings. Rooms
persist between rounds: the round ends, everyone returns to the lobby
(host command), ready flags reset, and the host can change mode and start
the next round. Losing the host ends the session (no host migration); a
client leaving just frees its slot.

Competitive lobby flow stays relay-agnostic: the lobby mode cycles
through Marathon, 40-Line Sprint, Classic Versus, and Tower; the
Classic Versus garbage setting (`GARBAGE: ON/OFF`) is a host decision
carried in the lobby state and the match configuration, and Classic
Versus may also be played with garbage off as an independent-survival
variant. Tower never runs with garbage. Competitive matches require
2-4 rostered peers (the start is refused otherwise), and clients
validate the competitive configuration - mode, roster size, garbage
flag - before building a match, so malformed or stale configurations
fail into the session error path. Tower board growth travels inside
every snapshot (per-player board geometry), so clients rebuild their
presenters safely when heights change mid-match.

## Player flow (no player-side setup)

1. `ONLINE -> CREATE ROOM` - the host receives a room code
   (shown prominently in the lobby, e.g. `K7QPZM2`).
2. Share the code with friends.
3. They run `ONLINE -> JOIN ROOM`, type the code, press Enter.
4. Clients toggle READY; the host picks the mode (and, for Classic
   Versus, the garbage setting) and starts the round.

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
- **Development/staging**: launch with `BLANKS_RELAY_URL` set, e.g.
  `BLANKS_RELAY_URL=ws://127.0.0.1:8080` against a locally running relay
  (`cd relay && npm install && npm start`). Plain `ws://` is accepted
  only in debug/editor builds; unset or invalid endpoints leave online
  unavailable with an actionable status line.

No credentials exist anywhere client-side; there is nothing to
configure for players.

### Shareable Windows dev package (friend test over `ws://`)

To let a friend play online without installing Godot or setting
environment variables, build them a debug package:

```
export_online_dev.bat
```

- The script prompts for the relay URL (`ws://host:port`) and
  produces a timestamped
  `Exports/BLANKS_OnlineDev_<timestamp>.zip`. The endpoint
  is written only into the generated `Start Online Dev.bat` inside
  the package - never into tracked project files.
- Recipients extract the zip anywhere and run **Start Online Dev.bat**
  rather than the `.exe` directly: the launcher sets `BLANKS_RELAY_URL`
  for the game process, and without it the game reports online as
  unavailable.
- The package is a **debug export**: it is unsigned, so Windows
  SmartScreen may require an explicit "run anyway" approval, and its
  relay traffic is unencrypted. Treat it as a short-lived
  trusted-friends test build - unsuitable for public distribution.
- For a public release, keep the production path: terminate TLS in
  front of the relay, set `[online] relay_url` to the `wss://` URL,
  and export a normal release build (`export_game.bat`), which never
  includes a launcher or a `ws://` endpoint.

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
    create room, join by code, ready gate, every lobby mode (including a
    Classic Versus round with garbage on and off and a Tower round), a full
    round plus a repeat round from the persistent lobby, leave from the
    lobby, leave mid-match, host quit mid-match (clients must see the
    disconnect error), malformed/expired/full code handling, and two
    unrelated rooms coexisting. Pause/replication/input QA inside a full
    round: the host's pause pauses everyone (passive overlay plus paused
    music on clients), client pause keys stay inert, intents sent while
    paused are dropped (movement resumes cleanly after the host resumes),
    remote pieces move smoothly (interpolated catch-up), and each player's
    own keyboard/controller profile drives only their own slot - including
    two players with per-profile keys on the same keyboard.
4. For a temporary friend test over a plain `ws://` relay, repeat the
   manual pass with two dev packages built by `export_online_dev.bat`
   and started through their `Start Online Dev.bat` launchers; only
   the build kind and endpoint differ from step 3 - the relay URL
   still lives solely in each generated launcher.
5. Verify packaged exports contain no EOSG libraries, EOS SDK files,
   credentials, or EOS setup text, and that the game rejects non-TLS
   relay URLs in release builds.
