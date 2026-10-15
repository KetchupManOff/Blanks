# Windows Online Dev Export

## Goal

Create a shareable Windows x86_64 **debug** package for external online testing against the existing public relay, `ws://76.13.27.117:8090`. The package lets both players connect to the same relay without requiring Godot, project files, or per-machine environment setup.

## Decisions

- Scope is Windows x86_64, matching the only existing export preset.
- Use a Godot debug export because debug/editor builds are intentionally the only builds permitted to use `ws://`; release exports require `wss://`.
- Do not place the relay IP in `project.godot`, `export_presets.cfg`, or another tracked configuration file. The package operation receives the URL as an argument and writes it only into the generated shareable bundle's launcher.
- Keep the existing release export and `export_game.bat` behavior unchanged.
- TLS/domain deployment is out of scope for this temporary friend-test workflow.

## Implementation

1. Extend `package_release.ps1` into a parameterized packager without changing its release defaults.
   - Add a switch identifying a debug/dev export and a `RelayUrl` string parameter used only for that mode.
   - Require a nonempty, valid `ws://` or `wss://` relay URL when making a debug online package; fail before exporting for missing or malformed input.
   - Select `--export-debug` for dev exports and retain `--export-release` for the default release path.
   - Update package/log labels so the generated artifact accurately identifies whether it is debug or release.
   - After assembling a debug package, generate `Start Online Dev.bat` beside the executable. It must set `TYE_RELAY_URL` for only the child process, launch the packaged executable from its own directory, and keep the console open if startup fails. Quote the executable path and environment assignment so paths with spaces work.
   - Do not create this launcher for ordinary release packages.

2. Add a tracked `export_online_dev.bat` convenience entry point for Windows developers.
   - Generate a timestamped `TetrisYankEdition_OnlineDev_<timestamp>` name in `Exports/`, without overwriting an unrelated build.
   - Prompt for the relay URL rather than hardcoding the current IP in a tracked file; show the known format `ws://host:port` in the prompt.
   - Invoke `package_release.ps1` with the debug switch and supplied relay URL, then print the package folder and ZIP paths using the same success/failure behavior as `export_game.bat`.
   - The operator will paste `ws://76.13.27.117:8090` for this test. The resultant ZIP intentionally contains that endpoint only in `Start Online Dev.bat`, which is necessary for recipients to connect.

3. Update the relevant packaging/online guidance in `ONLINE_SETUP.md`.
   - Document the Windows dev-export command, the resulting ZIP, and that the recipient extracts it and uses `Start Online Dev.bat` rather than the `.exe` directly.
   - State that this is an unsigned debug test build, so Windows SmartScreen may require an explicit user approval, and that it is unsuitable for a public release because its relay connection is unencrypted.
   - Retain the existing production recommendation: deploy TLS and set a `wss://` endpoint before creating a release export.

## Validation

1. Run `godot --headless --script tests/run_tests.gd` before packaging, per `AGENTS.md`.
2. Run `cd relay && npm test` to confirm the relay protocol suite remains green.
3. Create a dev package through `export_online_dev.bat`, supplying `ws://76.13.27.117:8090`.
4. Inspect the ZIP contents after extraction: Windows executable/PCK, existing open-file assets, and `Start Online Dev.bat` are present; no editor files, test files, credentials, EOS files, or release-only endpoint configuration are introduced.
5. Launch the generated launcher locally and confirm the Online menu reaches `Ready - create or join a room`; launching the executable directly should correctly report online unavailable because the environment override is absent.
6. Perform the real two-computer test over separate Internet connections: host creates a room, shares its code, friend joins using the supplied launcher, both reach the lobby, ready up, play a round, return to the persistent lobby, and leave. Confirm malformed/expired room-code feedback and host-disconnect feedback remain actionable.

## Risks And Boundaries

- The public relay port must remain reachable from the friend's network. This planning session could not execute a TCP reachability probe due to tool permissions, so validate it during the two-computer test.
- A direct `ws://` relay has no transport encryption and should be treated as a short-lived trusted-friends test only.
- The worktree already contains unrelated online/gameplay changes; implementation must not revert or bundle source changes outside the packaging and documentation files above.
