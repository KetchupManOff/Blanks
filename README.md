# Tetris Yank Edition

Tetris Yank Edition is a feature-rich, moddable Tetris-style game built with
[Godot 4.7](https://godotengine.org/). It combines classic tetromino
gameplay with local multiplayer, host-authoritative online play, customizable
themes, open-file music and sound effects, and a deliberately testable core.

## Features

- **Solo modes:** Marathon, 40-Line Sprint, and Tower.
- **Local multiplayer:** shared-board co-op and competitive matches for up to
  four players.
- **Online multiplayer:** create or join private rooms using a shareable room
  code. No player account, launcher, port forwarding, or credentials are
  required.
- **Competitive options:** Classic Versus with optional garbage and Tower
  matches with dynamically growing boards.
- **Customizable presentation:** built-in visual themes, custom theme files,
  background images and videos, fonts, piece skins, dithering, and bloom.
- **Open-file modding:** replace music, sound effects, and theme assets beside
  the exported game without repacking the project.
- **Profiles and controls:** per-profile settings, bindings, input-device
  assignments, audio controls, and local score/history tracking.
- **Offline-first design:** online services are isolated from the gameplay
  core, so offline play does not depend on a relay.

## Getting started

### Play a packaged build

Windows x64 packages can be created with the repository's export script:

```bat
export_game.bat
```

The script creates a timestamped folder and ZIP archive under `Exports/`.
Keep the generated `.exe` and `.pck` together when moving or distributing the
game. The packaged build also includes loose `music/`, `sfx/`, and `themes/`
folders that can be edited for modding.

### Run from Godot

1. Install Godot 4.7.
2. Import this repository as a Godot project.
3. Run the project; its main scene is `scenes/main.tscn`.

The default renderer is Godot's Compatibility renderer. The project is
currently configured for a 1280×720 viewport with canvas-item stretching.

## Controls

The game supports keyboard and gamepad input. The in-game profile and settings
screens are the source of truth for the active bindings; bindings can be
changed per profile. Menu navigation supports D-pad/arrow keys, `A`/Enter to
select, and `B`/Escape to go back.

## Online co-op

Online play uses a self-hosted WebSocket relay in `relay/`. The game host
remains authoritative for simulation, input validation, and snapshots; the
relay only forwards frames between peers.

For players, the flow is simple:

1. Select **Online → Create Room**.
2. Share the displayed room code.
3. Other players select **Online → Join Room** and enter the code.
4. Players ready up; the host chooses the mode and starts the round.

To configure or deploy a relay, see [ONLINE_SETUP.md](ONLINE_SETUP.md). The
relay requires Node.js 20+ and can run directly or through Docker:

```sh
cd relay
npm install
npm start
```

The relay's own tests can be run with:

```sh
cd relay
npm test
```

For temporary friend testing, `export_online_dev.bat` creates a debug package
that launches against a supplied `ws://` relay URL. Use a TLS-terminated
`wss://` relay for public or release deployments.

## Modding

Exported builds intentionally keep user-editable content as plain files:

```text
TetrisYankEdition/
├─ TetrisYankEdition.exe
├─ TetrisYankEdition.pck
├─ music/
├─ sfx/
├─ themes/
└─ MODDING.md
```

Replace or add supported files, then restart the game or use the relevant
reload/rescan action in Settings. See [docs/MODDING.md](docs/MODDING.md) for
the complete packaged-layout guide and [themes/README.md](themes/README.md)
for the theme format and asset rules.

## Development

The code is organized around a pure gameplay core and a Godot UI shell:

```text
scripts/core/          Gameplay rules and simulation
scripts/input/         Keyboard/controller input handling
scripts/ui/            Menus, HUD, orchestration, and settings
scripts/presentation/  Board and piece rendering
scripts/online/        Online service and relay transports
scripts/persistence/   Profiles, settings, and score history
relay/                 Node.js WebSocket relay
tests/                 Godot test suites
```

`GameHost` is the boundary between the UI and gameplay. UI and input code
should call the host's command/action methods rather than reaching into
transport or gameplay internals directly.

## Testing

Run the full Godot suite from the repository root:

```sh
godot --headless --script tests/run_tests.gd
```

This covers board behavior, randomization, scoring, rotation, themes,
settings, input, gameplay, co-op, competitive modes, and online protocol
flows. Online tests use an in-memory relay and do not require a network or a
deployed service. Run the relay suite separately with `cd relay && npm test`.

## Repository guides

- [Online setup and deployment](ONLINE_SETUP.md)
- [Packaged-game modding](docs/MODDING.md)
- [Custom theme format](themes/README.md)
- [Relay service](relay/README.md)
- [Audio file conventions](audio/sfx/README.md)

## Project status

Tetris Yank Edition is an actively developed Godot project. Exported builds,
relay deployments, and online development packages may require configuration
specific to the environment in which they are run.
