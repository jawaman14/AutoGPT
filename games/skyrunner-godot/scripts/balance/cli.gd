extends SceneTree
## Balance tooling CLI (port of `python -m skyrunner.sim`).
##
##   godot --headless --script res://scripts/balance/cli.gd -- feasibility    # aircraft x strip x load, flown by the bot
##   godot --headless --script res://scripts/balance/cli.gd -- tactical --seeds 3
##   godot --headless --script res://scripts/balance/cli.gd -- strategic --n 200
##   godot --headless --script res://scripts/balance/cli.gd -- report     # rebuild docs/BALANCE.md
##   godot --headless --script res://scripts/balance/cli.gd -- all
##
## Options: --workers N (default 4), --seeds N (3), --n N (200), --uncalibrated,
## --results DIR (sim-results), --out FILE (docs/BALANCE.md).
## Results are saved as JSON under sim-results/ so the report can be rebuilt
## without re-flying anything. `worker <kind> <in> <out>` is internal (WorkerPool).

var opts := {"workers": 4, "seeds": 3, "n": 200, "calibrated": true, "results": "sim-results", "out": "docs/BALANCE.md",
	"grid": "", "rules": ""}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 4 and args[0] == "worker":
		WorkerPool.serve(args[1], args[2], args[3])
		quit(0)
		return
	var what := ""
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if a in ["--workers", "--seeds", "--n"]:
			opts[a.substr(2)] = int(args[i + 1])
			i += 1
		elif a in ["--results", "--out", "--grid", "--rules"]:
			opts[a.substr(2)] = args[i + 1]
			i += 1
		elif a == "--uncalibrated":
			opts["calibrated"] = false
		elif a in ["feasibility", "tactical", "strategic", "report", "all", "tune"]:
			what = a
		else:
			printerr("unknown argument " + a)
			quit(2)
			return
		i += 1
	if what == "":
		print("usage: cli.gd -- feasibility|tactical|strategic|report|all [--workers N] [--seeds N] [--n N]")
		quit(2)
		return
	var steps := ["feasibility", "tactical", "strategic", "report"] if what == "all" else [what]
	for s in steps:
		call("cmd_" + s)
	quit(0)


func _abs(p: String) -> String:
	return p if p.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(p)


func _save(name: String, data) -> void:
	var d := _abs(opts["results"])
	DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(d.path_join(name + ".json"), FileAccess.WRITE)
	f.store_string(Py.json(data))
	f.close()


func _load(name: String):
	var p := _abs(opts["results"]).path_join(name + ".json")
	return JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null


func _secs(t0: int) -> float:
	return (Time.get_ticks_msec() - t0) / 1000.0


func cmd_feasibility() -> void:
	var t0 := Time.get_ticks_msec()
	var r := Feasibility.sweep(opts["workers"])
	_save("feasibility", r)
	print(Feasibility.table(r))
	print("%d trials in %.0f s" % [r.size(), _secs(t0)])


func cmd_tactical() -> void:
	var t0 := Time.get_ticks_msec()
	var r := Tactical.sweep(opts["seeds"], opts["workers"])
	_save("tactical", r)
	var cal := Tactical.calibrate(r)
	_save("calibration", cal.to_dict())
	print("%d flights in %.0f s; calibration: %s" % [r.size(), _secs(t0), BalanceReport.cal_repr(cal)])


func cmd_strategic() -> void:
	var cal: HQ.Calibration = null
	var c = _load("calibration") if opts["calibrated"] else null
	if c is Dictionary:
		cal = HQ.Calibration.from_dict(c)
	var t0 := Time.get_ticks_msec()
	var rules = JSON.parse_string(opts["rules"]) if opts["rules"] != "" else null
	var r := Strategic.run_matrix(opts["n"], rules, cal, [], null, null, opts["workers"])
	for x in r:
		x.erase("history")
	_save("strategic", r)
	var v: float = Strategic.equilibrium(Strategic.matrix(r)[2])[2]
	print("%d seasons in %.1f s; equilibrium runner win %.3f" % [r.size(), _secs(t0), v])
	print(Py.json(Strategic.summary(r)))
	var abl := {}
	for mech in Strategic.ABLATIONS:
		var rr := Strategic.run_matrix(maxi(20, Py.idiv(opts["n"], 4)), rules, cal, [mech], null, null, opts["workers"])
		abl[mech] = Strategic.equilibrium(Strategic.matrix(rr)[2])[2]
	# the cartel as a whole: the same matrix with rivals off
	var off := {"rivals": false}
	if rules is Dictionary:
		off.merge(rules)
		off["rivals"] = false
	var r0 := Strategic.run_matrix(maxi(20, Py.idiv(opts["n"], 4)), off, cal, [], null, null, opts["workers"])
	abl["cartel"] = Strategic.equilibrium(Strategic.matrix(r0)[2])[2]
	_save("ablation", {"base": v, "without": abl})
	_save("rivals", Strategic.rival_summary(r))
	var shown := {}
	for k in abl:
		shown[k] = Py.round_n(abl[k], 3)
	print("ablations (equilibrium runner win without each mechanic): ", shown)


## Grid search over rule values: --grid '{"retire_target": [40000, 45000], "rival_market": [0.3, 0.4]}'
## Prints each combination's equilibrium and how evenly the endings spread.
func cmd_tune() -> void:
	var grid = JSON.parse_string(opts["grid"]) if opts["grid"] != "" else {}
	var base = JSON.parse_string(opts["rules"]) if opts["rules"] != "" else {}
	var cal: HQ.Calibration = null
	var c = _load("calibration") if opts["calibrated"] else null
	if c is Dictionary:
		cal = HQ.Calibration.from_dict(c)
	var combos := [{}]
	for k in grid:
		var nxt := []
		for combo in combos:
			for v in grid[k]:
				var d: Dictionary = combo.duplicate()
				d[k] = v
				nxt.append(d)
		combos = nxt
	var rows := []
	for combo in combos:
		var rules: Dictionary = base.duplicate()
		rules.merge(combo, true)
		var r := Strategic.run_matrix(opts["n"], rules, cal, [], null, null, opts["workers"])
		var eq := Strategic.equilibrium(Strategic.matrix(r)[2])
		var ends := Strategic.endings(r)
		var worst: float = ends.values().min()
		var p: Array = eq[0]
		var q: Array = eq[1]
		var mix := "%d/%d" % [Py.count(p, func(x): return x > 0.01), Py.count(q, func(x): return x > 0.01)]
		rows.append([absf(eq[2] - 0.5) + maxf(0.0, 0.08 - worst), combo, eq[2], worst, mix, ends])
		print("%s  eq %.3f  rarest ending %.3f  mix %s" % [JSON.stringify(combo), eq[2], worst, mix])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	print("\nbest:")
	for row in rows.slice(0, 5):
		print("  %s  eq %.3f  rarest %.3f  mix %s  %s" % [JSON.stringify(row[1]), row[2], row[3], row[4], JSON.stringify(row[5])])


func cmd_report() -> void:
	print("wrote " + BalanceReport.write_report(_abs(opts["results"]), _abs(opts["out"])))
