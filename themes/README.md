# Custom Themes

The game reads themes from two folders:

- Built-in: `res://themes/` (shipped with the game)
- Custom: `user://themes/` (yours - drop `.theme` files here)

`user://themes/` is created the first time you use **Settings > Display >
Reload Themes**. Files added or edited while the game is running appear after
using that reload row; no restart is needed.

Theme assets (images, videos, fonts, piece skins) referenced by a theme live
next to that `.theme` file, in the same folder or any subfolder of it. They
resolve against the theme file's own location, so a portable install and your
custom folder work the same way.

## Format

The format is CSS-like but deliberately small: selectors, properties,
values. No scripts, URLs, animations, or layout expressions are supported.

- Comments start with `#` or `//`. A `//` comments out the rest of its line;
  `#` comments must start the line (so hex colors are never cut).
- Structure is one-per-line: a selector and its `{` share a line, each
  property goes on its own line, and `}` stands alone. Compact one-line
  blocks like `theme { name: "X"; }` are not valid.
- Selectors open with `name {` and close with `}` on their own lines.
- Properties are `name: value;` - the trailing `;` is optional.
- Colors are hex: `#rgb`, `#rgba`, `#rrggbb`, or `#rrggbbaa`.
- Numbers are plain integers or decimals.
- Asset paths are double-quoted relative paths, for example
  `image: "assets/menu_bg.png";`. See "Media assets" below for the rules.
- The `theme` block with a quoted `name` is required; every other property
  is optional and inherits from the Modern Neon Arcade defaults.

Partial themes are encouraged: override only what you want to change.
`reference.theme` in this folder is a fully commented example that uses
every selector and property - a good starting point for your own file.

## Selectors and properties

| Selector  | Property           | Value            | Notes |
|-----------|--------------------|------------------|-------|
| `theme`   | `name`             | `"quoted text"`  | Required identity, shown in Settings. |
|           | `background`       | color            | Base color behind menu/settings screens. |
|           | `image`            | path             | Menu/settings background picture (`.png` `.jpg` `.jpeg` `.webp`). |
|           | `video`            | path             | Menu/settings background video (`.ogv`); see "Backgrounds" below. |
|           | `fit`              | `cover`/`contain`| How the menu background media fills the screen. Default `cover`. |
|           | `opacity`          | 0.0-1.0          | Menu background media opacity. Default `1.0`. |
|           | `tint`             | color            | Color washed over the menu background media; its alpha controls the strength. Default fully transparent. |
|           | `text`             | color            | Primary text. |
|           | `dim`              | color            | Secondary/muted text. |
|           | `accent`           | color            | Emphasis color (events, headers). |
|           | `font`             | path             | Body font for all UI labels (`.ttf` `.otf`). |
|           | `title_font`       | path             | Heading font (menu/settings/HUD titles); falls back to `font`, then the built-in font. |
| `game`    | `background`       | color            | Backdrop color around the active playfield (solo and co-op). The playfield itself uses `board.bg`. |
|           | `image`            | path             | Backdrop picture behind the active playfield. |
|           | `video`            | path             | Backdrop video behind the active playfield. |
|           | `fit`              | `cover`/`contain`| How the game background media fills the screen. Default `cover`. |
|           | `opacity`          | 0.0-1.0          | Game background media opacity. Default `1.0`. |
|           | `tint`             | color            | Color washed over the game background media. Default fully transparent. |
| `menu`    | `panel`            | color            | Menu panel/card background. |
|           | `scrim`            | color            | Full-screen dim behind menus (drawn over background media; keep some transparency if you use media). |
|           | `focus`            | color            | Selected row/item highlight. |
|           | `title_size`       | 20-96            | Title font size (px). |
|           | `item_size`        | 14-48            | Menu item font size (px). |
|           | `spacing`          | 0-48             | Vertical spacing between items. |
|           | `transition`       | 0.0-1.0          | Reserved for restrained UI transitions. |
|           | `split_gap`        | 0-160            | Horizontal gap between split menu columns. |
|           | `split_padding`    | 12-96            | Inner padding around the split menu panel. |
|           | `detail_size`      | 12-32            | Detail text font size (px). |
|           | `divider`          | color            | Split menu panel border/divider color. |
| `board`   | `bg`               | color            | Playfield background. |
|           | `peek`             | color            | Hidden spawn rows backdrop. |
|           | `grid`             | color            | Grid lines. |
|           | `border`           | color            | Playfield frame. |
|           | `ghost`            | color            | Ghost piece fill (ghosts are always color-only). |
|           | `ghost_line`       | color            | Ghost piece outline. |
|           | `flash`            | color            | Line-clear flash. |
|           | `section_line`     | color            | Co-op section dividers. |
|           | `section_tint_alpha` | 0.0-0.25       | Co-op ownership tint strength. |
| `players` | `p1` ... `p4`      | color            | Co-op player accents. |
| `pieces`  | `i` `o` `t` `s` `z` `j` `l` | color **or** path | Tetromino palette. A hex value is the piece color; a quoted path is a per-piece skin image (see below). Colors must stay readable against the themed board background; unreadable entries fall back per piece to the default color. |
|           | `dither`           | `none`/`bayer`/`hatch`/`scanline`/`stipple` | Procedural 16-bit-style shading pattern drawn as a dark ink overlay on every solid piece cell. Default `none`. |
|           | `dither_strength`  | 0.0-1.0          | For `bayer`, `hatch`, and `stipple`: how much of the cell the pattern covers and how dark the ink is, from `0.0` (invisible) to `1.0` (the full treatment). For `scanline`: the raster bands' opacity. Default `0.5` when a pattern is declared. |
|           | `bloom`            | `false`/`true`/0.0-2.0 | Additive glow over the active playfield (solo and co-op), independent of dither. Omitted or `false` is off (`0.0`), `true` uses the `0.8` default intensity, and a number sets a custom intensity up to `2.0`. Default off. |

## Media assets

Backgrounds, fonts, and piece skins are plain files referenced by quoted
relative paths. The rules keep themes portable and safe:

- Paths are relative to the `.theme` file and double-quoted:
  `theme { image: "assets/bg.png"; }`. Use `/` separators (`\` is also
  accepted and converted).
- Assets must live inside the theme's own folder (subfolders are fine).
  Paths that try to climb out of it (`../`), absolute paths
  (`C:/...`, `/...`), and URL schemes (`res://`, `http://`) are rejected
  with a warning.
- Because the parser is line-based, paths cannot contain `;`, `{`, `}`,
  `"`, `//`, or `:` - none of those are safe inside a quoted value.
- Accepted formats: images `.png` `.jpg` `.jpeg` `.webp`, videos `.ogv`
  (Ogg Theora), fonts `.ttf` `.otf`. Other extensions are reported as
  unsupported.
- Unsupported formats, missing or unreadable files never break a theme:
  the entry is reported in the Settings status line and the affected
  backdrop/font/skin falls back to its color/built-in equivalent.

Example layout:

```text
user://themes/
├─ my_pack.theme          image: "art/menu.png"; video: "art/loop.ogv";
└─ art/
   ├─ menu.png
   ├─ loop.ogv
   └─ skins/i.png
```

### Backgrounds

`theme.image`/`theme.video` paint the background under menu and settings
screens; `game.image`/`game.video` paint the full viewport behind active
gameplay (they also stay visible behind the pause overlay). Both sit above
their block's `background` color.

- Resolution precedence: a valid video, then a valid image, then the themed
  color.
- Videos autoplay, loop, and play muted. Switching themes stops and removes
  the previous video immediately. There is no audio track, no controls, and
  no autoplay-permission gating: backgrounds are decorative only.
- `fit: cover` scales the media to fill the screen (cropping the overflow);
  `fit: contain` letterboxes it. `opacity` fades the media over the
  background color (at `0.0` only the color shows). `tint` washes a color
  over the media; use its alpha channel for the wash strength (for example
  `tint: #05080fc0` for a 75% dark wash). A transparent tint (the default)
  does nothing.

### Fonts

- `font` replaces the font of every UI label; `title_font` replaces the
  font of headings (menu/settings/HUD titles) and falls back to `font`,
  then to the built-in font.
- Fonts apply everywhere labels are (re)built - menus, settings rows, HUD
  stats - not just at startup.
- Loose font files are loaded at runtime; no import step is needed for
  modded files.

### Piece skins

- Any piece letter accepts a quoted image path instead of a color:
  `pieces { i: "art/skins/i.png"; }`. The image is drawn stretched into
  every occupied cell of that piece, and the usual cell border is kept on
  top.
- Missing or invalid skins fall back per piece to the piece color; a piece
  declared as a skin keeps the default color as its fallback color.
- Skins combine with dithering: the dark ink overlay shades the skin
  texture inside each cell just like a color-filled cell.

### Dithering

`dither` shades solid piece cells (active and locked cells; ghost pieces
stay color-only) with a 16-bit-inspired pattern on an 8x8 per-cell grid,
drawn as a translucent dark ink overlay over the cell fill or skin:

- `none` (default): no pattern.
- `bayer`: the classic 8x8 ordered Bayer matrix - smooth, regular density
  ramps like console palette blending.
- `hatch`: ranked diagonal and cross-hatch strokes with a board-stable
  phase, evoking hand-shaded 16-bit sprites.
- `scanline`: fine continuous horizontal CRT raster bands.
- `stipple`: deterministic clustered-dot clusters with controlled spacing
  and a stable per-piece phase - fully deterministic, so it never
  flickers between frames.

`dither_strength` produces a tonal ramp: for `bayer`, `hatch`, and
`stipple` it sets how much of the cell the ordered pattern covers and how
dark the ink overlay is (`0.0` invisible, `1.0` the full treatment); for
`scanline` it sets the bands' opacity. When a pattern is declared without
a strength, `0.5` applies. The pattern never changes piece readability
rules and never affects ghost pieces.

`bloom` adds an additive glow post-process to the active playfield only
(solo and co-op): a restrained blurred highlight layer is added over the
sharp board image, so boards with bright piece colors or skins get a soft
retro glow. It is completely independent of dithering - it works with
`dither: none`, any pattern, or skins - and it accepts `false`/omitted
(off), `true` (the `0.8` default intensity), or an explicit number up to
`2.0`. It never affects ghost pieces, hold/next previews, the HUD, menus,
or background media. Theme switches and reloads apply or remove it
immediately during a run. Default off.

> **Breaking rename:** the retired dither names `checker`, `dots`,
> `scanlines`, and `noise` and the old `dither_bloom: true` flag are no
> longer valid. Old declarations are reported in the Settings status line
> and fall back to `none`/off; update them to the new dither names and the
> `bloom` property.

Backdrop layers stack like this: `theme.background` (plus theme media)
fills menu and settings screens, `game.background` (plus game media) fills
the viewport around the active playfield, and `board.bg` fills the
playfield itself. Each is themed independently.

## Validation and fallback

- Unknown selectors/properties, invalid colors/numbers, and duplicate
  declarations are reported in Settings > Display (status line) and ignored;
  only that token falls back to the default.
- The same applies to media problems: unsupported formats, paths escaping
  the theme folder, missing/unreadable files, and invalid video/font data
  are reported as warnings and the affected asset falls back to its color
  or built-in equivalent. The theme stays selectable.
- A file without a valid `theme { name: ... }` block, or with broken
  structure (unclosed braces), is rejected entirely and the game keeps the
  Modern Neon Arcade look.
- If the selected theme disappears or becomes invalid after a reload, the
  selection is repaired to Modern Neon Arcade, persisted, and the active
  run (if any) is left untouched.
- Editing an asset file and using **Reload Themes** picks the new content
  up, like edited `.theme` files.

## Starter theme (copy me)

```
theme {
  name: "My Theme";
  background: #090b1d;
  text: #f4f7ff;
  dim: #f4f7ff8c;
  accent: #39e6ff;
  // Optional: a menu background picture and a display font.
  // image: "assets/menu.png";
  // font: "assets/body.ttf";
}

game {
  background: #0d1226;
  // image: "assets/game.png";
  // fit: contain;
  // opacity: 0.85;
  // tint: #05080fc0;
}

menu {
  panel: #151a3d;
  focus: #b6ff4a;
}

board {
  border: #39e6ff;
  ghost_line: #39e6ff;
}

players {
  p1: #39e6ff;
  p2: #b6ff4a;
}

pieces {
  i: #39e6ff;
  // A skin instead of (or as fallback for) a color:
  // i: "assets/skins/i.png";
  // dither: bayer;
  // dither_strength: 0.4;
  // bloom: true;
  // bloom: 1.25;
}
```

Save it as `user://themes/my_theme.theme`, then reload themes in Settings
> Display and cycle the Theme row to try it.
