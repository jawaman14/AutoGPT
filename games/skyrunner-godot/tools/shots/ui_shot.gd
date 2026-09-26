extends SceneTree
## Menu/station screenshot: godot --script res://tools/shots/ui_shot.gd -- <load|jobs|market|hangar|upgrades|boss|chief|desk|lawtree|copilot|hud|lobby|lieutenant|patrol|seats> <out.png>
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
		"load", "jobs", "market", "hangar", "upgrades":
			sess = Session.new({"seed": 1, "location": "FRM", "upgrades": {"runner": ["bug_sweep", "detector", "dark_paint"]}})
			if what == "upgrades":
				sess.money = 9000
			sess.update(1.0 / 30)
			app = PilotApp.new()
			root.add_child(app)
			app.setup(sess, "low")
			if what == "load":
				var job = Py.first(sess.boards["FRM"], func(j): return not j.is_airdrop() and j.weight_lb() < 400)
				sess.accept_job(job)
				sess.loadout.pending.clear()
				app._toggle_menu("l")
			elif what in ["jobs", "market"]:
				if what == "market":  # a busy night: a crackdown, seizures, cops in town, the Cuervos in the west
					sess.econ.events.append({"good": "cocaine", "mult": 1.35, "until": 1e9, "text": Economy.EVENTS[0][3]})
					sess.econ.record_seizure("marijuana", "sea")
					sess.econ.fuel_walk = 1.18
					var c: Array = Economy.centre("town")
					sess.econ.update(Economy.TICK_S, 1.0, [[c[0], c[1]], [c[0] + 500, c[1]]], [], {"west": 0.8, "north": 0.2, "sea": 0.5})
				app._toggle_menu("j")
				if what == "market":
					app.menus["j"].key("right")
			else:
				app._toggle_menu("h")
				if what == "upgrades":
					app.menus["h"].key("right")
					for i in 9:
						app.menus["h"].key("down")
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
		"lieutenant", "patrol":
			# twenty minutes into a war on the city coast
			sess = Session.new({"seed": 5, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES,
				"ground_war": true, "chronicle": true, "agency": true, "family": true, "island": true})
			sess.police.frozen = true
			sess.money = 60000
			sess.law_funds = 30000.0
			for i in 1200:
				sess.update(1.0)
			sess.family.ai = false  # an offer on the table, and a shipment out
			sess.family.offer("docks")
			sess.island.ship("mules", 4)
			var role := Roles.LIEUTENANT if what == "lieutenant" else Roles.PATROL
			app = StationApp.new()
			root.add_child(app)
			app.setup(LocalLink.new(sess, role), role, sess.world)
			app._key("down")
		"seats":
			sess = Session.new({"seed": 5, "mode": Roles.VERSUS, "map_seed": MapCity.SEED, "ground_war": true})
			var link := NetClient.new()
			link._closed = true  # a stand-in roster: no socket
			link.seats = sess.seats.roster()
			for r in link.seats:
				if r.role == Roles.LIEUTENANT:
					r.who = "human"
					r.name = "Manny"
				elif r.role == Roles.CONTROLLER:
					r.who = "human"
					r.name = "Hart"
			link.players = [{"name": "host", "role": Roles.PILOT}, {"name": "Manny", "role": Roles.LIEUTENANT},
				{"name": "Hart", "role": Roles.CONTROLLER}, {"name": "Rosa", "role": ""}]
			link.chat_log = [{"from": "Manny", "text": "I've got the streets - somebody take patrol so it's a fair fight"},
				{"from": "Hart", "text": "the desk is mine. good luck, flyboy"}]
			root.add_child(link)
			app = SeatPicker.new()
			root.add_child(app)
			app.setup(link)
		"desk", "lawtree":
			sess = Session.new({"seed": 9, "mode": Roles.POLICE, "humans": {Roles.CONTROLLER: "me"},
				"upgrades": {"law": ["doppler", "heli_df"] if what == "lawtree" else []}})
			for i in 30 * 90:
				sess.update(1.0 / 30)
			sess.police.launch("heli", "HAR")
			app = StationApp.new()
			root.add_child(app)
			app.setup(LocalLink.new(sess, Roles.CONTROLLER), Roles.CONTROLLER, sess.world)
			if what == "lawtree":
				app._key("u")
func _process(_d):
	n += 1
	if n == 3 and what in ["boss", "chief"]:
		app.list.select(2)
	if n == 5 and what == "lawtree":
		for i in 5:
			app._key("down")
	if what == "hud" and app is PilotApp:
		app.set_process(n < 20)  # let the HUD settle, then hold the frame
	if n == 30:
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
