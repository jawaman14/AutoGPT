class_name Beta
extends RefCounted
## Beta-test helpers: the version shown on every screen, and F12's feedback
## bundle, one zip a tester can send back: what machine, what build, what was
## happening (the session's state and recent messages), the log and a
## screenshot. Written to user://feedback/ and shown in the file manager.

const FEEDBACK_DIR := "user://feedback"


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


static func label() -> String:
	return "Skyrunner %s%s" % [version(), " (beta)" if OS.has_feature("beta") and not version().contains("beta") else ""]


## What the bundle says about the machine and the build.
static func system_info() -> Dictionary:
	var vp: Window = (Engine.get_main_loop() as SceneTree).root if Engine.get_main_loop() is SceneTree else null
	return {
		"version": version(),
		"godot": Engine.get_version_info().get("string", ""),
		"os": OS.get_name(), "os_version": OS.get_version(), "distro": OS.get_distribution_name(),
		"cpu": OS.get_processor_name(), "cores": OS.get_processor_count(),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"gpu": RenderingServer.get_video_adapter_name(), "gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"screen": str(DisplayServer.screen_get_size()) if DisplayServer.get_name() != "headless" else "headless",
		"window": str(vp.size) if vp != null else "",
		"locale": OS.get_locale(),
		"time_utc": Time.get_datetime_string_from_system(true),
		"debug_build": OS.is_debug_build(),
	}


## What was going on: enough to reproduce a report, nothing personal.
static func session_info(s: Session) -> Dictionary:
	if s == null:
		return {}
	var st := s.state
	var d := {
		"mode": s.mode, "phase": s.phase, "time_s": s.time, "money": s.money, "aircraft": s.aircraft_key,
		"location": s.location, "map_seed": s.map_seed, "features": s.features.keys(),
		"messages": s.messages.slice(-30).map(func(m): return str(m)),
	}
	if st != null:
		d["state"] = {"x": st.x, "y": st.y, "alt": st.alt, "agl": st.agl, "heading": st.heading,
			"ias_kts": st.ias_kts, "vs_fpm": st.vs_fpm, "fuel_lb": st.fuel_lb, "weight_lb": st.weight_lb,
			"on_ground": st.on_ground}
	return d


## Write the bundle; returns its path ("" on failure). `note` is the tester's words, if any.
static func feedback_bundle(s: Session, viewport: Viewport = null, note := "") -> String:
	DirAccess.make_dir_recursive_absolute(FEEDBACK_DIR)
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "").replace("T", "-")
	var path := "%s/skyrunner-feedback-%s.zip" % [FEEDBACK_DIR, stamp]
	var zip := ZIPPacker.new()
	if zip.open(ProjectSettings.globalize_path(path)) != OK:
		return ""
	_add(zip, "info.json", JSON.stringify({"system": system_info(), "session": session_info(s), "note": note}, "  ").to_utf8_buffer())
	var log_path := str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
	if FileAccess.file_exists(log_path):
		var text := FileAccess.get_file_as_string(log_path)
		_add(zip, "godot.log", text.right(400000).to_utf8_buffer())  # the tail is what matters
	if viewport != null and DisplayServer.get_name() != "headless":
		var img := viewport.get_texture().get_image()
		if img != null:
			_add(zip, "screenshot.png", img.save_png_to_buffer())
	zip.close()
	return path


static func _add(zip: ZIPPacker, name: String, data: PackedByteArray) -> void:
	zip.start_file(name)
	zip.write_file(data)
	zip.close_file()


## F12 from any seat: write the bundle and show it.
static func report(s: Session, viewport: Viewport) -> String:
	var path := feedback_bundle(s, viewport)
	if path != "" and DisplayServer.get_name() != "headless":
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
	return path
