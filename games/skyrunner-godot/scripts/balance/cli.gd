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

var opts := {"workers": 4, "seeds": 3, "n": 200, "calibrated": true, "results": "sim-results", "out": "docs/BALANCE.md"}


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
		elif a in ["--results", "--out"]:
			opts[a.substr(2)] = args[i + 1]
			i += 1
		elif a == "--uncalibrated":
			opts["calibrated"] = false
		elif a in ["feasibility", "tactical", "strategic", "report", "all"]:
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
	var r := Strategic.run_matrix(opts["n"], null, cal, [], null, null, opts["workers"])
	for x in r:
		x.erase("history")
	_save("strategic", r)
	var v: float = Strategic.equilibrium(Strategic.matrix(r)[2])[2]
	print("%d seasons in %.1f s; equilibrium runner win %.3f" % [r.size(), _secs(t0), v])
	print(Py.json(Strategic.summary(r)))
	var abl := {}
	for mech in Strategic.ABLATIONS:
		var rr := Strategic.run_matrix(maxi(20, Py.idiv(opts["n"], 4)), null, cal, [mech], null, null, opts["workers"])
		abl[mech] = Strategic.equilibrium(Strategic.matrix(rr)[2])[2]
	_save("ablation", {"base": v, "without": abl})
	var shown := {}
	for k in abl:
		shown[k] = Py.round_n(abl[k], 3)
	print("ablations (equilibrium runner win without each mechanic): ", shown)


func cmd_report() -> void:
	print("wrote " + BalanceReport.write_report(_abs(opts["results"]), _abs(opts["out"])))
