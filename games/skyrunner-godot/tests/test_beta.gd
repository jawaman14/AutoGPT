extends TestCase
## The beta build's version label and F12 feedback bundle.


func test_version_comes_from_the_project() -> void:
	check_eq(Beta.version(), ProjectSettings.get_setting("application/config/version"))
	check(Beta.label().begins_with("Skyrunner " + Beta.version()), Beta.label())


func test_feedback_bundle_holds_what_a_report_needs() -> void:
	var s := T.sess(5)
	T.idle(s, 0.5)
	s.say("a message the tester saw")
	var path := Beta.feedback_bundle(s, null, "the gear collapsed at QRY")
	check(path != "" and FileAccess.file_exists(path), "written: " + path)
	var zip := ZIPReader.new()
	check_eq(zip.open(ProjectSettings.globalize_path(path)), OK)
	check("info.json" in zip.get_files(), str(zip.get_files()))
	var info: Dictionary = JSON.parse_string(zip.read_file("info.json").get_string_from_utf8())
	zip.close()
	check_eq(info.system.version, Beta.version())
	check_eq(info.note, "the gear collapsed at QRY")
	check_eq(info.session.aircraft, s.aircraft_key)
	check(info.session.state.has("ias_kts"), "flight state")
	check(info.session.messages.any(func(m): return "a message the tester saw" in m), "recent messages")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	s.dispose()


func test_a_station_bundle_needs_no_session() -> void:
	var path := Beta.feedback_bundle(null)
	check(path != "" and FileAccess.file_exists(path), "written")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
