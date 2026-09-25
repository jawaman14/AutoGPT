extends SceneTree
## Quick balance probe: the equilibrium win rate for one rule set.
##   godot --headless --script res://tools/equilibrium.gd -- <n per cell> '<rules json>' [workers]
## Prints "EQ <equilibrium> raw <raw win rate> endings {...}". Uses sim-results/calibration.json.

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]) if a.size() > 0 else 250
	var rules = JSON.parse_string(a[1]) if a.size() > 1 and a[1] != "" else {}
	var workers := int(a[2]) if a.size() > 2 else 4
	var c = JSON.parse_string(FileAccess.get_file_as_string("res://sim-results/calibration.json"))
	var cal := HQ.Calibration.from_dict(c) if c is Dictionary else null
	var r := Strategic.run_matrix(n, rules, cal, [], null, null, workers)
	var s := Strategic.summary(r)
	var e: float = Strategic.equilibrium(Strategic.matrix(r)[2])[2]
	print("EQ %.3f raw %.3f endings %s" % [e, s["runner_win"], Py.json(Strategic.endings(r))])
	quit()
