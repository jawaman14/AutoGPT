class_name WorkerPool
extends RefCounted
## Process-pool map for the balance simulators (Python used ProcessPoolExecutor).
##
## JSBSim keeps process-wide state, so trials run in separate headless Godot
## processes rather than threads. The job list is cut into ordered chunks; each
## chunk goes to `cli.gd -- worker <kind> <in.bin> <out.bin>` and the results
## come back in job order. Jobs and results travel as Godot binary variants:
## exact doubles, and ints stay ints (JSON would round-trip neither).

const CHUNKS_PER_WORKER := 3


static func run_one(kind: String, job: Array) -> Dictionary:
	match kind:
		"strategic":
			var r := Strategic.run_job(job)
			r.erase("history")  # the saved results never keep it; saves a lot of JSON
			return r
		"tactical":
			return Tactical.run_job(job)
		"feasibility":
			return Feasibility.run_job(job)
	push_error("unknown job kind " + kind)
	return {}


static func _tmp_dir() -> String:
	var d := OS.get_user_data_dir().path_join("pool")
	DirAccess.make_dir_recursive_absolute(d)
	return d


static func map(kind: String, jobs: Array, workers: int) -> Array:
	if jobs.is_empty():
		return []
	var per := 1 if kind == "strategic" else CHUNKS_PER_WORKER  # seasons are cheap and uniform: start-up dominates
	var n_chunks := mini(jobs.size(), maxi(1, workers) * per)
	var size := ceili(float(jobs.size()) / n_chunks)
	var chunks := []
	for i in range(0, jobs.size(), size):
		chunks.append(jobs.slice(i, i + size))
	var tmp := _tmp_dir()
	var tag := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var paths := []
	for i in chunks.size():
		var inp := tmp.path_join("%s_%s_%d_in.bin" % [kind, tag, i])
		var outp := tmp.path_join("%s_%s_%d_out.bin" % [kind, tag, i])
		var f := FileAccess.open(inp, FileAccess.WRITE)
		f.store_buffer(var_to_bytes(chunks[i]))
		f.close()
		paths.append([inp, outp])
	var exe := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var running := {}  # pid -> chunk index
	var next := 0
	var done := 0
	var failed := []
	while done < chunks.size():
		while running.size() < workers and next < chunks.size():
			var args := ["--headless", "--path", project, "--script", "res://scripts/balance/cli.gd", "--",
				"worker", kind, paths[next][0], paths[next][1]]
			var pid := OS.create_process(exe, args)
			if pid <= 0:
				failed.append(next)
				done += 1
			else:
				running[pid] = next
			next += 1
		OS.delay_msec(50)
		for pid in running.keys():
			if not OS.is_process_running(pid):
				running.erase(pid)
				done += 1
	var out := []
	for i in chunks.size():
		var got = null
		if FileAccess.file_exists(paths[i][1]):
			got = bytes_to_var(FileAccess.get_file_as_bytes(paths[i][1]))
		if not (got is Array) or got.size() != chunks[i].size():
			# a worker died: run its chunk here so no job goes missing
			push_warning("worker chunk %d of %s failed; running it in-process" % [i, kind])
			got = chunks[i].map(func(j): return run_one(kind, j))
		out.append_array(got)
		DirAccess.remove_absolute(paths[i][0])
		if FileAccess.file_exists(paths[i][1]):
			DirAccess.remove_absolute(paths[i][1])
	return out


## Entry point inside a worker process.
static func serve(kind: String, inp: String, outp: String) -> void:
	var jobs = bytes_to_var(FileAccess.get_file_as_bytes(inp))
	var res := []
	for j in jobs:
		res.append(run_one(kind, j))
	var tmpf := outp + ".part"
	var f := FileAccess.open(tmpf, FileAccess.WRITE)
	f.store_buffer(var_to_bytes(res))
	f.close()
	DirAccess.rename_absolute(tmpf, outp)
