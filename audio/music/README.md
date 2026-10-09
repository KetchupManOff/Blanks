# Built-in music

Drop legally supplied tracks here. Supported formats: `.ogg`, `.mp3`,
`.wav`. Files are scanned at startup and by the settings screen's
"Rescan Music Library" action, and appear as built-in tracks (shown before
custom tracks, with friendly labels when known).

`placeholder_loop.wav` is a synthesized original chord loop shipped so
Single mode has something to play out of the box - replace or delete it
when real tracks are available. It contains no Tetris melodies.

## Copyright warning

Famous Tetris themes (Korobeiniki, Troika, and other versions of the
Russian folk songs and classical arrangements used by Tetris products)
may be copyrighted depending on the arrangement and recording. Only add
files you own the rights to or that are verifiably licensed for
distribution. The game code ships with no recordings; missing files are
safe no-ops.

## Recognized filenames

The audio manager maps these filenames to friendly labels (any other
supported file is shown by its filename without extension):

- `korobeiniki.ogg` - Korobeiniki (Theme A)
- `brides.ogg` - Bride of the Princess (Theme B)
- `katyusha.ogg` - Katyusha (Theme C)
- `troika.ogg` - Troika (Theme D)
- `tancov.ogg` - Dance of the Sugar Plum Fairy (Theme E)
- `prelude.ogg` - Prelude in C# Minor (Theme G)
- `menu_theme.ogg` - Main Menu Theme

## Custom music

Players can also place their own files in `user://music/` (shown in the
settings screen with the absolute path) without touching the project
files. Custom tracks display by filename.
