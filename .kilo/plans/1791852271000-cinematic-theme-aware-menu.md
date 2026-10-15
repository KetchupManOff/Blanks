# Cinematic Theme-Aware Menu Plan

## Goal

Replace the current centered, two-column dialog treatment used by the shared `MenuController` with a cinematic menu composition based on the supplied reference: a restrained title/branding area, a lower-center vertical menu, a full-width selected-row treatment, and unobtrusive supporting copy. Apply that presentation consistently to every screen that inherits or uses the shared controller:

1. Top-level main menu.
2. Solo mode chooser.
3. Pause menu and return-to-menu confirmation.
4. Local and online result overlays.

Preserve all existing navigation, callbacks, host state transitions, controller support, audio cues, menu music behavior, and backdrop lifecycle. This is a presentation refactor, not a gameplay or routing change.

## Confirmed Decisions

- The reference defines layout, hierarchy, and interaction character, not a fixed color palette.
- All visual colors and fonts must come from the resolved existing theme data. Do not hard-code the reference's olive, black, white, or red values.
- Reuse the current theme backdrop pipeline (`theme.background`, optional `theme.image`/`theme.video`, fit, opacity, and tint). Do not add or reproduce a copyrighted background image, logo, or icon.
- Do not add new image, video, font, or logo assets. The screen must look correct over the current color-only built-in themes and automatically use a custom theme's backdrop media when present.
- Use the existing menu theme tokens before considering any schema additions: `theme.text`, `theme.dim`, `theme.accent`, `menu.panel`, `menu.scrim`, `menu.focus`, `menu.divider`, `menu.item_size`, `menu.spacing`, `menu.title_size`, and `menu.transition`.
- Apply the layout to all shared-controller displays. `PauseMenu` inherits `MenuController`, so it receives the same presentation without duplicating logic.
- Keep raw event navigation as-is: Up/Down and controller directional input move selection, Enter/A confirms, and a valid existing Back callback handles Escape/B. Do not introduce Godot `Button` focus navigation or new directional semantics.

## Existing Architecture To Preserve

- `scenes/main.tscn` remains a script-holder scene; all UI stays code-built.
- `scripts/ui/game_host.gd` remains the single UI-to-flow orchestration boundary. Menu callbacks continue calling only existing `cmd_*` methods.
- `scripts/ui/menu_controller.gd` remains the shared menu engine and owns menu rendering, selection, and input.
- `scripts/ui/pause_menu.gd` continues to inherit `MenuController`; preserve its special no-Back behavior to avoid racing the pause input.
- `scripts/ui/media_backdrop.gd` remains the sole owner of themed background image/video setup and teardown. The menu must not create or manage a second media layer.
- `GameHost._apply_theme()` remains the theme-application boundary and continues pushing tokens/media via `_menu.apply_theme(tokens, media)` and `_pause_menu.apply_theme(tokens, media)`.

## Implementation Steps

### 1. Recompose the shared menu layout in `scripts/ui/menu_controller.gd`

- Replace the current full-screen `CenterContainer` -> rounded `PanelContainer` -> two-column split layout built in `_build()`.
- Keep the full-screen root and non-interactive scrim, but create a lower-center menu region anchored around the horizontal center and lower-middle viewport area rather than exact fixed desktop coordinates.
- Build a compact vertical hierarchy:
  - full-screen root;
  - full-screen theme-driven scrim;
  - optional top/upper supporting title and subtitle region;
  - lower-center menu container;
  - one full-width row control per logical menu item;
  - a selected-row background/highlight owned by the menu presentation;
  - a lower or adjacent detail/status label for active-profile, mode, result, and instructional text.
- Keep title, subtitle, detail, item containers, selection index, callbacks, and navigation state as explicit members. Remove obsolete split-panel members only after all caller/test references have been updated.
- Avoid a conventional card. The selected row, not an enclosing dialog, is the primary structural surface.
- Use layout containers plus anchors/offsets so the menu stays centered and remains inside the safe viewport under resize. Do not depend on the current `CenterContainer` or absolute positions alone.
- Give item rows a configurable minimum width and height derived from font size and padding. Ensure long labels such as `ONLINE MULTIPLAYER`, `RETURN TO LOBBY`, and `NO, KEEP PLAYING` do not clip.

### 2. Implement theme-driven visual styling and selection in `scripts/ui/menu_controller.gd`

- Replace the current `"▸  "` text prefix selection treatment with a dedicated selected-row background/style. Keep every item label text semantically unchanged for tests and localization-ready behavior.
- Render non-selected labels with `theme.dim`; selected labels use `menu.focus` as the primary emphasis. If a theme requires primary text for selection, preserve readable contrast by using the existing resolved semantic tokens rather than introducing a fixed fallback color.
- Style the selected row from `menu.panel`, with optional divider/border treatment from `menu.divider`. Preserve sharp-to-subtle geometry: use a very small or zero radius rather than the current universally rounded 12px card.
- Style headings with `theme.text` and `menu.title_size`; style subtitles/details/version-like supporting information with `theme.dim`.
- Apply `theme.font` to body/item/subtitle/detail labels and `theme.title_font` to the primary heading, using the established null-clearing helper.
- Drive item gap from `menu.spacing`. Use `menu.transition` as the timing source for restrained focus/entrance transitions, clamped to a safe visible duration if necessary.
- Add a short fade or opacity transition when the selection changes and when a screen opens. Do not animate position enough to compromise input responsiveness, and stop/replace active tweens safely when the menu closes, rebuilds, or reapplies its theme.
- Preserve the full-screen `menu.scrim` layer for readability. Its alpha and appearance stay entirely theme-owned so custom themes can expose or conceal their backdrop media intentionally.
- Do not extend `ThemeProfile` unless implementation proves existing tokens cannot express a required visual state. The initial implementation must consume the established schema without new `.theme` properties.

### 3. Adapt shared content modes without changing their flow

- Keep `open(title, subtitle, items, back)` as the controller API so `show_main_menu`, `show_solo_menu`, `show_results`, `show_online_results`, and `PauseMenu` remain callers of one shared engine.
- Retain the existing top-level item order and callbacks exactly: `SOLO`, `LOCAL MULTIPLAYER`, `ONLINE MULTIPLAYER`, `PROFILES`, `SETTINGS`, `QUIT`.
- Retain the solo chooser items, results options, online result restrictions, pause options, and confirmation options unchanged.
- Treat each call's title as the screen heading and subtitle/detail as supporting copy in the cinematic composition. Keep the active-profile summary visible in the main-menu detail region and keep pause/result context readable.
- Preserve `_selected = 0`, `UiNavigation.reset()`, wrapping behavior, callback invocation, UI sound requests, and Back behavior when opening/reopening a screen.
- Preserve mouse filtering as non-interactive/ignored unless explicit mouse interaction is added later; this scope must not accidentally change the existing keyboard/controller-first menu semantics.

### 4. Keep host, backdrop, and theme boundaries intact

- Do not change `GameHost` command implementations, gameplay state, profile-picker return context, settings origins, online lifecycle, or audio context logic for this visual change.
- Do not change `MediaBackdrop` presentation precedence: video, then image, then theme color.
- Keep `GameHost._update_presentation()` behavior unchanged: menu backdrop remains visible only while no run is active; game backdrop remains behind pause/result screens.
- Ensure `MenuController.apply_theme(tokens, media)` updates every newly introduced control, style box, font override, and active-row treatment both before and after `_ready()`.
- Ensure item rebuilds on theme changes preserve the current item list and selected index when valid, rather than resetting navigation unexpectedly while the settings screen applies a new theme.
- Continue clearing stale font overrides when a selected theme does not provide custom fonts.

### 5. Update focused automated coverage

#### `tests/test_shell.gd`

- Preserve the existing assertions for top-level item order, solo routing, active-profile copy, settings round-trips, result flow, and input gating.
- Add structural assertions for the new shared layout: no legacy split-panel composition, lower-center menu container exists, row count equals logical item count, and the selected row is visibly distinguished from unselected rows.
- Add a viewport-resize or small-layout assertion if the test harness supports resizing: menu bounds must stay within the root bounds and remain horizontally centered.
- Verify the same presentation contract is applied when opening the solo chooser and result screens, not only at startup.

#### `tests/test_theme.gd`

- Extend theme-propagation coverage to verify new menu controls receive `theme.text`, `theme.dim`, `menu.focus`, `menu.panel`, `menu.divider`, body font, and title font values after `cmd_theme_selected()`.
- Verify a theme switch rebuilds item rows without losing row count, labels, or selection functionality.
- Verify a fontless theme clears every new relevant font override.
- Exercise at least the existing `modern_neon`, `retro_crt`, `clean_tournament`, and `game_boy` themes to ensure the shared composition makes no fixed-palette assumptions.
- Preserve current backdrop image/video lifecycle tests; they already establish the intended optional-media behavior for the redesigned menu.

#### `tests/test_audio.gd`

- Retain existing menu movement, confirmation, and pause navigation SFX tests.
- Add or adjust coverage only if selection animation/rebuild logic could issue duplicate `menu_move`, `menu_confirm`, or `menu_back` requests.

### 6. Verify visually and functionally

- Run the required full suite: `godot --headless --script tests/run_tests.gd`.
- Manually inspect at the project logical viewport (`1280x720`) and a 16:9 desktop viewport:
  - top-level menu has a lower-center vertical hierarchy;
  - selected row is obvious using active theme tokens;
  - all long labels fit;
  - title, subtitle, and detail do not overlap the menu;
  - no hard-coded reference palette survives;
  - no copyrighted reference image or logo has been added.
- Manually navigate keyboard and controller through main, solo, pause, result, and confirmation screens. Confirm wrapping, accept, Back behavior, callbacks, and UI sounds match existing behavior.
- Switch themes while the menu is open and while a pause/result overlay is open. Confirm fonts, colors, selected-row style, spacing, and backdrop update without changing game state or producing stale UI nodes.

## File-Level Change Summary

| File | Intended change |
| --- | --- |
| `scripts/ui/menu_controller.gd` | Primary implementation: replace centered split-panel layout with a responsive cinematic composition; implement themed selected-row styling, restrained transitions, and complete `apply_theme` refresh. |
| `scripts/ui/pause_menu.gd` | No behavior change expected; verify inherited presentation works for pause and confirmation copy. Edit only if an explicit presentation mode field is required. |
| `scripts/ui/game_host.gd` | No functional change expected; only make minimal wiring changes if a menu lifecycle hook is required. Preserve all commands and theme/backdrop ownership. |
| `scripts/ui/theme_profile.gd` | No initial change. Extend only if a concrete necessary visual setting cannot be derived from existing menu tokens. |
| `tests/test_shell.gd` | Add layout, selected-state, shared-screen, and responsive-boundary assertions while retaining flow coverage. |
| `tests/test_theme.gd` | Add complete theme refresh/font/style assertions for the new controls. |
| `tests/test_audio.gd` | Confirm no duplicate navigation sounds after visual transitions, if affected. |

## Risks And Guardrails

- The repository has unrelated uncommitted work. Do not revert, reformat, or fold those changes into this task.
- `MenuController` is shared. Do not make the main-menu visual treatment depend on top-level-only data or break pause/result content.
- `PauseMenu` intentionally has no Back callback. Preserve that behavior exactly.
- The main menu is keyboard/controller-driven today. Do not introduce `Button` focus mechanics that could conflict with raw `UiNavigation` event handling.
- Menu media belongs to `MediaBackdrop`; do not duplicate video/image loading in the controller.
- Theme changes can occur while menus are visible. New controls must update safely before `_ready()`, after `_ready()`, and after dynamic item rebuilds.
- Keep the UI code-built and typed; do not add a `.tscn` layout scene.

## Completion Criteria

- Every shared menu screen uses the new lower-center cinematic composition.
- All visual identity remains controlled by existing theme files and optional existing theme media.
- No copyrighted visual asset from the reference is copied or added.
- Existing menu commands, navigation semantics, callbacks, audio behavior, and host state transitions are unchanged.
- Theme switches update all redesigned controls correctly.
- The full Godot headless test suite passes.
