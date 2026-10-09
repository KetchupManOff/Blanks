# Sound effects

Drop SFX assets here. Supported formats: `.ogg`, `.mp3`, `.wav`. Each
file's basename (without extension) becomes the sound name used by the
game code. Missing files are safe no-ops: the game runs silently and
never fails to start.

This folder currently ships with simple synthesized placeholder sounds
(one short blip per name below) so the audio wiring is audible out of
the box. Replace them with proper effects freely - they are original
waveforms with no licensing restrictions.

## Names used by the code

| Name          | Trigger                                              |
| ------------- | ---------------------------------------------------- |
| `menu_move`   | Menu/settings selection movement, value adjustment   |
| `menu_confirm`| Menu accept, settings commands, add/remove playlist  |
| `menu_back`   | Menu cancel/back                                     |
| `pause`       | Entering pause                                       |
| `move`        | Successful piece shift                               |
| `rotate`      | Successful piece rotation                            |
| `soft_drop`   | Soft-drop key press (once per press, not per frame)  |
| `hard_drop`   | Successful hard drop (also covers its lock)          |
| `hold`        | Successful hold swap                                 |
| `lock`        | Natural piece lock (lock delay expiry)               |
| `line_clear`  | Line clear (non-T-spin locks)                        |
| `tspin`       | Any T-spin lock, including T-spin line clears        |
| `level_up`    | Level increase                                       |
| `game_over`   | Run ends by topping out                              |
| `finish`      | Sprint finished (40 lines)                           |

All SFX play through the `SFX` bus; music plays through the `Music` bus;
both are affected by `Master`.
