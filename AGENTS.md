# AGENTS.md

## Project

Godot 4.7 GDScript project ("Tetris Yank Edition"). Everything is
code-built UI - avoid inventing `.tscn` files except where they are
just script holders (see `scenes/`).

- Core gameplay (`scripts/core/`) is `RefCounted` and pure; no scene-tree
  dependencies. UI (`scripts/ui/`) and input (`scripts/input/`) drive it
  through `GameHost` (`scripts/ui/game_host.gd`), which is the single
  orchestration boundary: UI code only ever calls `cmd_*`/`action_*`
  methods on the host.
- Online co-op lives behind the `OnlineService` autoload
  (`scripts/online/`) and a WebSocket relay (`relay/`); never touch
  transport internals from gameplay code. See `ONLINE_SETUP.md`.

## Tests

Run the full suite (required before finishing any task):

```
godot --headless --script tests/run_tests.gd
```

(Use a Godot 4.7 console binary.) The runner registers suites in
`tests/run_tests.gd`; suites extend `tests/test_lib.gd`. Tests never
require the editor, a relay deployment, or a network: the online suites
run against the in-memory relay hub (`relay_memory.gd`). The relay's
own suite runs headless with `cd relay && npm test`.

## Conventions

- Typed GDScript; extensive `##` doc comments for lifecycle/state
  behavior; explicit guard clauses.
- No comments unless they explain non-obvious behavior (match the
  existing density in `scripts/core/`).
- The relay holds no credentials or secrets; keep it that way and
  never commit local `.env` overrides or player data.