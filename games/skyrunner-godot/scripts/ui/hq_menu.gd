class_name HQMenu
extends GameMenu
## The organisation's orders, from the boss's desk in the villa (walk in and
## press E). Same order list as the boss station (HQOrders): cost, effect,
## state; LEFT/RIGHT sets it, ENTER issues it. `intel` mode is the map table:
## what the organisation knows about Los Cuervos, tonight's plan and the news.

var intel := false
var orders := HQOrders.new("runner")
var list: ItemList
var detail: Label
var info: Label
var rows: Array = []


func _build() -> void:
	info = UIStyle.label("", 15, UIStyle.WHITE, UIStyle.mono())
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(info)
	list = GameMenu.make_list()
	list.item_activated.connect(func(_i): key("enter"))
	list.item_selected.connect(func(_i): _detail())
	content.add_child(list)
	detail = UIStyle.label("", 15, UIStyle.DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size = Vector2(0, 50)
	content.add_child(detail)


func _view():
	return s.nights.view("runner") if s.nights != null else null


func refresh() -> void:
	var ss = _view()
	if ss == null:
		title.text = "THE VILLA"
		info.text = "No season is running: the organisation and its HQ orders come with the fifth rule layer\n(--players 5 or more, or --layer 5)."
		list.visible = false
		footer.text = "ESC close"
		return
	list.visible = not intel
	var o: Dictionary = ss.org
	var head := "NIGHT %d/%d  %s" % [int(ss.night), int(ss.nights), str(ss.phase).to_upper()]
	var lines := [
		"Dirty $%s   Clean $%s / $%s to retire   heat %d" % [Py.money(int(o.dirty)), Py.money(int(o.clean)),
			Py.money(int(ss.retire_target)), int(ss.public.heat)],
		"Case against you: %s   moves left tonight: %d%s" % [ss.evidence_rumor, int(o.actions), "   READY" if o.ready else ""],
	]
	lines += HQOrders.realism_lines(ss, "runner")
	var rv = ss.get("rival")
	if intel:
		title.text = "MAP TABLE  -  " + head
		if rv is Dictionary:
			lines += ["", "%s: %s%s%s" % [rv.name, rv.band, ("   truce %d nights" % int(rv.truce_nights)) if rv.truce_nights else "",
				"   OUT FOR REVENGE" if rv.grudge else ""], "Their share of each market:"]
			for z in HQOrders.ZONES:
				lines.append("  %-6s %s %d%%" % [z, "#".repeat(int(float(rv.turf[z]) * 20)), int(float(rv.turf[z]) * 100)])
		else:
			lines.append("No rival outfit on this island.")
		if ss.get("patrol_leak"):
			lines.append("Our man in dispatch: the patrol goes %s tonight." % ss.patrol_leak)
		lines += ["", "NEWS:"] + ss.get("news", []).slice(-5).map(func(n): return "  " + str(n))
		lines += ["", "LOG:"] + ss.get("log", []).slice(-6).map(func(n): return "  " + str(n))
		info.text = "\n".join(lines)
		footer.text = "ESC close"
		return
	title.text = "THE BOSS'S DESK  -  " + head
	info.text = "\n".join(lines)
	var keep := maxi(0, GameMenu.selected(list))
	rows = orders.rows(ss)
	list.clear()
	for r in rows:
		list.add_item("%-34s %s" % [r.label, r.state])
		if r.key == "ready":
			list.set_item_custom_fg_color(list.item_count - 1, UIStyle.GREEN)
	list.select(mini(keep, list.item_count - 1))
	_detail()
	footer.text = "UP/DOWN order   LEFT/RIGHT change it   ENTER issue   ESC close"


func _detail() -> void:
	var i := GameMenu.selected(list)
	detail.text = rows[i].detail if i >= 0 and i < rows.size() else ""


func key(k: String) -> void:
	var ss = _view()
	if ss == null or intel:
		return
	var i := GameMenu.selected(list)
	match k:
		"up":
			GameMenu.list_move(list, -1)
			_detail()
			return
		"down":
			GameMenu.list_move(list, 1)
			_detail()
			return
		"left", "right":
			if i >= 0:
				orders.adjust(rows[i], 1 if k == "right" else -1, ss)
		"enter":
			if i >= 0:
				var r: Dictionary = rows[i]
				var args := {"order": r.order}
				args.merge(r.args)
				var res: Array = s.command(Roles.PILOT, "hq", args)
				if not res[0]:
					s.say(res[1])
	refresh()
