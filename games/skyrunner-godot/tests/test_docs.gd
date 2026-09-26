extends TestCase
## The docs stand on their own: every relative link in the project's Markdown
## resolves inside the Godot project, and none points back at the archival
## Python prototype (only tools/reference and the fixtures' README may name it).

const DOCS := ["res://README.md", "res://docs/DESIGN.md", "res://docs/MULTIPLAYER.md", "res://docs/BALANCE.md",
	"res://docs/PORTING.md", "res://tests/fixtures/README.md"]


func _links(text: String) -> Array:
	var re := RegEx.new()
	re.compile("\\]\\(([^)#\\s]+)")
	var out := []
	for m in re.search_all(text):
		var l := m.get_string(1)
		if not (l.begins_with("http") or l.begins_with("mailto:")):
			out.append(l)
	return out


func test_relative_links_resolve() -> void:
	for d in DOCS:
		check(FileAccess.file_exists(d), d + " exists")
		var text := FileAccess.get_file_as_string(d)
		var base: String = d.get_base_dir()
		for l in _links(text):
			var p: String = base.path_join(l).simplify_path()
			check(FileAccess.file_exists(p) or DirAccess.dir_exists_absolute(p), "%s: link %s resolves" % [d.get_file(), l])


func test_nothing_links_to_the_python_prototype() -> void:
	for d in DOCS:
		if d.ends_with("fixtures/README.md"):
			continue
		for l in _links(FileAccess.get_file_as_string(d)):
			check(not l.contains("../skyrunner/"), "%s links %s" % [d.get_file(), l])
