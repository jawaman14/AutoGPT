extends SceneTree
## godot --headless --script res://tests/run_tests.gd [-- filter]
## Runs every tests/test_*.gd; exit code is the number of failed tests.

func _init() -> void:
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		filter = args[0]
	var files: Array[String] = []
	for f in DirAccess.get_files_at("res://tests"):
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
			files.append(f)
	files.sort()
	var passed := 0
	var failed := 0
	var t0 := Time.get_ticks_msec()
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		var inst = script.new()
		var names: Array[String] = []
		for m in script.get_script_method_list():
			if m.name.begins_with("test_") and (filter == "" or filter in f or filter in m.name):
				if not names.has(m.name):
					names.append(m.name)
		for n in names:
			inst.current = "%s::%s" % [f.get_basename(), n]
			inst.failures.clear()
			inst.before_each()
			inst.call(n)
			if inst.failures.is_empty():
				passed += 1
			else:
				failed += 1
				for msg in inst.failures:
					printerr("FAIL ", msg)
	print("%d passed, %d failed in %.1f s" % [passed, failed, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(failed)
