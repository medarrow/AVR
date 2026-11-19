# AVR — Augmented Virtual Reality for WoW 1.12

Draw circles, cones, markers, arrows and freehand lines **on the 3D world** in the
vanilla (1.12) client. Use it to show raid positions, check spacing, mark where a
blink lands, or measure distances on the ground. You can share scenes with your
party or raid.

AVR is a from-scratch rewrite for 1.12, inspired by the
[original AVR](https://www.curseforge.com/wow/addons/avr) addon for Wrath of the
Lich King. It shares no code with the original.

## Requirements

The stock 1.12 client gives addons neither world positions nor the player's facing,
so AVR needs a client extension:

| Need | Provided by |
|---|---|
| Unit world positions (`UnitPosition`) | [SuperWoW](https://github.com/balakethelock/SuperWoW) and/or [ClassicAPI](https://github.com/brues-code/ClassicAPI) |
| Player facing (`GetPlayerFacing`) | ClassicAPI, or else the minimap arrow (stock) |
| Facing of other units (`UnitFacing`) | ClassicAPI (optional; for cones and arrows on other units) |

SuperWoW returns positions for players only. ClassicAPI also returns them for NPCs,
so marks on mobs need ClassicAPI.

## Installation

1. Download `AVR-<version>.zip` from the [Releases](https://github.com/medarrow/AVR/releases) page.
2. Extract it into `World of Warcraft\Interface\AddOns\`. The result should be
   `Interface\AddOns\AVR\AVR.toc`.
3. Restart the game, or log out to character select and back in.

## Usage

`/avr` opens the options window, where you can manage scenes and add, edit, pin and
remove marks. `/avr help` lists every command.

| Command | Effect |
|---|---|
| `/avr circle [radius] [unit\|here]` | Circle that follows a unit (default: you). `here` pins it to the ground. `fcircle` draws it filled. |
| `/avr cone [length] [angle] [unit]` | Cone in front of a unit |
| `/avr mark` | Marker on the ground where you stand |
| `/avr blink` | Marker 20 yards in front of you |
| `/avr range [radius]` | Circle around you that turns red when a group member is inside it |
| `/avr groupmarks [range]` | Hexagon under each nearby group member |
| `/avr draw`, `/avr measure` | Mouse tools: drag with the left button, right-click to finish |
| `/avr scene <name>` | Switch to a scene, creating it if needed |
| `/avr clear` | Empty the current scene |
| `/avr share` | Send the current scene to your party or raid |
| `/avr receive on\|off` | Accept or ignore scenes others share. Accepting always asks first. |
| `/avr on\|off` | Turn drawing on or off |
| `/avr status` | Show what AVR is reading from the client |

A unit can be a token (`player`, `target`, `party2`, `raid14`, `focus`,
`nameplate3`, a GUID) or a player's name.

### Calibration

AVR rebuilds the game camera from the saved-view cvars. Two values can't be read
exactly, so they are estimated:

- **Camera height:** the height of the point the camera orbits, above your feet.
  A per-race default is used. Newer ClassicAPI builds can report the exact value.
- **Field of view:** taken from the client's FoV setting.

To check them, stand on flat ground, type `/avr circle 5`, and orbit the camera
with the left mouse button:

- If the circle floats above or sinks below your feet, adjust **Camera height**.
- If the circle looks too big or too small for its radius, or slides across the
  ground as you tilt the camera, adjust **Vertical FoV**.
- If the circle swings the wrong way as you orbit, press **Flip yaw**.

**Auto** returns both values to the estimates.

## API for other addons

```lua
-- Red 8-yard circle around a unit for 5 seconds
local mesh = AVR:MarkUnit("raid12", 8, 5, 1, 0, 0)

-- Circle pinned where a unit stands now (or pass x, y, z)
AVR:MarkPosition("target", nil, nil, 10, 8)

-- Range warning around you
AVR:RangeWarning(10, 20)

-- Remove a mark early
AVR:RemoveTemp(mesh)
```

These marks are temporary: they are not saved and expire after the duration you
give.

## Limitations

- Everything is drawn on top of the world, so marks show through walls and units.
- Marks are flat, and look best on flat ground. Slopes and stairs throw them off.
- When a wall pushes the camera in, marks drift until the camera is free again.
- To read the camera, AVR saves the live view into **view slot 5** every frame
  while it is drawing. Anything you saved in view 5 yourself is overwritten.
  AVR doesn't touch the camera while it has nothing to draw.

## License

[MIT](LICENSE)
