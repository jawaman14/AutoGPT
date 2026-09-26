class_name HQBoard
extends VBoxContainer
## The HQ screen for either side, shared by the boss's desk in the villa
## (HQMenu), the boss and chief stations (StationApp): headline tiles, tonight's
## conditions (forecast, routine, the rival), the order table and the news.
## `update(season_view)` refreshes it; `rows` holds the HQOrders rows in table order.

var side := "runner"
var orders: HQOrders
var tiles := {}
var cond := {}
var table: DataTable
var detail: Label
var news: Label
var rows: Array = []


func setup(side_: String, show_news := true) -> HQBoard:
	side = side_
	orders = HQOrders.new(side)
	add_theme_constant_override("separation", 8)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	add_child(head)
	var names := ["dirty", "clean", "case", "moves", "heat"] if side == "runner" else ["evidence", "budget", "support", "moves", "fronts"]
	var caps := {"dirty": "Dirty", "clean": "Clean / retire", "case": "The case", "moves": "Moves",
		"heat": "Heat", "evidence": "Evidence", "budget": "Budget", "support": "Support",
		"fronts": "Fronts known"}
	for n in names:
		tiles[n] = StatTile.new().setup(caps[n], n in ["clean", "evidence", "heat", "support"], 19)
		head.add_child(tiles[n])
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	add_child(row2)
	for n in ["forecast", "routine", "rival"]:
		cond[n] = StatTile.new().setup({"forecast": "Weather", "routine": "Routine" if side == "runner" else "Pattern of life",
			"rival": "Los Cuervos"}[n], false, 15)
		row2.add_child(cond[n])
	table = DataTable.new().setup([{"title": "Order", "expand": true, "ratio": 3, "min": 220},
		{"title": "Now", "expand": true, "ratio": 2, "min": 160}])
	table.custom_minimum_size = Vector2(0, 200)
	add_child(table)
	detail = UIStyle.label("", 15, UIStyle.DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size = Vector2(0, 22)
	add_child(detail)
	table.row_selected.connect(func(_i): _detail())
	news = UIStyle.label("", 13, UIStyle.CAPTION)
	news.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	news.visible = show_news
	add_child(news)
	return self


static func _k(v: float) -> String:
	return "$%.0fk" % (v / 1000.0) if absf(v) >= 10000 else "$" + Py.money(int(v))


func update(ss: Dictionary) -> void:
	if side == "runner":
		var o: Dictionary = ss.get("org", {})
		tiles["dirty"].set_value(_k(float(o.get("dirty", 0))), UIStyle.AMBER)
		var clean := float(o.get("clean", 0))
		var target := maxf(1.0, float(ss.get("retire_target", 1)))
		tiles["clean"].set_value("%s / %s" % [_k(clean), _k(target)], UIStyle.GREEN, clean / target)
		var ev = ss.get("evidence")
		tiles["case"].set_value(str(ss.get("evidence_rumor", "?")), UIStyle.RED if str(ss.get("evidence_rumor", "")) in ["strong", "damning"] else UIStyle.WHITE,
			-1.0, ("%.0f/100 (your sources)" % ev) if ev != null else "")
		tiles["moves"].set_value("%d%s" % [int(o.get("actions", 0)), "  READY" if o.get("ready") else ""], UIStyle.GREEN if o.get("ready") else UIStyle.WHITE)
		var heat := float(ss.get("public", {}).get("heat", 0))
		tiles["heat"].set_value("%d" % int(heat), UIStyle.RED if heat > 60 else UIStyle.WHITE, heat / 100.0)
	else:
		var L: Dictionary = ss.get("law", {})
		var ind := maxf(1.0, float(ss.get("indict_evidence", 100)))
		tiles["evidence"].set_value("%.0f / %.0f" % [float(L.get("evidence", 0)), ind], UIStyle.AMBER, float(L.get("evidence", 0)) / ind)
		tiles["budget"].set_value("$%.0fk" % float(L.get("budget_k", 0)))
		tiles["support"].set_value("%.0f" % float(L.get("support", 0)), UIStyle.GREEN, float(L.get("support", 0)) / 100.0)
		tiles["moves"].set_value("%d%s" % [int(L.get("actions", 0)), "  READY" if L.get("ready") else ""], UIStyle.GREEN if L.get("ready") else UIStyle.WHITE)
		var est = ss.get("clean_estimate")
		tiles["fronts"].set_value("%d" % int(ss.get("known_fronts", 0)), UIStyle.WHITE, -1.0, ("laundered ~$" + Py.money(int(est))) if est else "laundered: unknown")
	_conditions(ss)
	var keep := table.selected_row()
	var new_rows := orders.rows(ss)
	var same := new_rows.size() == rows.size() and table.row_count() == rows.size()
	rows = new_rows
	if not same:
		table.clear_rows()
		for r in rows:
			table.add_row([r.label, r.state], {"color": UIStyle.GREEN if r.key == "ready" else Color(0.9, 0.92, 0.95)})
		table.select_near(maxi(0, keep))
	else:
		for i in rows.size():
			table.set_cell(i, 0, rows[i].label)
			table.set_cell(i, 1, rows[i].state)
	_detail()
	var lines := []
	for n in ss.get("news", []).slice(-3):
		lines.append("NEWS  " + str(n))
	for n in ss.get("log", []).slice(-3):
		lines.append("LOG   " + str(n))
	if side == "runner" and ss.get("patrol_leak"):
		lines.append("Our man in dispatch: the patrol goes %s tonight." % ss.patrol_leak)
	news.text = "\n".join(lines)


func _conditions(ss: Dictionary) -> void:
	var f = ss.get("forecast")
	if f is Dictionary and not f.is_empty():
		var w: Dictionary = ss.get("weather", {})
		var sky := str(f.sky)
		var col: Color = {"clear": UIStyle.WHITE, "cloud": UIStyle.CYAN, "storm": UIStyle.RED}.get(sky, UIStyle.WHITE)
		var sub := "wind %03d/%d kt  moon %d%%" % [int(f.wind_dir), int(f.wind_kt), int(float(f.moon) * 100)]
		if not w.is_empty() and w.sky != f.sky:
			sub += "  -  actual: %s" % w.sky
		cond["forecast"].set_value(sky.to_upper(), col, -1.0, sub)
	else:
		cond["forecast"].set_value("-", UIStyle.CAPTION)
	var pat = ss.get("pattern")
	if pat is Dictionary:
		var worst: String = HQOrders.ZONES[0]
		for z in HQOrders.ZONES:
			if float(pat[z]) > float(pat[worst]):
				worst = z
		var parts := HQOrders.ZONES.map(func(z): return "%s +%d%%" % [z, int(round(float(pat[z]) * 100))])
		var hot := float(pat[worst]) > 0.15
		cond["routine"].set_value(("%s expected" % worst) if hot else "unpredictable", UIStyle.AMBER if hot else UIStyle.GREEN, -1.0, "  ".join(parts))
	else:
		cond["routine"].set_value("-", UIStyle.CAPTION)
	var rv = ss.get("rival")
	if rv is Dictionary:
		var text := str(rv.get("band", ""))
		var sub := ""
		if side == "runner":
			if rv.get("truce_nights"):
				sub = "truce %d nights" % int(rv.truce_nights)
			if rv.get("grudge"):
				sub = "OUT FOR REVENGE"
			if str(rv.get("reputation", "")) != "":
				sub += ("  -  " if sub != "" else "") + str(rv.reputation)
		else:
			sub = "%d busted" % int(rv.get("busts", 0))
		cond["rival"].set_value(text if text != "" else "-", UIStyle.RED if rv.get("grudge") else UIStyle.WHITE, -1.0, sub)
	else:
		cond["rival"].set_value("none on this island", UIStyle.CAPTION)


func _detail() -> void:
	var i := table.selected_row()
	detail.text = rows[i].detail if i >= 0 and i < rows.size() else ""


func selected() -> Dictionary:
	var i := table.selected_row()
	return rows[i] if i >= 0 and i < rows.size() else {}


## LEFT/RIGHT on the selected order.
func adjust(d: int, ss: Dictionary) -> void:
	var r := selected()
	if not r.is_empty():
		orders.adjust(r, d, ss)


## The `hq` command args for the selected order (empty when nothing's selected).
func command_args() -> Dictionary:
	var r := selected()
	if r.is_empty():
		return {}
	var args := {"order": r.order}
	args.merge(r.args)
	return args
