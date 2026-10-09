# Modding the packaged game (open files install)

The release ships its moddable content as plain files beside the
executable. Nothing is packed away: edit a file, restart the game (or use
the in-game reload/rescan), and your change applies. The `.exe` and `.pck`
only carry the engine and the game code.

## Layout

```text
TetrisYankEdition/
├─ TetrisYankEdition.exe    game and engine
├─ TetrisYankEdition.pck    code and scenes (keep next to the exe)
├─ music/                   gameplay and menu soundtrack
├─ sfx/                     gameplay and UI sounds
├─ themes/                  visual themes
│  └─ assets/...            optional theme media (any subfolder structure)
└─ MODDING.md               this file
```

## music/

- Formats: `.mp3`, `.ogg`, `.wav`.
- Replace a file (keeping its name) to swap that track, add a new file to
  add a track, or delete a file to remove it.
- Use Settings > Audio > Rescan Music Library after adding, removing, or
  editing files, or restart the game.
- Tracks in this folder play at their original volume. If you want
  loudness matching for your own additions, put them in the custom music
  folder instead (the path is shown in Settings > Audio); the Normalize
  Custom Music option applies there.
- The packaged build ships this folder as the music source: deleting it
  leaves the game playable and silent.

## sfx/

- Formats: `.mp3`, `.ogg`, `.wav`.
- Sounds are addressed by filename without the extension: `move.wav` is
  the move sound, `hard_drop.wav` the hard-drop sound, and so on. The
  name table is in `sfx/README.md`.
- Replacing a file with the same name swaps that sound on the next
  launch; a brand-new name only becomes audible if the game requests it.
- Deleting a file silences that event (never an error).

## themes/

- `.theme` text files; the format and all properties are documented in
  `themes/README.md`.
- Themes may reference media assets - background images (`.png` `.jpg`
  `.jpeg` `.webp`), background videos (`.ogv`), fonts (`.ttf` `.otf`),
  and per-piece skins - with quoted relative paths. Asset files can be
  organized in subfolders (for example `themes/assets/`); the release
  keeps the whole folder structure intact.
- Editing `retro_crt.theme` (same filename) changes the built-in Retro
  CRT selection in place, so saved selections keep working.
- Adding `my_pack.theme` adds a new selectable theme to the list.
- Use Settings > Display > Reload Themes after editing, or restart.
- A file that fails to parse is reported in the settings status line and
  ignored; the packaged built-in with the same name stays active.
  Deleting a loose theme file restores the packaged built-in with that
  name (themes also ship inside the PCK as fallbacks).
- Missing or unreadable assets never break a theme: each is reported as
  a warning and the affected background/font/skin falls back to its
  color or built-in equivalent, so the theme stays selectable.

## Notes

- Content is read at startup and on reload/rescan; no tools or Godot
  installation are needed to mod the game.
- Keep the `.exe` and `.pck` together in the same folder.
- Personal settings (selections, volumes, bindings) are stored per
  Windows user and are separate from these files.
