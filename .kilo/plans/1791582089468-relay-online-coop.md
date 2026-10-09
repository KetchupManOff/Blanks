# EOS-Free Online Co-op Plan

## Goal and Decisions

Replace EOS authentication, lobby discovery, NAT traversal, and EOS P2P with an EOS-free, host-authoritative online mode that is simple for players:

- The game ships with one configured `wss://` relay URL; players create a room or enter a shared opaque room code.
- No account, launcher, credentials file, IP address, router configuration, lobby browser, or player-side configuration is required.
- A self-hosted Node.js relay is the reliable Internet path. It forwards traffic only; the host still owns simulation, validates client input, and publishes snapshots.
- Rooms are private/unlisted. The relay creates high-entropy room codes, admits at most four peers, removes the room if its host disconnects, and expires idle rooms.
- This is relay-backed multiplayer, not literal direct P2P. That tradeoff is intentional: direct P2P cannot reliably connect all household NAT/router combinations without user configuration or an external relay service.
- Keep the current four-player maximum, persistent lobby between rounds, host-disconnect behavior, and no host migration. Public browsing, accounts, invitations, cross-platform identity, and anti-cheat are out of scope.

## Existing Boundaries

- `scripts/ui/game_host.gd` is already the correct orchestration boundary. It only calls `OnlineService` commands and receives callbacks; retain that boundary and its host-authoritative `CoopGame` model.
- `scripts/online/online_service.gd` currently owns both session state and EOS/`MultiplayerPeer` setup. Its state/lobby/match ownership and input validation should remain, but remove `bridge`, credential, EOS identity, browser, and direct ENet production branches.
- `scripts/online/online_net.gd` is currently RPC-only. Replace it with explicit relay-frame encode/decode and send helpers while retaining the same service handler names and authority checks.
- `scripts/ui/online_menu.gd` currently exposes EOS wording, a conditional browser, and a generic lobby-id/address field. Simplify it to host/create and join-by-room-code.
- Current tests use the debug ENet harness and Godot RPC paths. They must move to an injected in-memory relay transport so tests remain headless, deterministic, and independent of a real relay.

## Implementation Steps

1. Add a deployable relay service under `relay/`.
   - Add a minimal Node.js package using the `ws` WebSocket dependency, a Dockerfile, Compose example, `.env.example`, and deployment instructions for terminating TLS with Caddy or nginx.
   - Configure listener port, permitted web origins if applicable, room idle timeout, packet-size limit, and connection/rate limits through environment variables; do not embed credentials in the client or repository.
   - Use a small control protocol over JSON: `create`, `join` with an opaque code, `created`, `joined`, `error`, `peer_joined`, `peer_left`, `room_closed`, and heartbeat acknowledgements.
   - Generate cryptographically secure, case-normalized codes with enough entropy to resist casual guessing; reject invalid codes, duplicate host rooms, joins after four peers, and non-host control actions.
   - Assign relay peer IDs deterministically: host `1`, then unique client IDs `2..4`; the relay, never the client payload, supplies the incoming sender ID.
   - Forward binary game envelopes only from clients to host and from host to room clients. Enforce direction, maximum frame size, per-socket rate limits, and closed/error handling without decoding or trusting gameplay payloads.
   - On host socket close or heartbeat timeout, notify remaining members that the room closed and delete it. On client close, notify the host so it can update its roster. Periodically expire empty/idle rooms and clear timers on shutdown.

2. Define a small relay transport boundary in `scripts/online/`.
   - Add a typed `relay_connection.gd` contract/facade that exposes connect/create/join/leave, binary send, poll, current peer ID, and relay lifecycle events. Add a production `WebSocketPeer` implementation using Godot's built-in WebSocket support and an in-memory implementation solely for headless tests.
   - Keep the server URL as one non-secret product setting with a release default, plus an environment/project override for development and staging. Validate only `ws://` for local debug and `wss://` for release; report a clear unavailable/offline status when the endpoint is unset or unreachable.
   - Define one versioned envelope for relay-forwarded game messages. Serialize only allowed primitive/array/dictionary/`PackedByteArray` payloads, include message type and protocol version, and impose client-side payload limits before sending.
   - Preserve sender identity at the transport boundary rather than accepting a sender field from the remote player. The service must reject host-only messages received from a non-host, client messages received by clients, malformed envelopes, unexpected state messages, wrong protocol version, and oversized payloads.

3. Migrate `OnlineService` to the relay-only lifecycle.
   - Replace EOS-specific state/comments/constants and `TransportKind` with relay connection state. Reduce readiness to endpoint availability; remove initialization/authentication state transitions, product user IDs, credentials, lobby attributes, `bridge`, browse results, and EOS-specific shutdown.
   - On `create_lobby()`, connect to the relay, request a room, store the returned room code, become peer `1`, initialize roster slot `0` from the existing local profile display name, then enter `LOBBY` only after the relay acknowledges creation.
   - On `join_lobby(code)`, normalize and validate the code locally, connect/request join, wait for the assigned peer ID, then send the existing client hello. Do not expose or accept host addresses.
   - Route relay lifecycle events into existing roster/disconnect behavior: host adds only successfully handshaked clients, client loss removes its roster entry, and a room-close/host-loss during a match triggers the existing actionable error and teardown. A client cannot continue after host loss.
   - Keep ready toggles, host-selected mode, start gate, roster slots, intent guards, snapshot sequence/chunk reassembly, result broadcast, and return-to-lobby semantics. Change roster identity from EOS PUID to relay peer ID/local display name only; remove PUID lookup and EOS lobby membership checks.
   - Poll the relay connection from `_process`, reset all connection/session state on leave, and close only the local WebSocket. The relay owns room cleanup; the host may additionally send an explicit close for prompt teardown.
   - Preserve operation-token cancellation and add bounded create/join/handshake timeouts so a lost relay response cannot strand UI state.

4. Replace RPC transport I/O with relay envelopes in `online_net.gd`.
   - Remove `@rpc`, `rpc_id`, `rpc`, `MultiplayerAPI`, and multiplayer-authority assumptions. Provide the existing semantic helpers for client hello, ready changes, intents, lobby state, match start/results/return, and reliable/unreliable snapshot labels through `OnlineService`/`RelayConnection` instead.
   - Dispatch incoming envelope type plus relay-provided sender ID to the existing `_net_*` service handlers. Maintain current authority and slot validation in the service, not in this thin I/O layer.
   - Treat snapshots as relay binary traffic. Retain chunking for defensive bounded messages; retain reliable/periodic semantics at the application layer, documenting that WebSocket itself is ordered/reliable and periodic snapshots may be dropped locally when superseded.
   - Update `GameHost` only where it reads `multiplayer.get_unique_id()` or EOS-specific terminology. Derive the local roster identity from `OnlineService.local_peer_id`; do not alter core gameplay or the public `cmd_*` orchestration boundary.

5. Simplify the online UI and remove the EOS/debug proof surface.
   - In `online_menu.gd`, present `CREATE ROOM` and `JOIN ROOM`; remove `BROWSE LOBBIES`, its screen/items/signals, `JOIN BY ID` wording, address:port hints, and all EOS/Device ID/Dev Auth Tool descriptions.
   - Display the generated room code prominently in the host lobby and use a room-code-specific input field/instructions for joining. Continue to show connection, full-room, invalid-code, timeout, and host-disconnected status text.
   - Rename user-visible copy to relay-backed online co-op without falsely calling it direct P2P. Remove the debug `P2P PROOF` entry and its GameHost command if it has no relay-equivalent purpose; remove `network_p2p_proof.gd`, `proof_player.gd`, and their holder scenes when no longer referenced.

6. Remove EOS code, autoloads, dependencies, credentials, and stale documentation.
   - Remove EOSG runtime/service autoloads from `project.godot`, leaving only `OnlineService`.
   - Delete `scripts/online/eosg_bridge.gd`, `online_credentials.gd`, their `.uid` files, `eos_credentials.example.cfg`, `addons/epic-online-services-godot/`, and `addons/eos-transport/` including their tracked binaries/source/docs. Remove EOS-only ignore rules, retaining only relevant generated artifact rules.
   - Rewrite `ONLINE_SETUP.md` as the relay deployment and player-flow guide: configure `RELAY_URL` for the build, deploy the container behind TLS, health check it, create/share/join a code, ports/domain requirements for the operator only, and clear distinction that players require no setup.
   - Audit comments and names in `game_host.gd`, tests, and docs for EOS, PUID, Dev Auth, ENet dev harness, direct P2P, or lobby browsing claims; update/remove each stale reference.

7. Rebuild tests around the new boundary.
   - Update `tests/test_online_core.gd` to remove credential tests and add protocol/frame validation tests: invalid endpoint/code normalization, malformed/unsupported message rejection, sender spoofing prevention, payload-size limits, room-code constraints, and snapshot chunk behavior.
   - Replace ENet/RPC-dependent setup in `tests/test_online_session.gd` with paired services connected through the in-memory relay. Preserve the existing end-to-end assertions for create/join/handshake, ready gate, match start, client intent ownership, snapshot convergence, result/return-to-lobby, client leave, and host loss.
   - Add relay service tests using Node's built-in test runner and `ws` test clients for room creation, join/full/invalid code responses, peer notifications, directional forwarding, spoofing attempts, host disconnect cleanup, timeout cleanup, and packet/rate limit rejection.
   - Register any new test suites in their existing runners. Keep Godot tests headless and network-free; relay integration tests start the relay on an ephemeral local port and never contact the production endpoint.

8. Validate and release safely.
   - Run `godot --headless --script tests/run_tests.gd` and the relay's Node test command. Run formatting/lint commands defined by the new Node package.
   - Manually test two release-exported clients through deployed `wss://`: host room, join by code, readiness, every playable mode, snapshots under a throttled connection, repeat round, leave from lobby, leave during match, host crash, malformed/expired/full code, and a second unrelated room.
   - Verify packaged exports no longer contain EOSG libraries, SDK files, credentials, EOS autoloads, or EOS setup text. Verify the relay works behind TLS from a non-local network and that the game rejects non-TLS relay URLs in release.

## Risks and Mitigations

- A public relay can be abused. Keep rooms private/high-entropy, cap peers/frame sizes/rates, impose idle cleanup and connection limits, do not expose a lobby list, and use TLS. This is not a security boundary against a player who possesses a room code.
- WebSocket is reliable and ordered, unlike the prior unreliable snapshot channel. Bound snapshot size/chunking, send at the existing cadence, and discard stale snapshot assemblies so a slow client cannot accumulate unbounded memory.
- The relay is a single availability dependency. Surface clear connection errors, health check it, log aggregate operational errors without room payloads or player data, and do not allow failure to crash/offline gameplay.
- Existing user edits are already present in `ONLINE_SETUP.md`, `project.godot`, `scripts/online/eosg_bridge.gd`, `scripts/online/online_service.gd`, and `tests/run_tests.gd`, plus untracked EOS build artifacts. The implementer must inspect and preserve/conflict-resolve those changes rather than blindly deleting or reverting them.
