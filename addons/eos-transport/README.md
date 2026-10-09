# EOS Transport (custom `EOSMultiplayerPeer`)

A dedicated C++ GDExtension transport implementing an **EOS-backed
`MultiplayerPeer`** for this project's online co-op, exactly as the plan
specifies: native Godot multiplayer (RPCs, `MultiplayerSpawner`,
`MultiplayerSynchronizer`) over EOS P2P, with:

- **host-assigned peer ids**: server = `1`, clients = `2..max_peers`,
  assigned in accept order through an id-assignment handshake (no
  client-random ids, so roster/slot mapping is deterministic);
- **manual accept gating**: only product user ids passed to
  `allow_peers()` (the EOS lobby's members) may establish connections;
  duplicates, strangers, and over-capacity peers are refused;
- **internal fragmentation/reassembly**: MultiplayerAPI packets larger
  than `EOS_P2P_MAX_PACKET_SIZE` are split and reassembled, so gameplay
  traffic never hits the EOS packet ceiling;
- **reliable/unreliable transfer modes** mapped onto EOS packet
  reliability (gameplay code uses standard Godot RPC transfer modes).

Adapted from EOSG's `EOSGMultiplayerPeer` (MIT License, (c) Dallin Lovin
aka LowFire), which implements the same `MultiplayerPeerExtension` virtuals.

## Files

- `src/eos_multiplayer_peer.h` / `src/eos_multiplayer_peer.cpp` - the
  transport, written as a **drop-in for the EOSG addon's build**: it
  includes the EOSG tree's internal headers (`ieos.h`, `eos_p2p.h`,
  `utils.h`) and drives EOS through `IEOS::get_singleton()->_p2p_*`, the
  same wrappers EOSG's own peer uses.

## Why drop-in (and not a separate .gdextension)

Both extensions must share ONE EOS SDK state (one `EOS_Initialize`, one
platform handle, one auth session). The only reliable way to get that in
one process is to compile this class **into the EOSG addon's binary**,
which owns the SDK instance and the `IEOS` singleton. The runtime accepts
this transport only when `ClassDB.class_exists("EOSMultiplayerPeer")` -
i.e. after a rebuilt EOSG registers it - and otherwise transparently
falls back to the addon's built-in `EOSGMultiplayerPeer` (also
EOS-backed, same RPC contract; peer ids are client-random but the
session protocol maps peer->slot at the roster layer, so nothing in the
gameplay code changes).

## Integrating and building

Prerequisites: the EOSG addon installed at
`res://addons/epic-online-services-godot/` (with its `godot-cpp` +
EOS SDK build environment; see its repository README).

1. Copy `src/eos_multiplayer_peer.h` and `src/eos_multiplayer_peer.cpp`
   into the EOSG addon source tree (e.g. `src/`).
2. Register the class in the addon's `register_types.cpp`:

   ```cpp
   #include "eos_multiplayer_peer.h"
   // inside register_eosg_types():
   ClassDB::register_class<EOSMultiplayerPeer>();
   ```

3. Add `src/eos_multiplayer_peer.cpp` to the addon's build script
   (`SConstruct`/CMake sources list) and build the addon per its own
   instructions.
4. Reopen the project; `OS.get_class_list` / the online menu status shows
   the transport in use ("EOS P2P (EOSMultiplayerPeer)").

### Reconcile with your EOSG version

This source is written against EOSG's internal API as of the addon's
`main` branch. When building, verify these details against your copy:

- `utils.h` helpers: `encode_uint32`/`decode_uint32`,
  `encode_uint16`/`decode_uint16`,
  `eosg_string_to_product_user_id`, `eosg_product_user_id_to_string`,
  `STRNCPY_S` (adjust if named differently).
- The `IEOS::_p2p_*` notification/polling wrappers and their options
  structs (`EOS_P2P_AddNotifyPeerConnection*`, `EOS_P2P_ReceivePacket*`,
  `EOS_P2P_SendPacketOptions`, ...).
- `EOS_P2P_SOCKETID_SOCKETNAME_SIZE` / API-LATEST macros from the EOS SDK
  headers shipped with the addon.

4. The transport polls EOS inside `_poll()` (MultiplayerAPI frame), and
   its callbacks fire on the `IEOS` tick thread - this project's bridge
   (`scripts/online/eosg_bridge.gd`) ticks `IEOS` from `_process`, so
   callbacks and polling share the main thread. No locking needed.

## Not needed for correctness

The transport adds id determinism and packet-size headroom, but the
online session protocol (`scripts/online/`) already works over the
EOSG built-in peer: gameplay correctness does not depend on this module
being built. It exists because the plan requires a dedicated EOS-backed
MultiplayerPeer with the handshake/accept/fragmentation contract above,
and because snapshots are large enough that transport-level
fragmentation (in addition to the RPC-level chunking) is the robust
default.

## Provenance

- `EOSGMultiplayerPeer` (the upstream this adapts): MIT License,
  (c) Dallin Lovin aka LowFire.
- EOS SDK: Epic Online Services SDK - subject to Epic's terms; not
  redistributed in this repository.