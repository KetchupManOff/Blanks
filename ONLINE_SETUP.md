# ONLINE_SETUP.md - EOS P2P Online Co-op Setup

This project ships host-authoritative online co-op over **Epic Online
Services P2P**. Everything EOS lives behind the `OnlineService` autoload
(`scripts/online/online_service.gd`); gameplay code (GameHost, InputController,
UI) never touches EOS or transport internals.

## Architecture

```
scripts/online/online_service.gd   autoload: state machine, lobby, match session
scripts/online/online_net.gd      RPC I/O node (lobby_state, match_started,
                                  intents, chunked snapshots, results)
scripts/online/eosg_bridge.gd    EOSG addon bridge (loaded ONLY when the
                                  addon is installed): platform/auth/lobby/P2P
                                  + transport creation + IEOS ticking
scripts/online/online_credentials.gd  credential loading (never logs secrets)
scripts/online/input_intent.gd   intent DTO + host-side validation
                                  (ownership, phase, sequence, rate)
scripts/online/network_p2p_proof.gd + scenes/network_p2p_proof.tscn
                                  debug-only native replication proof
                                  (MultiplayerSpawner + MultiplayerSynchronizer)
addons/eos-transport/             custom EOS-backed MultiplayerPeer source
                                  (drop-in module; see its README)
```

Authoritative model: only the host ticks `CoopGame` and broadcasts
snapshots (`CoopGame.to_snapshot()` / `apply_snapshot()`); clients render
the latest snapshot and submit bounded input intents, which the host
validates (sender/slot ownership, ACTIVE phase, monotonic sequence, token
bucket) before applying. EOS lobbies persist across rounds: the round
ends, everyone returns to the lobby (host command), ready flags reset,
and the host can change mode and start the next round.

## Transport

`OnlineService` picks, in order:

1. `EOSMultiplayerPeer` - this project's custom EOS-backed MultiplayerPeer
   (host-assigned ids 2..4, membership-gated accept, internal
   fragmentation) - **only if the class is registered** (built into the
   EOSG addon's binary; see `addons/eos-transport/README.md`);
2. `EOSGMultiplayerPeer` - the EOSG addon's built-in EOS-backed
   MultiplayerPeer (default EOS path, works out of the box once EOSG is
   installed);
3. ENet loopback (`127.0.0.1`) in debug/editor builds only - the dev/test
   harness (browse is disabled there; join by `address:port`).

## EOS Developer Portal setup (one-time, per product)

1. Create a product on the [EOS Developer Portal](https://dev.epicgames.com).
   Note the **Product ID** and **Sandbox ID**.
2. Create a **Deployment** (or use the default one) with the **Client Policy**
   you need; note the **Deployment ID**.
3. Create a **Client** (in the deployment's client policy section): note the
   **Client ID** and **Client Secret**.
4. Enable the **Lobby** and **P2P** interfaces in the client policy (this
   project uses Lobby create/search/join/attributes and P2P sockets).
5. Copy the deployment's **encryption key** (EOSG requires it).
6. Fill those values into `eos_credentials.cfg` (see below).

## Credentials

```
copy eos_credentials.example.cfg eos_credentials.cfg
```

Then fill in the `[eos]` section. `eos_credentials.cfg` is **git-ignored**
and must never be committed (see `.gitignore`; the loader prints presence,
never values). The loader also accepts `user://eos_credentials.cfg`
(per-user override). Without a configured file, online stays in the
dev harness (debug builds) or shows an actionable error (release builds).

## Authentication

- **Debug/editor builds**: the **Dev Auth Tool** (EOSG's
  `DevToolHelper`). Run the EOS Dev Auth Tool locally
  (`java -jar DevAuthTool.jar -port 4545 -cred1 PlayerOne`), pick the
  credential in the UI; defaults are `localhost:4545` / `PlayerOne`
  (override `devtool_url` / `devtool_credential`).
- **Release builds**: an **anonymous Device ID** login is created
  automatically (the online entry screen discloses this; the identity is
  device-local and NOT a recoverable account).

Force either mode with `auth_mode = "devtool"` or `"device"` in the
credentials file.

## Addon installation (EOSG)

1. Install the addon from
   [epic-online-services-godot](https://github.com/3ddelano/epic-online-services-godot)
   into `res://addons/epic-online-services-godot/` (see its README for the
   prebuilt releases and the EOS SDK requirements).
2. Open the project in the **Godot editor once** so the addon's global
   classes (`EOS`, `HCredentials`, `BaseClass`, `HLog`) register, then
   restart if prompted. (The bridge refuses to load when those classes are
   missing, and the status line tells you exactly this.)
3. No autoload changes are needed: `OnlineService` instantiates the
   bridge and its `H*` helpers as children at runtime; it also ticks `IEOS`
   per frame from the bridge.

## Custom transport (optional but recommended)

To enable the project's own `EOSMultiplayerPeer` (deterministic ids,
membership gating, fragmentation), build it into the EOSG binary:
`addons/eos-transport/README.md` has the exact steps (copy two files,
register the class, rebuild the addon). After it registers, the online
status line shows `EOS P2P (EOSMultiplayerPeer)`.

## Validation checklist

Run through this order after any transport/lobby change (see the plan):

1. `godot --headless --script tests/run_tests.gd` - offline/online unit +
   protocol suites (the session suite runs the full host<->client flow
   over the ENet dev harness, including intents, snapshots, results,
   and disconnect teardown).
2. Debug builds: ONLINE CO-OP -> P2P PROOF (DEBUG) over a dev session -
   native `MultiplayerSpawner`/`MultiplayerSynchronizer` replication.
3. With EOSG + Dev Auth Tool: two instances, CREATE LOBBY on one, JOIN BY
   ID on the other, START ROUND, play, return to lobby, start again -
   confirming the lobby persists between rounds.
4. With two machines behind symmetric/symmetric NATs, confirm direct
   connection, and confirm EOS relay fallback still plays when direct
   fails (NAT types show in the online status; relay fallback is EOS
   default behavior).