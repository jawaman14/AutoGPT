# Skyrunner beta 0.9.0-beta.1: tester's guide

Thanks for flying. This is the first beta: everything in the game is in, the flight model is new,
and the balance is still being tuned. What we need most is to hear where it breaks, where it
confuses you and where it's no fun.

## Get it

Builds come from the CI run of the `claude/cargo-flight-game-2g413p` branch (GitHub → Actions →
**Skyrunner beta builds** → the latest green run → *Artifacts*): `skyrunner-linux`,
`skyrunner-windows`, `skyrunner-macos`. Or open the project folder in Godot 4.7 and press play.

| System | Run it |
|---|---|
| Windows 10/11 (x86_64) | Unzip, run `Skyrunner.exe`. SmartScreen may warn about an unknown publisher: *More info → Run anyway*. |
| Linux (x86_64) | Unzip, `chmod +x Skyrunner.x86_64`, run it. Keep `Skyrunner.pck` next to it. |
| macOS 11+ (Intel and Apple Silicon) | Unzip `Skyrunner.zip`. The app is not notarized: right-click → *Open* the first time, or `xattr -dr com.apple.quarantine Skyrunner.app`. |

A GPU with Vulkan (Linux/Windows) or Metal (macOS) is expected. On an old or missing GPU, start
it with `--rendering-driver opengl3` and use `--graphics low`.

**The first launch of a map takes a while** (up to a minute on a black screen) while the terrain
is generated; it is cached, so later launches are quick.

## What to try

1. **The story** (the default): Costa Brava, 1979. Chapter 1 teaches the basics: fly marijuana
   into the stash houses and put a dealer on a corner. Tick `Tutorial` in the lobby, or press
   `SHIFT+F10` in game, for lessons as you play.
2. **Flying.** The flight model is new in this beta (the game's own, replacing JSBSim). Take off
   heavy from the short strips, land on the hilltop quarry, fly a loaded Cessna at night. Does it
   feel like an aeroplane? Too twitchy, too sluggish, too easy?
3. **Open mode** (`--unlocks open`, or the lobby): every faction and system from the first minute,
   with a $10,000 float.
4. **Multiplayer**: host from the lobby; friends join as co-pilot, boss, police controller and
   more. The AI plays every seat nobody takes.
5. **Watch the AI** fly the career with `F3` in the air, or `--watch` on the command line.

`F1` shows every key in the 3D seat. `F8` rebinds keys and joystick axes (yokes, throttle
quadrants and pedals work).

## Reporting a problem

Press **F12** at the moment something goes wrong. It saves a zip with:
- the build and your machine;
- what was happening (the aircraft's state and the last messages);
- the log and a screenshot.

It then opens the folder the zip is in:

| System | Folder |
|---|---|
| Windows | `%APPDATA%\Godot\app_userdata\Skyrunner\feedback\` |
| Linux | `~/.local/share/godot/app_userdata/Skyrunner/feedback/` |
| macOS | `~/Library/Application Support/Godot/app_userdata/Skyrunner/feedback/` |

Send us the zip with a line on what you expected and what happened. Nothing personal is in it,
and you can open it and check. The saves live one folder up (`story.json`, `save.json`), if we
ask for one.

## Known rough edges

- The flight model is new. The C172 is calibrated to its handbook; the other aircraft are
  plausible but less checked. Hands off at high power, some roll slowly left (propeller torque),
  as real ones do.
- The balance was measured with the old flight model, and a re-run is under way. Expect money
  and police odds to shift between beta builds.
- Text-to-speech (the read-aloud option) needs the OS speech service; on Linux that is
  speech-dispatcher.
- Rendering without a GPU (llvmpipe) works but is slow.
- The version is shown at the bottom right of the screen: please quote it in reports.
