extends SceneTree
## Bake the built-in maps' terrain into res://data/terrain, so no player waits
## for it (GDScript generation takes ~10 s a grid, the city map needs two).
## Re-run after any change to Terrain's generator (and bump CACHE_VERSION):
##
##   godot --headless --script tools/bake_terrain.gd


func _init() -> void:
	var dir := ProjectSettings.globalize_path(Terrain.BAKED_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".bin"):
			DirAccess.remove_absolute(dir.path_join(f))
	Terrain.bake_to = dir
	for map_seed in [MapCity.SEED, 0]:
		World.use_map(map_seed)
		World.new()
		print("baked map ", map_seed)
	for f in DirAccess.get_files_at(dir):
		print(f, " ", FileAccess.get_file_as_bytes(dir.path_join(f)).size())
	quit()
