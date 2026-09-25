extends SceneTree
## Pilot view screenshot: godot --script res://tools/shots/pilot_shot.gd -- <low|medium|high> <hour> <out.png> <chase|cockpit|tower> [air]
var app: PilotApp
var n := 0
var q := "medium"
var hour := 14.0
var out := "shot.png"
var cam := "chase"
func _init():
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: q = a[0]
	if a.size() > 1: hour = float(a[1])
	if a.size() > 2: out = a[2]
	if a.size() > 3: cam = a[3]
	var s := Session.new({"seed": 1, "location": "HAR"})
	app = PilotApp.new()
	root.add_child(app)
	app.setup(s, q)
	app.scene.set_hour(hour)
	app.cam_mode = cam
	if a.size() > 4 and a[4] == "air":
		var af := World.airfield("EGL")
		s.spawn_airborne(af.x - 2500, af.y - 1800, 40.0, 180.0, 95.0)
func _process(_d):
	n += 1
	if n == 40:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
