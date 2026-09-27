# Parity fixtures (frozen)

These JSON files are reference values produced once by the Python prototype (`../skyrunner/`,
archival) through `tools/reference/gen_*.py`. The parity tests (`test_*_parity.gd`, `test_police.gd`)
replay the same seeds in Godot, with the Godot-only rules switched off, and require bit-identical
results. They are frozen: the Godot game is the only game, and nothing here is regenerated in normal
work. Regenerate only if you deliberately change a rule the prototype shares, using the matching
`tools/reference/gen_*.py`.

## Flight golden (`flight_golden.json`)

One exception: everything that *flies* (the take-off roll in `test_core_parity.gd`, the seeded bot
flight in `test_bots_parity.gd`, the tactical and feasibility trials in `test_trials_parity.gd`) is
checked against `flight_golden.json` instead. The Python prototype flew JSBSim; the game now flies
its own flight model (`scripts/sim/flight/`), which can't match JSBSim bit for bit. These values
come from the Godot game itself (`godot --headless --script tools/regen_flight_golden.gd`) and pin
the flight model and the bot down as a determinism check. Regenerate them only when you
deliberately change the flight model, the aircraft data or the pilot bot, and say so in the commit.
The trial inputs still come from `trials_ref.json`, and the Python `fm`/`flight` entries in
`core_ref.json` and `bots_ref.json` are kept as history.
