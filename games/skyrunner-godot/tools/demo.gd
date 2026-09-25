extends SceneTree
## Split-screen demo: the pilot bot's 3D view (left) and the task-force desk
## (right) watching the same session, flying one of the tactical sim's seeded
## scenarios. Record with Godot's Movie Maker (fixed 30 fps = the sim's step):
##
##   xvfb-run godot --rendering-method gl_compatibility --write-movie out.avi --fixed-fps 30 \
##       --script res://tools/demo.gd -- <zone> <law> <tactic> <seed> [graphics] [max_s] [hour]
##
## tools/record_demo.sh wraps it and encodes an MP4.

var s: Session
var bot: PilotBot
var app: PilotApp
var desk: StationApp
var banner: Label
var ended_at := -1.0
var max_s := 900.0
var label := ""


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var zone: String = a[0] if a.size() > 0 else "west"
	var law: String = a[1] if a.size() > 1 else "all_in"
	var tactic: String = a[2] if a.size() > 2 else "evasive"
	var seed := int(a[3]) if a.size() > 3 else 101
	var graphics: String = a[4] if a.size() > 4 else "medium"
	max_s = float(a[5]) if a.size() > 5 else 900.0
	var hour := float(a[6]) if a.size() > 6 else 16.5
	var st = Tactical.setup_trial(zone, law, tactic, seed)
	s = st[0]
	bot = st[1]
	label = "%s route, police %s, tactic %s, seed %d" % [zone, law, tactic, seed]
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(ui)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 4)
	ui.add_child(h)
	var left := _pane(h)
	app = PilotApp.new()
	left.add_child(app)
	app.setup(s, graphics, bot)
	app.scene.set_hour(hour)
	app.cam_mode = "chase"
	var right := _pane(h)
	desk = StationApp.new()
	right.add_child(desk)
	desk.setup(LocalLink.new(s, Roles.CONTROLLER, false), Roles.CONTROLLER, s.world, true)
	banner = UIStyle.label("", 15, UIStyle.AMBER)
	banner.add_theme_stylebox_override("normal", UIStyle.panel_box(Color(0, 0, 0, 0.7)))
	banner.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	banner.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ui.add_child(banner)


func _pane(parent: Control) -> SubViewport:
	var c := SubViewportContainer.new()
	c.stretch = true
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(c)
	var vp := SubViewport.new()
	vp.handle_input_locally = false
	c.add_child(vp)
	return vp


func _process(_dt: float) -> bool:
	var t := s.time
	banner.text = "SKYRUNNER (Godot)  left: pilot  right: task-force desk  T+%d:%02d  %s" % [int(t / 60), int(fmod(t, 60)), label]
	if ended_at < 0 and (bot.phase == "done" or s.phase in ["busted", "crashed"] or (s.parked and s.unloading.is_empty() and s.time > 60)):
		ended_at = t
		print("outcome at T+%.0fs: %s" % [t, s.last_outcome if s.last_outcome else bot.outcome])
	return (ended_at >= 0 and t - ended_at > 6.0) or t > max_s
