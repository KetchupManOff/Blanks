# Add your own music

This folder is where you drop your own music files so the game plays
them as built-in tracks. Nothing ships in the repository: the folder is
git-ignored, so any file you place here stays on your machine and is
never committed or uploaded.

## How to use it

1. Copy your music files into this folder (`audio/music/`).
2. Supported formats: `.ogg`, `.mp3`, `.wav`. Other extensions are
   ignored.
3. Start the game - the folder is scanned at startup and the tracks
   appear in the settings screen as built-in music. You can also use
   the settings screen's "Rescan Music Library" action to pick up files
   added while the game is running.
4. Files are never modified or rewritten: loudness matching for custom
   tracks is applied at playback time only.

Any file whose name is not recognized is listed by its filename without
extension. These filenames get friendly labels in the music list:

- `korobeiniki.ogg` - Korobeiniki (Theme A)
- `brides.ogg` - Bride of the Princess (Theme B)
- `katyusha.ogg` - Katyusha (Theme C)
- `troika.ogg` - Troika (Theme D)
- `tancov.ogg` - Dance of the Sugar Plum Fairy (Theme E)
- `prelude.ogg` - Prelude in C# Minor (Theme G)
- `menu_theme.ogg` - Main Menu Theme

## Copyright warning

Famous Tetris themes (Korobeiniki, Troika, and other versions of the
Russian folk songs and classical arrangements used by Tetris products)
may be copyrighted depending on the arrangement and recording. Only add
files you own the rights to or that are verifiably licensed for your
personal use.

## Alternative: per-user custom music

You can also place files in the `music/` folder of the game's user data
directory (`user://music/`, shown in the settings screen with its
absolute path). Those tracks are listed as custom tracks, work the same
way at runtime, and never touch the project files.

## Missing files are safe

The game code ships with no recordings. An empty or missing folder is a
safe no-op: menus, gameplay, and tests all run without any music file.
