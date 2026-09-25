extends SceneTree
## Menu/station screenshot: godot --script res://tools/shots/ui_shot.gd -- <load|jobs|hangar|boss|chief|desk> <out.png>
var n := 0
var what := "load"
var out := ""
var app
var sess: Session
func _init():
	var a := OS.get_cmdline_user_args()
	what = a[0]
	out = a[1]
	match what:
		"load", "jobs", "hangar":
			sess = Session.new({"seed": 1, "location": "FRM"})
			sess.update(1.0 / 30)
			app = PilotApp.new()
			root.add_child(app)
			app.setup(sess, "low")
			if what == "load":
				var job = Py.first(sess.boards["FRM"], func(j): return not j.is_airdrop() and j.weight_lb() < 400)
				sess.accept_job(job)
				sess.loadout.pending.clear()
				app._toggle_menu("l")
			elif what == "jobs":
				app._toggle_menu("j")
			else:
				app._toggle_menu("h")
		"boss", "chief":
			sess = Session.new({"seed": 9, "location": "FRM", "mode": Roles.VERSUS, "features": Session.SANDBOX_FEATURES + ["hq"]})
			sess.update(1.0 / 30)
			var role := Roles.BOSS if what == "boss" else Roles.CHIEF
			sess.command(role, "hq", {"order": "route", "zone": "north"} if what == "boss" else {"order": "fund", "unit": "heli", "n": 2})
			app = StationApp.new()
			root.add_child(app)
			app.setup(LocalLink.new(sess, role), role, sess.world)
		"desk":
			sess = Session.new({"seed": 9, "mode": Roles.POLICE, "humans": {Roles.CONTROLLER: "me"}})
			for i in 30 * 90:
				sess.update(1.0 / 30)
			sess.police.launch("heli", "HAR")
			app = StationApp.new()
			root.add_child(app)
			app.setup(LocalLink.new(sess, Roles.CONTROLLER), Roles.CONTROLLER, sess.world)
func _process(_d):
	n += 1
	if n == 3 and what in ["boss", "chief"]:
		app.list.select(2)
	if n == 30:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
