extends SceneTree
## A tour of the ground war, the seats and the 1980s-coast look, for the demo
## video (Movie Maker, fixed 30 fps):
##
##   xvfb-run godot --rendering-method gl_compatibility --resolution 1280x720 \
##       --write-movie ground.avi --fixed-fps 30 --script res://tools/ground_tour.gd
##
## Shots: sunset over San Telmo; a firefight on a palm-lined boulevard; the
## lieutenant's desk (squads, orders, the streets) with the war running; the
## patrol commander's desk; the lobby's seat picker; on foot with a rifle; a
## run paying off; the city's neon at night.

var shots: Array = []  ## [duration s, setup, [[t, callable], ...], camera path or null]
var shot := -1
var shot_t := 0.0
var beat := 0
var app
var caption: Label
var sess: Session
var path = null


func _initialize() -> void:
	World.use_map(MapCity.SEED)
	var layer := CanvasLayer.new()
	layer.layer = 100
	root.add_child(layer)
	var cap := PanelContainer.new()
	cap.theme = UIStyle.theme()
	cap.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.02, 0.09, 0.86), 8, UIStyle.PINK, 1, Vector4(16, 8, 16, 9)))
	cap.anchor_left = 0.5
	cap.anchor_right = 0.5
	cap.anchor_top = 1.0
	cap.anchor_bottom = 1.0
	cap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	cap.offset_bottom = -58
	caption = UIStyle.label("", 19, UIStyle.WHITE)
	cap.add_child(caption)
	layer.add_child(cap)
	sess = Session.new({"seed": 5, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES,
		"ground_war": true, "chronicle": true, "agency": true})
	sess.police.frozen = true
	sess.money = 60000
	sess.law_funds = 30000.0
	sess.update(1.0 / 30)
	for i in 900:  # a quarter of an hour of war before we look
		sess.update(1.0)
	var C := MapCity.CITY_C
	shots = [
		[8.0, _aerial.bind(18.4, "San Telmo at sunset: pastel deco, neon trim, palm-lined boulevards"), [],
			[[Vector3(C.x + 2600, 380, -(C.y - 2400)), Vector3(C.x, 0, -C.y)], [Vector3(C.x + 900, 160, -(C.y - 1100)), Vector3(C.x - 300, 10, -(C.y + 300))]]],
		[9.0, _fight, [], null],
		[9.0, _desk.bind(Roles.LIEUTENANT, "The lieutenant's desk: our soldiers, their guns and orders, who holds the streets - AI until someone sits down"),
			[[3.0, func(): app._key("down")], [5.0, func(): app._key("m")]], null],
		[7.0, _desk.bind(Roles.PATROL, "The patrol commander: stakeouts, tails, checkpoints, a cordon before the raid"), [], null],
		[7.0, _picker, [], null],
		[9.0, _on_foot, [[2.0, func(): _shoot()], [2.4, func(): _shoot()], [2.8, func(): _shoot()], [4.5, func(): _shoot()], [5.0, func(): _shoot()]], null],
		[6.0, _banner, [], null],
		[8.0, _aerial.bind(21.2, "After dark: the neon, and the violet sky over the bay"), [],
			[[Vector3(C.x + 1800, 260, -(C.y - 2000)), Vector3(C.x - 200, 10, -C.y)], [Vector3(C.x + 300, 140, -(C.y - 900)), Vector3(C.x - 600, 10, -(C.y + 300))]]],
	]


func _cap(text: String) -> void:
	caption.text = text


func _swap(node: Node) -> void:
	if app != null and is_instance_valid(app):
		app.queue_free()
	app = node
	root.add_child(node)
	root.move_child(node, 0)


func _pilot(hour: float) -> PilotApp:
	var p := PilotApp.new()
	_swap(p)
	p.setup(sess, "medium")
	p.scene.set_hour(hour)
	p.hud.visible = false
	return p


func _aerial(hour: float, text: String) -> void:
	_pilot(hour)
	_cap(text)


var _fight_cam: Array


## A squad of faction f at p: raised if there's room, else one already out there, moved.
func _squad_at(f: String, kind: String, p: Vector2):
	var g := sess.ground
	var q = g.recruit(f, kind, p, false)
	if q is String:
		q = g.of(f).filter(func(x): return x.fight == null).front()
		q.x = p.x
		q.y = p.y
		q.men = maxi(q.men, 4)
		q.morale = 0.8
	q.human = true  # the AI leaves it where we put it
	return q


func _fight() -> void:
	var g := sess.ground
	var c: Vector2 = g.graph.nodes[g.graph.nearest(MapCity.CITY_C)]
	var a = _squad_at("org", "car", c)
	var b = _squad_at("rival", "car", c + Vector2(45, 25))
	for q in [a, b]:
		q.state = "holding"
		q.route = PackedVector2Array()
	g._open(a, b)
	var p := _pilot(18.3)
	var eye: Vector2 = a.pos() - (b.pos() - a.pos()).normalized() * 26 + Vector2(-(b.pos() - a.pos()).normalized().y, (b.pos() - a.pos()).normalized().x) * 14
	var mid: Vector2 = (a.pos() + b.pos()) / 2
	_fight_cam = [Vector3(eye.x, sess.world.ground(eye.x, eye.y) + 5.0, -eye.y), Vector3(mid.x, sess.world.ground(mid.x, mid.y) + 1.0, -mid.y)]
	path = [[_fight_cam[0], _fight_cam[1]], [_fight_cam[0] + Vector3(6, 1, 0), _fight_cam[1]]]
	_cap("The organisation's crew against Los Cuervos on the boulevard: Lanchester's law, cover, nerve")


func _desk(role: String, text: String) -> void:
	var st := StationApp.new()
	_swap(st)
	st.setup(LocalLink.new(sess, role), role, sess.world)
	_cap(text)


func _picker() -> void:
	# a stand-in roster, as a client sees it
	var link := NetClient.new()
	link._closed = true  # a stand-in roster: no socket
	link.seats = sess.seats.roster()
	link.seats[5] = {"role": Roles.LIEUTENANT, "side": "runner", "who": "human", "name": "Manny"}
	link.players = [{"name": "Manny", "role": Roles.LIEUTENANT}, {"name": "Rosa", "role": ""}]
	link.chat_log = [{"from": "Manny", "text": "I've got the streets. Somebody take the patrol desk"}]
	root.add_child(link)
	var p := SeatPicker.new()
	_swap(p)
	p.setup(link)
	_cap("Join mid-game: every seat the AI is playing is yours for the taking")


func _on_foot() -> void:
	var p := _pilot(17.6)
	p.hud.visible = true
	p._toggle_on_foot()
	if p.gun != null:
		p.gun.key("2")
		var g := sess.ground
		var xy: Array = p.walker.game_xy()
		var q = _squad_at("rival", "foot", Vector2(xy[0], xy[1]) + Vector2(10, 45))
		q.state = "holding"
		p._sync_squads(0.1)
	_cap("On foot with a rifle from the armoury: they shoot back")


func _shoot() -> void:
	if not (app is PilotApp) or app.gun == null:
		return
	var pts: Array = app.squads.men_pts
	if not pts.is_empty():
		app.walker.cam.look_at(pts[0][1] + Vector3(0, 1.3, 0), Vector3.UP)
	app.gun._cool = 0.0
	app.gun.trigger()


func _banner() -> void:
	var p := _pilot(16.5)
	p.hud.visible = true
	p.hud.show_banner("Run complete", "+$12,400", UIStyle.PINK)
	_cap("A run pays off")


func _process(dt: float) -> bool:
	shot_t += dt
	if shot < 0 or shot_t >= shots[shot][0]:
		shot += 1
		shot_t = 0.0
		beat = 0
		if shot >= shots.size():
			sess.dispose()
			return true
		path = shots[shot][3]
		shots[shot][1].call()
		return false
	if app is PilotApp:
		if path != null:
			var f := smoothstep(0.0, 1.0, shot_t / shots[shot][0])
			app.set_process(false)
			app.cam.global_position = path[0][0].lerp(path[1][0], f)
			app.cam.look_at(path[0][1].lerp(path[1][1], f), Vector3.UP)
			app.cam.fov = 60
			if sess.ground != null and not sess.ground.fights.is_empty() and int(shot_t * 30) % 20 == 0:
				sess.ground._rounds(GroundWar.ROUND_S)
			app._sync_squads(dt)
		elif app.on_foot:
			sess.update(dt)
			app._sync_squads(dt)
			app.hud.refresh()
		else:
			app.hud.refresh()
	elif app is StationApp:
		sess.update(dt * 20.0)  # the war runs fast behind the desk
	var beats: Array = shots[shot][2]
	while beat < beats.size() and shot_t >= beats[beat][0]:
		beats[beat][1].call()
		beat += 1
	return false
