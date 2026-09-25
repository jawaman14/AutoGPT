class_name JobMenu
extends GameMenu
## Job board at the current strip: accept work, drop jobs you've taken. Shows
## pay, weight, passengers, distance, and for a strip destination the estimated
## landing roll with this load, so you can see a trap before you fly into it.

var list: ItemList
var detail: Label
var rows: Array = []  ## [kind, job] per list index, or null for a separator


func _build() -> void:
	list = GameMenu.make_list()
	list.item_activated.connect(func(_i): key("enter"))
	list.item_selected.connect(func(_i): _show_detail())
	content.add_child(list)
	detail = UIStyle.label("", 15, UIStyle.WHITE)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size = Vector2(0, 70)
	content.add_child(detail)
	footer.text = "UP/DOWN or click to select   ENTER / double-click accept or drop   ESC close"


func refresh() -> void:
	var af := World.airfield(s.location)
	title.text = "JOB BOARD - %s (%.0f m %s)" % [af.name, af.length, af.surface]
	var keep := GameMenu.selected(list)
	list.clear()
	rows.clear()
	var board: Array = s.boards.get(s.location, [])
	var est_w: float = s.loadout.compute().weight_lb
	if not board.is_empty():
		_sep("-- available --")
	for j in board:
		_row("board", j, af, est_w)
	if not s.active_jobs.is_empty():
		_sep("-- on board (ENTER to drop) --")
	for j in s.active_jobs:
		_row("active", j, af, est_w)
	if rows.is_empty():
		_sep("No work here right now.")
	if keep >= 0 and keep < list.item_count and list.is_item_selectable(keep):
		list.select(keep)
	elif list.item_count > 1:
		list.select(1)
	_show_detail()


func _sep(text: String) -> void:
	list.add_item(text, null, false)
	list.set_item_custom_fg_color(list.item_count - 1, UIStyle.AMBER)
	rows.append(null)


func _row(kind: String, j: Jobs.Job, af: Airfield, est_w: float) -> void:
	var xy: Array = s.job_xy(j)
	var dist := PyMath.hypot(xy[0] - af.x, xy[1] - af.y) / 1000
	var pax := Py.count(j.items, func(it): return it.kind == "passenger")
	var where := ""
	if j.is_airdrop():
		where = "drop at sea, %d bales, paid per bale at the cove" % j.items.size()
	else:
		var dst := World.airfield(j.dest)
		var roll := s.spec.est_landing_roll(est_w + (j.weight_lb() if kind == "board" else 0.0), s.world.airfield_elev(dst))
		where = "strip %.0f m (est. roll %.0f m)" % [dst.length, roll]
	var text := "%s%s\n    $%s  %.0f lb  %d pax  %.1f km  %s%s" % ["[HOT] " if j.hot() else "", j.title, Py.money(j.payout),
		j.weight_lb(), pax, dist, where, ("  %d min" % int(j.deadline_s / 60)) if j.deadline_s else ""]
	list.add_item(text)
	if j.hot():
		list.set_item_custom_fg_color(list.item_count - 1, Color(1, 0.6, 0.45))
	rows.append([kind, j])


func _show_detail() -> void:
	var i := GameMenu.selected(list)
	detail.text = ""
	if i >= 0 and rows[i] != null and rows[i][1].notes:
		detail.text = rows[i][1].notes


func key(k: String) -> void:
	match k:
		"up":
			GameMenu.list_move(list, -1)
			_show_detail()
		"down":
			GameMenu.list_move(list, 1)
			_show_detail()
		"enter":
			var i := GameMenu.selected(list)
			if i < 0 or rows[i] == null:
				return
			var job: Jobs.Job = rows[i][1]
			if rows[i][0] == "board":
				var err = s.accept_job(job)
				s.say(err if err != null else "Accepted: %s. Check your load [L]!" % job.title)
			else:
				s.drop_job(job)
			refresh()
