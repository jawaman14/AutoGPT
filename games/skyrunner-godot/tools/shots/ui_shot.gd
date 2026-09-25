extends SceneTree
## Menu/station screenshot: godot --script res://tools/shots/ui_shot.gd -- <load|jobs|hangar|boss|chief|desk|copilot|hud|lobby> <out.png>
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
		"copilot", "hud":
			# over the rendezvous with a ferry tank pumping and bales going out
			sess = Session.new({"seed": 5, "location": "HAR", "mode": Roles.COOP})
			sess.update(1.0 / 30)
			sess.set_copilot("human")
			sess.money = 20000
			sess.buy_gear("ferry_tank")
			for i in 30 * 20:
				sess.update(1.0 / 30)
			sess.fill_ferry(150)
			var drop := Maritime.random_drop_point(sess.world, sess.rng, sess.maritime.cove)
			var job := Jobs.airdrop_job(World.airfield("HAR"), drop, sess.rng, 4)
			sess.boards["HAR"].append(job)
			sess.accept_job(job)
			for i in 30 * 30:
				sess.update(1.0 / 30)
			sess.spawn_airborne(drop[0] - 900, drop[1], 90, 150, 88)
			sess.fm.fdm.set_property("propulsion/tank[0]/contents-lbs", 60)
			sess.fm.fdm.set_property("propulsion/tank[1]/contents-lbs", 60)
			sess.command(Roles.PILOT, "autopilot", {"on": true})
			sess.command(Roles.COPILOT, "pump", {"on": true})
			sess.command(Roles.COPILOT, "call_boat")
			sess.command(Roles.COPILOT, "chat", {"text": "boat's on its way, two minutes"})
			for i in 30 * 8:
				sess.update(1.0 / 30)
			sess.command(Roles.COPILOT, "kick", {"count": 2})
			sess.update(1.0 / 30)
			if what == "copilot":
				app = StationApp.new()
				root.add_child(app)
				app.setup(LocalLink.new(sess, Roles.COPILOT), Roles.COPILOT, sess.world)
			else:
				sess.police.case("runner").wanted = 1
				sess.police.wanted = 1
				app = PilotApp.new()
				root.add_child(app)
				app.setup(sess, "low")
		"lobby":
			app = Lobby.new()
			root.add_child(app)
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
	if what == "hud" and app is PilotApp:
		app.set_process(n < 20)  # let the HUD settle, then hold the frame
	if n == 30:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
