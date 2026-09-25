# Porting Skyrunner from Python/Panda3D to Godot 4

The Python game (`games/skyrunner/`) was ported module by module to Godot 4.4 (GDScript plus a small
C++ GDExtension). Every simulation module was checked against the Python original by running both on
the same seeds and comparing the output. This file explains how that was done, what matched exactly,
what didn't and why, and the traps along the way.

## What went where

| Python | Godot | Notes |
|---|---|---|
| `jsbsim` (pip wheel) | `native/src/jsbsim_fdm.*` | JSBSim 1.3.1 built from source by CMake (FetchContent), same version as the wheel |
| `random.Random` | `native/src/rng.*` `PyRandom` | Bit-exact CPython MT19937: `seed` (int and float via `_Py_HashDouble`), `random`, `uniform`, `randint`, `getrandbits`, `gauss`, `shuffle`, `choice`, `choices` |
| `numpy.random.default_rng` | `NpRandom` | SeedSequence + PCG64 `random`/`uniform` (terrain) |
| `world.py` terrain (numpy) | `native/src/terrain.*` | Island generator, heights, trees, line of sight, in C++ for speed and float32 fidelity |
| `math.hypot`, `round`, `f"{x:.2f}"` | `native/src/pymath.*` `PyMath` | CPython's own `vector_norm`, round-half-even, formatting, `repr` |
| `world, aircraft, loadout, fdm, autopilot, controls, jobs, events, roles, comms` | `scripts/sim/*.gd` | |
| `sensors, police, maritime, ai_smuggler, game (Session)` | `scripts/sim/*.gd` | `Session(**kw)` becomes `Session.new(opts_dict)` |
| `hq, nights, layers, campaign` | `scripts/sim/*.gd` | |
| `bots/pilot, route, autorun, hq` | `scripts/bots/*.gd` | numpy `arange`/`maximum`/`where` became explicit loops in the same order |
| `sim/feasibility, tactical, strategic, report, __main__` | `scripts/balance/*.gd` | `ProcessPoolExecutor` became headless Godot worker processes (`worker_pool.gd`) |
| `net/server, client, snapshot` | `scripts/net/*.gd` | Same line-JSON protocol: a Python station can join a Godot host and vice versa |
| `render/*`, `station.py`, `__main__.py` | `scripts/render`, `scripts/ui`, `scripts/station`, `scripts/game`, `scripts/main.gd` | Rebuilt for Godot, with the graphics overhaul and new menus |
| `tests/*.py` (pytest) | `tests/test_*.gd` | A small runner (`tests/run_tests.gd`, `tools/test.sh`) |

## How parity was checked

For each module, a generator under `tools/reference/` runs the Python game and writes a JSON fixture:

| Fixture | Generator | Checked by | Result |
|---|---|---|---|
| `core_ref.json` | `gen_core.py` | `test_core_parity.gd` | Mass data, auto-balance and seeded job boards exact; a 10 s JSBSim take-off roll matches to 1e-12 |
| `session_ref.json` | `gen_session.py` | `test_session_parity.gd` | 300 s police-mode world exact at every minute; all 40 HQ bot pairings exact |
| `bots_ref.json` | `gen_bots.py` | `test_bots_parity.gd` | Route plans, approaches and departures for every strip exact; a 700 s bot flight HAR→VAL within 1e-7 |
| `strategic_ref.json` | `gen_strategic.py` | `test_strategic.gd` | Seasons, win matrix, equilibrium, dominance, summary and action values exact. At n=200 the calibrated equilibrium is 0.497361506980898 in both |
| `trials_ref.json` | `gen_trials.py` | `test_trials_parity.gd` | Seeded feasibility and tactical trials reproduce Python's outcome and every flag; the numbers match except on the one chaotic trial (see below) |

Re-generate a fixture with `python3 tools/reference/gen_<name>.py` (from `games/skyrunner` with its
virtualenv active).

## Lessons (the traps)

1. **Godot's `Vector2`/`Vector3` are float32.** Simulation state uses plain `float` (float64) and Arrays.
   Vectors appear only in rendering.
2. **numpy 2 float32 promotion.** `world.height()` interpolates a float32 grid, and numpy 2 keeps the
   result in float32 where numpy 1 promoted it. The native terrain reproduces the float32 path exactly
   (`height`), with `height64` alongside.
3. **`math.hypot` isn't `libm` `hypot`.** CPython uses its own `vector_norm` (scaled, with a correction
   step). It differs from glibc in about 0.6% of inputs, enough to change a branch eventually. Ported as
   `PyMath.hypot`/`hypot3`.
4. **GDScript float literals can be 1 ulp off.** Tests compare with a relative tolerance where a literal
   is involved. Constants that matter are computed, not typed.
5. **FMA contraction.** The GDExtension is built with `-ffp-contract=off`, or the compiler fuses
   multiply-adds that Python evaluates separately.
6. **Run `--import` before headless runs.** Without it a `--script` run can stall on an unresolved
   `class_name` instead of failing. `tools/test.sh` imports first.
7. **Runtime script errors don't abort.** GDScript logs a `SCRIPT ERROR` and carries on with `null`, so
   a broken test can "pass". `tools/test.sh` fails the run on any `SCRIPT ERROR` in the output.
8. **`JSON.stringify` loses precision, even with `full_precision`.** On Godot 4.4 it writes 15
   significant digits, and `String.num(v, 17)` and `String.to_float()` aren't correctly rounded either
   (about 40% of doubles don't survive a round trip). The fixes:
   - `PyMath.repr`/`parse` in C++ (`%.17g` shortest round-trip, `strtod`)
   - `Py.json()` for saved results
   - binary `var_to_bytes` for worker IPC
9. **Methods aren't properties.** `wb.ok` on a method returns a `Callable`, which is always truthy.
   GDScript won't warn. It hid a bug where the AutoRunner never hired a loadmaster.
10. **`bool()` only takes numbers, and truthiness differs.** `Py.truthy()` gives Python semantics for
    `None`, empty containers and strings.
11. **Monkeypatching has no equivalent.** Python tests replaced `police.tick` and the ablations replaced
    `season._r_bribe`. The port has explicit switches instead: `PoliceSystem.frozen` and
    `HQ.Season.disabled`.
12. **Stable sorts and first-wins min/max.** `sort_custom` isn't stable, and Python's `min(key=)` keeps
    the first minimum. `Py.sorted_by`, `Py.min_by` and `Py.max_by` reproduce both.
13. **Tests must start after the SceneTree is the main loop.** Nodes added during `_init` or
    `_initialize` aren't inside the tree. The runner starts on the first `_process` frame.

## Where exact parity stops

- **JSBSim builds differ by ulps.** The pip wheel and the CMake build disagree in the last bits of
  `position/long-gc-deg` now and then (compiler and libm). Most flights never notice. A flight that
  passes close to a bot decision threshold amplifies it. The tipped north run is identical to 1e-12
  until t=88 s, then 0.7 mm apart at t=119 s, and ends in the same bust a minute later. Over the
  189-flight tactical sweep, 130 flights are identical. The rest diverge symmetrically: 109 vs 109
  flagged, 69 vs 69 delivered.
- **The calibration inherits that noise.** Each calibration cell has only 9 flights. The divergence
  above moved the fitted `intercept_k` from 2.0 to 1.3, and the season equilibrium from 45% to 69%.
  This is a real weakness of the original balance method, not of the port. The Godot balance run uses
  10 seeds per cell (630 flights).
- **The rival cartel is Godot-only.** With `rules.rivals` on, seasons can't be compared with Python.
  The parity tests run with `{"rivals": false}`. The cartel draws from its own random stream, so
  switching it off reproduces Python exactly.

## Deliberate changes from the plan

- **Networking uses TCP with the Python line-JSON protocol, not ENet.** Wire compatibility with the
  Python clients was worth more than ENet's features for 20 Hz snapshots. `test_net.gd` checks the raw
  wire format, and a Python `NetClient` was run against the Godot dedicated server.
- **Balance workers are processes, not threads.** JSBSim keeps process-wide state.
