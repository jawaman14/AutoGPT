extends SceneTree
## World screenshot:
##   godot --script res://tools/shots/pilot_shot.gd -- <low|medium|high> <hour> <out.png> <chase|cockpit|tower> [view] [map_seed]
## view: ground (default: parked at HAR) | air (climbing out near Eagle's Nest) |
##       org | law | rival (looking at that HQ) | overview (high above the island)
var app: PilotApp
var n := 0
var q := "medium"
var hour := 14.0
var out := "shot.png"
var cam := "chase"
var view := "ground"
var fixed_cam = null  ## [position, look_at] for the HQ / overview views


func _init():
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: q = a[0]
	if a.size() > 1: hour = float(a[1])
	if a.size() > 2: out = a[2]
	if a.size() > 3: cam = a[3]
	if a.size() > 4: view = a[4]
	var opts := {"seed": 1, "location": "HAR"}
	if a.size() > 5: opts["map_seed"] = int(a[5])
	var s := Session.new(opts)
	app = PilotApp.new()
	root.add_child(app)
	app.setup(s, q)
	app.scene.set_hour(hour)
	app.cam_mode = cam
	if view == "air":
		var af := World.airfield("EGL")
		s.spawn_airborne(af.x - 2500, af.y - 1800, 40.0, 180.0, 95.0)
	elif view in ["org", "law", "rival"]:
		var h: Dictionary = s.world.map.hqs[view]
		var hd := deg_to_rad(h.heading)
		# stand 40 m out in front of the building, looking back at it
		var px: float = h.x + sin(hd) * 38 + cos(hd) * 14
		var py: float = h.y + cos(hd) * 38 - sin(hd) * 14
		var gz := s.world.ground(h.x, h.y)
		fixed_cam = [Vector3(px, maxf(gz, s.world.ground(px, py)) + 9.0, -py), Vector3(h.x, gz + 3.0, -h.y)]
	elif view == "overview":
		var har := World.airfield("HAR")
		fixed_cam = [Vector3(har.x - 3000, 2600, -(har.y - 4000)), Vector3(0, 200, 0)]


func _process(_d):
	n += 1
	if fixed_cam != null:
		app.set_process(false)  # the app would move its camera back (processing re-enables on ready)
		app.cam.global_position = fixed_cam[0]
		app.cam.look_at(fixed_cam[1], Vector3.UP)
		app.cam.fov = 60
		app.hud.visible = false
	if n == 40:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
