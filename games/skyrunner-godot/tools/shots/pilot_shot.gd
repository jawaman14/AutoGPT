extends SceneTree
## World screenshot:
##   godot --script res://tools/shots/pilot_shot.gd -- <low|medium|high> <hour> <out.png> <chase|cockpit|tower> [view] [map_seed] [sky] [moon]
## view: ground (default: parked at HAR) | air (climbing out near Eagle's Nest) |
##       org | law | rival (looking at that HQ) | overview (high above the island)
##       city (the port city from over the harbour) | estuary | farm (map-specific: the city coast)
##       foot (on foot beside the parked aircraft, looking at the hangars) |
##       villa (on foot inside the org's villa, at the boss's desk) |
##       gun (on foot by the hangars with a rifle from the armoury) |
##       island (Isla Soberana from its approach, over the horizon) | island_strip (its runway) |
##       debug (the F6 performance overlay, detailed)
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
	if view == "gun":
		opts.merge({"map_seed": MapCity.SEED, "features": Session.SANDBOX_FEATURES, "ground_war": true})
	if a.size() > 5: opts["map_seed"] = int(a[5])
	if a.size() > 6:
		opts["weather"] = {"sky": a[6], "moon": float(a[7]) if a.size() > 7 else 0.5}
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
	elif view == "city":
		fixed_cam = [Vector3(MapCity.CITY_C.x + 1400, 330, -(MapCity.CITY_C.y - 2200)), Vector3(MapCity.CITY_C.x - 300, 10, -MapCity.CITY_C.y)]
	elif view == "downtown":
		fixed_cam = [Vector3(MapCity.CITY_C.x + 700, 140, -(MapCity.CITY_C.y - 900)), Vector3(MapCity.CITY_C.x - 200, 20, -(MapCity.CITY_C.y + 300))]
	elif view == "estuary":
		fixed_cam = [Vector3(-9000, 420, 9200), Vector3(-12000, 0, 7000)]
	elif view == "farm":
		var frm := World.airfield("FRM")
		fixed_cam = [Vector3(frm.x + 1800, 520, -(frm.y - 2600)), Vector3(frm.x - 400, 120, -frm.y)]
	elif view == "island":
		fixed_cam = [Vector3(Island.C.x + 3800, 520, -(Island.C.y + 4600)), Vector3(Island.C.x - 400, 0, -Island.C.y)]
	elif view == "island_strip":
		var sob := World.airfield(Island.CODE)
		fixed_cam = [Vector3(sob.x + 900, 60, -(sob.y + 350)), Vector3(sob.x - 200, 4, -sob.y)]
	elif view == "overview":
		var har := World.airfield("HAR")
		fixed_cam = [Vector3(har.x - 3000, 2600, -(har.y - 4000)), Vector3(0, 200, 0)]


func _areas(node: Node, action: String, out: Array) -> Array:
	if node is Area3D and node.get_meta("action", "") == action:
		out.append(node)
	for c in node.get_children():
		_areas(c, action, out)
	return out


func _process(_d):
	n += 1
	if n == 2 and view in ["foot", "villa", "gun"]:
		_on_foot()
	if fixed_cam != null:
		app.set_process(false)  # the app would move its camera back (processing re-enables on ready)
		app.cam.global_position = fixed_cam[0]
		app.cam.look_at(fixed_cam[1], Vector3.UP)
		app.cam.fov = 60
		app.hud.visible = false
	if n == 3 and view == "debug":
		app.cycle_debug_menu()
		app.cycle_debug_menu()  # the detailed overlay
	if n == 40:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()


## Get out and stand in front of the hangar (or the boss's desk). Runs once the tree is live.
func _on_foot() -> void:
	app._toggle_on_foot()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var w := app.walker
	w.look_enabled = false
	var target := "hq_org" if view == "villa" else "hangar"
	if view == "gun" and app.gun != null:
		app.s.arsenals.org.add("rifle", 1)  # the shot's rifle
		app.gun.key("2")
	var areas := _areas(app.scene, target, [])
	if view != "villa":
		areas = areas.filter(func(a): return a.get_meta("field", "") == "HAR" and str(a.get_meta("label")).begins_with("Hangar"))
	if not areas.is_empty():
		var p: Vector3 = areas[0].global_position
		var back: Vector3 = areas[0].get_parent().global_transform.basis.z.normalized()
		var dist := 3.2 if view == "villa" else 48.0
		var spot: Vector3 = p - back * dist
		w.place(spot.x, -spot.z, 0.0)
		w.look_at(Vector3(p.x, w.global_position.y, p.z), Vector3.UP)
		w.cam.rotation.x = deg_to_rad(-8 if view == "villa" else 4)
