# Skyrunner

A bush-flying cargo game built on **[JSBSim](https://github.com/JSBSim-Team/jsbsim)**, the open-source
flight dynamics engine used by FlightGear and many research simulators, with a
**[Panda3D](https://www.panda3d.org/)** 3D front-end.

You fly real JSBSim aircraft models (Cessna 172P, Cessna 182, Piper PA-28, Cessna 310, DHC-6 Twin Otter)
around a procedurally generated island. You take jobs, load passengers and cargo, balance
the aircraft, and get into short strips on cliff tops, in quarries and on beaches. Some jobs are
illegal: radar picks you up if you fly high, the police send helicopters and interceptors after you,
and rival smugglers try to take your cargo.

The weight and balance side isn't faked with a stat bar. Every passenger, bag and crate is fed to JSBSim
as a point mass at its real station arm. Overload the Cessna and the takeoff roll grows, the climb goes
flat, and the landing roll gets longer. Put everything in the baggage bay and the CG goes aft, and the
aircraft pitches up and wants to stall. The test suite checks both effects.

| Approach to Eagle's Nest (280 m mesa strip) | Job board | Police on your tail |
|---|---|---|
| ![approach](docs/approach-eagles-nest.png) | ![jobs](docs/job-board.png) | ![police](docs/police-chase.png) |

*(Screenshots from Panda3D's software renderer in a headless CI box. With a GPU you get lighting and multisampling.)*

## Quick start

```bash
cd games/skyrunner
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python -m skyrunner            # add --new to wipe the save
python -m pytest -q tests      # 46 headless tests, ~3 s
```

Requirements: Python 3.10+ and any GPU with OpenGL 2.1 or newer. On first launch the game builds a
patched copy of the JSBSim aircraft data in your temp directory (see *How JSBSim is used*).
Progress is saved to `~/.skyrunner/save.json` whenever you park at an airfield and when you quit.

## Controls

| | Keys |
|---|---|
| Pitch | `W`/`S` or `↑`/`↓` (S / ↓ = nose up) |
| Roll | `A`/`D` or `←`/`→` |
| Rudder / nosewheel | `Q`/`E` |
| Throttle | `R`/`F` or `PgUp`/`PgDn` (hold) · `X` cut · `Z` full |
| Flaps | `G` down a notch · `T` up a notch |
| Trim | `[` nose down · `]` nose up |
| Brakes | `B` or `Space` |
| Mouse yoke | `Y` toggles it: mouse position becomes the stick (much smoother than keys) |
| Camera | `C` cycles chase / cockpit / tower |
| Map | `M` enlarges the minimap |
| Ground menus | `J` job board · `L` load planner & fuel · `H` hangar / dealer |
| Other | `P` pause · `F1` help · `Enter` continue after a crash or bust · `Esc` close menu / save & quit |

A flight stick or gamepad is picked up automatically if one is connected (stick = pitch/roll,
twist or right stick = rudder, throttle axis or triggers = power). I haven't tested this path on
real hardware; the keyboard and mouse are the tested inputs.

## How to play

1. **Pick jobs** (`J`) while stopped at an airfield. Each job shows payout, weight, passenger count,
   distance, the destination's strip length, and a rough landing-roll estimate at your new weight.
2. **Load the aircraft** (`L`). The ramp crew puts everything in the first free spot from the front,
   which is often wrong. Move each item between stations with `←`/`→` and watch the CG envelope
   chart. `+`/`-` adds or drains fuel ($1.10/lb). Fuel is weight, so don't fill the tanks for a 10 km hop.
   `A` hires a loadmaster ($150) who balances the load for you. You can't leave with cargo still on the ramp.
3. **Fly it.** Green light columns mark both ends of each destination runway. Near a runway the
   HUD shows PAPI lights (2 white + 2 red = on a 3.5° path) plus the strip size and distance.
4. **Land and stop on the strip.** Delivery happens when you come to a full stop. Pay is adjusted for
   lateness (medical jobs have deadlines), broken fragile cargo (hard touchdowns), unhappy VIPs
   (banks over 45° or hard landings), and gets a bonus for smooth landings under 150 fpm.
5. **Buy bigger aircraft** at Port Harbor or Valley Regional (`H`).

### What kills you
- Touchdown sink rate above the gear limit (700 fpm for the 172, 25% lower when overweight)
- Leaving the strip above 15 kt, dragging a wingtip, nosing over, ditching, trees, terrain
- Crash cost: repairs (12% of the aircraft's price, minimum $2,500) plus every job on board. You respawn at the field you left from.

### The law
- **Hot cargo** (contraband, fugitives) triggers radar checks. Harbor (22 km) and Valley (12 km) radars
  are the red rings on the map. You're invisible below the radar floor (roughly 45 m AGL + 9 m per km of
  range) or when terrain blocks line of sight to the radar mast.
- Radar contact builds **suspicion**. At 100%, police dispatch a helicopter (wanted ★). Staying in
  view of police for 60 s escalates: an interceptor at ★★, a second one at ★★★.
- If a police unit stays within 350 m of you for about 5 s, you're **busted**: fine, cargo seized, and you
  restart at Harbor. Landing while a police unit is within 2.5 km, or landing at a police field while
  wanted, also gets you busted. Landing at a police field with hot cargo carries a 35% inspection chance.
- **Escape:** break line of sight (fly low, use the ridge) and stay unseen for 15 s + 12 s per wanted level
  to drop a star. Pursuers only check terrain straight ahead, so a tight canyon can make them hit the wall.
- **Rival smugglers** (black twin) may show up when you carry more than $2,000 of contraband. If they stay
  within 250 m for about 7 s, you have to jettison the goods.

## World

A 32 × 32 km island with a mountain ridge through the north:

| Code | Name | Strip | Notes |
|---|---|---|---|
| HAR | Port Harbor Intl | 1800 × 45 m asphalt | Hub, dealer, police HQ, 22 km radar |
| VAL | Valley Regional | 1000 × 30 m asphalt | Dealer, police, 12 km radar |
| FRM | Miller's Farm | 480 × 20 m grass | |
| ISL | Isla Verde | 550 × 20 m grass | Offshore island |
| PNR | Pine Ridge | 380 × 15 m gravel | One-way hillside strip: land uphill, no go-around, trees at both ends |
| EGL | Eagle's Nest | 280 × 14 m dirt | Mesa top at 1150 m with cliffs on every side |
| COV | Smuggler's Cove | 320 × 18 m sand | Beach, shady jobs |
| QRY | Old Quarry | 240 × 12 m dirt | Trench cut into the hillside, walls on both sides, shady jobs |

Measured JSBSim ground rolls with full flaps and max braking are about 140 m (172), 190 m (C310)
and 210 m (Twin Otter near MTOW). The short strips are possible, but only if you touch down near
the threshold at the right speed.

## Architecture

```
skyrunner/
  aircraft.py      roster: JSBSim model, load stations (arms), CG envelope, MTOW, visuals
  jsbsim_patch.py  builds a patched JSBSim root with one <pointmass> per station
  fdm.py           FGFDMExec wrapper: local ENU <-> lat/lon, controls, terrain feed, crash hook
  loadout.py       weight & balance math, envelope checks, loadmaster auto-balance
  world.py         seeded island heightmap, airfields (flattened/plateau/pit/beach), trees, LOS
  jobs.py          job board generation and pricing
  police.py        radar model, wanted levels, kinematic pursuer AI (police + rivals)
  controls.py      key/axis -> smoothed control surface commands
  game.py          Session: economy, loading rules, flight rules, delivery, save/load  (no rendering)
  render/          Panda3D: procedural meshes, HUD, menus, cameras, input
tests/             headless pytest suite (physics, W&B, world, police, full session loop)
```

`game.Session` never imports Panda3D, so the whole game loop runs headless. That covers tests,
scripted bots, and a future dedicated server.

### How JSBSim is used
- **Aircraft**: stock JSBSim XML models, shipped with the `jsbsim` pip wheel.
- **Load stations**: JSBSim fixes the number of point masses when it loads a model, but the models
  declare between 1 and 5. `jsbsim_patch.build_patched_root` mirrors the JSBSim data dir with symlinks
  and rewrites each aircraft's `<mass_balance>` so it has one `<pointmass>` per game station. At runtime
  the game writes `inertia/pointmass-weight-lbs[i]` and `propulsion/tank[i]/contents-lbs`. The load
  planner's predicted weight and CG match JSBSim's `inertia/weight-lbs` and `inertia/cg-x-in` to within
  0.2 in for every aircraft (`tests/test_loadout.py`).
- **Terrain**: JSBSim treats the ground as a flat plane. Every 1/120 s substep the game sets
  `position/terrain-elevation-asl-ft` to the island height under the aircraft. If that height would
  bury the gear (rising terrain arrives as a step), the game calls it a CFIT crash instead of letting
  the gear springs blow up.
- **Sign conventions** (verified in tests): `+rudder-cmd-norm` yaws the nose left (FlightGear negates it
  too), `+steer-cmd-norm` turns the nosewheel right, and `+elevator-cmd-norm` is nose down. The C310
  model has no nosewheel steering, so its pedals drive differential braking instead.
- **Speed**: one aircraft runs at hundreds of times real time. A full game frame with three
  pursuers costs about 2.5 ms.

## Roadmap / known gaps
- Art: every model is procedural and vertex-coloured. Swap in glTF models via `panda3d-gltf`.
  The FlightGear aircraft 3D models (GPL) would fit, since they share JSBSim's structural frame.
- Audio: none yet. An engine note from `propulsion/engine/engine-rpm`, a siren, and a stall horn are the obvious first three.
- Weather: JSBSim's atmosphere and wind (`atmosphere/wind-*`, turbulence) aren't used yet. Crosswind on
  the one-way strips would be a good difficulty knob.
- Police are kinematic, not JSBSim. They could run as JSBSim instances (`ah1s` helicopter, `pc7`) for
  honest performance limits.
- Taildraggers (J-3 Cub) are omitted because the JSBSim Cub needs a tail-up technique that doesn't work well on a keyboard.
- Gamepad and joystick mapping hasn't been tested on hardware.
