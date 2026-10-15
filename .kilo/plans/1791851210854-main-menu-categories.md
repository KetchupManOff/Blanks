# Main Menu Categories Plan

## Goal

Replace the flat gameplay entries in the main menu with these ordered top-level choices:

1. `SOLO`
2. `LOCAL MULTIPLAYER`
3. `ONLINE MULTIPLAYER`
4. `PROFILES`
5. `SETTINGS`
6. `QUIT`

Keep every currently playable mode and its existing start/lobby behavior. This is a navigation and player-facing terminology change only; core game rules, online transport, persistence, and profile data remain unchanged.

## Confirmed UX Decisions

- Selecting `SOLO` opens a dedicated mode menu with `MARATHON`, `40-LINE SPRINT`, `TOWER`, and `BACK`.
- A solo mode still opens the existing profile picker before starting a run.
- Navigation is hierarchical:
  - Back from the solo mode menu returns to the top-level main menu.
  - Back/cancel from a solo profile picker returns to the solo mode menu.
  - Back from local multiplayer and online multiplayer entry returns to the top-level main menu.
- The main-menu category labels use the exact requested text.
- Rename menu and lobby player-facing terminology to local/online multiplayer, including local lobby and online entry/lobby headings and instructions.
- Leave mode-specific in-game/result text such as `Coop` unchanged, since it distinguishes shared-board modes from Versus.

## Implementation Steps

1. Update `scripts/ui/menu_controller.gd`.
   - Replace the current flat main-menu game-mode entries with the six approved top-level items in the requested order.
   - Point `SOLO` to a new host command that opens the solo chooser; point local and online entries to the existing local-lobby and online-entry commands.
   - Add a `show_solo_menu(host)` presentation method using the existing generic menu engine. It will show the three current solo modes and an explicit `BACK` item, and wire `ui_cancel`/controller Back to return to the top-level menu.
   - Update the contextual detail copy for the top-level and solo views so it no longer claims the screen is a flat local arcade-mode list, while retaining the active-profile summary where appropriate.
   - Reuse the existing `open`, `close`, focus, input, sounds, and theme path. Do not introduce a new scene or separate menu framework.

2. Update menu routing in `scripts/ui/game_host.gd`.
   - Add a `cmd_open_solo_menu()` command valid from `MAIN_MENU` that replaces the current menu content with the solo chooser.
   - Add a command/callback for returning from that chooser to `_show_main_menu()`.
   - Track the profile-picker return context narrowly enough to distinguish a solo-start picker from profile management and the local lobby picker. On `cmd_profile_screen_back()`, return a canceled solo picker to the solo chooser; preserve the current local-lobby cancellation behavior and ordinary profile-management return to the top-level menu.
   - Clear/reset this context whenever navigation finishes or returns to the main menu so stale state cannot redirect a later profile-screen exit.
   - Keep `cmd_start_marathon`, `cmd_start_sprint`, `cmd_start_tower`, and run construction unchanged aside from entering them from the new submenu. A selected profile must still close the picker and start the chosen mode exactly as it does today.
   - Keep local multiplayer mapped to the existing `cmd_open_coop_setup()` lobby, and online multiplayer mapped to `cmd_open_online()`; do not change their available mode cycles or online session lifecycle.

3. Rename multiplayer menu/lobby wording without renaming implementation concepts.
   - In `scripts/ui/coop_setup_menu.gd`, change the local lobby heading and any surrounding player-facing instructions from `CO-OP` terminology to `LOCAL MULTIPLAYER` terminology.
   - In `scripts/ui/online_menu.gd`, rename the online entry and lobby headings/details from `ONLINE CO-OP` to `ONLINE MULTIPLAYER`, including room-sharing wording where it refers to the menu category.
   - Update relevant player-facing host/menu comments only when necessary to prevent the new routing semantics from being misleading. Leave identifiers, core class names, and result text untouched.

4. Update `tests/test_shell.gd` menu-flow coverage.
   - Replace assertions that expect `MARATHON` and `CO-OP` directly on the main menu with an exact/order-sensitive assertion for the new six top-level labels.
   - Add coverage that `SOLO` opens the chooser with all three expected modes and Back restores the top-level menu.
   - Verify selecting a solo mode still opens the profile picker, and canceling that picker restores the solo chooser rather than the top-level menu.
   - Retain/adjust the existing tests proving profile selection starts the correct solo mode and that normal main-menu/profile behavior still works.
   - Add lightweight assertions for the renamed local and online overlay titles/details only where the existing test fixture initializes those screens; avoid network-dependent tests for static copy.

## Edge Cases And Compatibility

- No mode is removed: solo retains Marathon, Sprint, and Tower; local and online lobbies retain their existing mode cycles and eligibility rules.
- `Esc`/controller B must follow the same hierarchy as explicit `BACK` rows, without leaving an overlay open behind another overlay.
- The existing profile picker also serves local-lobby joins and profile management, so its new solo return behavior must be context-specific rather than unconditional.
- Top-level `Profiles`, `Settings`, and `Quit` retain their existing callbacks and behavior.
- No persisted settings migration is needed because menu depth and return context are session-only UI state.
- The implementation must preserve currently uncommitted changes in the affected files.

## Validation

1. Run `godot --headless --script tests/run_tests.gd` from the repository root.
2. Manually smoke-test with keyboard and controller navigation:
   - Verify the exact top-level order and selection behavior.
   - Enter/exit the solo chooser by explicit `BACK` and `Esc`/B.
   - Open each solo mode, cancel profile selection, then select a profile and verify its run starts.
   - Enter and leave local multiplayer and online multiplayer entry screens; verify their renamed headings and return path.
3. Verify game results, pause/menu returns, and profile-management Back still land on the top-level main menu unless they originated from the solo-start flow.
