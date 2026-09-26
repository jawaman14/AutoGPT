# Parity fixtures (frozen)

These JSON files are reference values produced once by the Python prototype (`../skyrunner/`,
archival) through `tools/reference/gen_*.py`. The parity tests (`test_*_parity.gd`, `test_police.gd`)
replay the same seeds in Godot, with the Godot-only rules switched off, and require bit-identical
results. They are frozen: the Godot game is the only game, and nothing here is regenerated in normal
work. Regenerate only if you deliberately change a rule the prototype shares, using the matching
`tools/reference/gen_*.py`.
