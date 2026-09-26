class_name JobMenu
extends GameMenu
## Job board at the current strip: accept work, drop jobs you've taken. A table
## of pay, weight, passengers, distance and - for a strip destination - the
## estimated landing roll with this load against the strip length, so a trap
## shows up red before you fly into it. The card below explains the selected job.

var list: DataTable
var card: PanelContainer
var card_title: Label
var detail: Label
var card_facts: Label
var rows: Array = []  ## [kind, job] per table row, or null for a section
var market: DataTable  ## the second page (LEFT/RIGHT): today's prices by market
var page := 0


func _build() -> void:
	list = GameMenu.make_table([
		{"title": "", "min": 54},
		{"title": "Job", "expand": true, "ratio": 3, "min": 220},
		{"title": "Pay", "align": "right", "mono": true, "min": 90},
		{"title": "Weight", "align": "right", "mono": true, "min": 80},
		{"title": "Pax", "align": "right", "mono": true, "min": 50},
		{"title": "Dist", "align": "right", "mono": true, "min": 80},
		{"title": "Strip / roll", "align": "right", "mono": true, "min": 170},
	])
	list.row_activated.connect(func(_i): key("enter"))
	list.row_selected.connect(func(_i): _show_detail())
	content.add_child(list)
	card = PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIStyle.box(Color(1, 1, 1, 0.04), 6, UIStyle.LINE, 1, Vector4(14, 10, 14, 10)))
	card.custom_minimum_size = Vector2(0, 96)
	content.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 4)
	card.add_child(cv)
	card_title = UIStyle.label("", 17, UIStyle.WHITE)
	cv.add_child(card_title)
	card_facts = UIStyle.label("", 14, UIStyle.CAPTION, UIStyle.mono())
	cv.add_child(card_facts)
	detail = UIStyle.label("", 15, UIStyle.DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cv.add_child(detail)
	market = GameMenu.make_table([
		{"title": "Good", "expand": true, "ratio": 3, "min": 200},
		{"title": "Town", "align": "right", "mono": true, "min": 80},
		{"title": "West", "align": "right", "mono": true, "min": 80},
		{"title": "North", "align": "right", "mono": true, "min": 80},
		{"title": "Sea", "align": "right", "mono": true, "min": 80},
	])
	market.visible = false
	content.add_child(market)


## A price multiplier as "+12%", coloured: green pays more, red less.
static func _pct(m: float) -> Array:
	var p := int(round((m - 1.0) * 100.0))
	return ["%+d%%" % p if p != 0 else "0", UIStyle.GREEN if p >= 4 else (UIStyle.RED if p <= -4 else UIStyle.DIM)]


func _market() -> void:
	title.text = "MARKET"
	var b := s.econ.board()
	subtitle.text = "prices against the usual  -  avgas $%.2f/lb (%s)" % [Session.FUEL_PRICE_PER_LB * b.fuel, _pct(b.fuel)[0]]
	market.clear_rows()
	for hot in [true, false]:
		market.section("CONTRABAND - paid at the street price when you deliver" if hot else "LEGAL WORK - paid as agreed")
		for r in b.goods.filter(func(g): return g.hot == hot):
			var cells := [r.name]
			var cc := {}
			for i in Economy.MARKETS.size():
				var pc := _pct(r.prices[Economy.MARKETS[i]])
				cells.append(pc[0])
				cc[i + 1] = pc[1]
			market.add_row(cells, {"cell_colors": cc})
	var heat := []
	for m in Economy.MARKETS:
		heat.append("%s: police %s, rivals %d%%" % [m, ("quiet" if b.heat[m] < 0.1 else ("around" if b.heat[m] < 0.4 else ("thick" if b.heat[m] < 0.9 else "everywhere"))),
			int(b.rival[m] * 100)])
	footer.text = "   ".join(heat) + ("\nNews: " + " / ".join(b.events) if not b.events.is_empty() else "")
	hints.set_hints([["LEFT/RIGHT", "job board", "left"], ["ESC", "close", "esc"]])


func refresh() -> void:
	list.visible = page == 0
	card.visible = page == 0
	market.visible = page == 1
	if page == 1:
		_market()
		return
	var af := World.airfield(s.location)
	title.text = "JOB BOARD"
	subtitle.text = "%s  -  %.0f m %s" % [af.name, af.length, af.surface]
	var keep := list.selected_row()
	list.clear_rows()
	rows.clear()
	var board: Array = s.boards.get(s.location, [])
	var est_w: float = s.loadout.compute().weight_lb
	if not board.is_empty():
		_sep("Available here")
	for j in board:
		_row("board", j, af, est_w)
	if not s.active_jobs.is_empty():
		_sep("On board  -  ENTER drops")
	for j in s.active_jobs:
		_row("active", j, af, est_w)
	if rows.is_empty():
		_sep("No work here right now.")
	list.select_near(keep if keep >= 0 else 0)
	_show_detail()
	footer.text = ""
	hints.set_hints([["UP/DOWN", "select", "down"], ["ENTER", "accept / drop", "enter"], ["LEFT/RIGHT", "market", "right"],
		["L", "load & fuel", ""], ["ESC", "close", "esc"]])


func _sep(text: String) -> void:
	list.section(text)
	rows.append(null)


func _row(kind: String, j: Jobs.Job, af: Airfield, est_w: float) -> void:
	var xy: Array = s.job_xy(j)
	var dist := PyMath.hypot(xy[0] - af.x, xy[1] - af.y) / 1000
	var pax := Py.count(j.items, func(it): return it.kind == "passenger")
	var strip := ""
	var strip_col := UIStyle.DIM
	if j.is_airdrop():
		strip = "sea, %d bales" % j.items.size()
		strip_col = UIStyle.CYAN
	else:
		var dst := World.airfield(j.dest)
		var roll := s.spec.est_landing_roll(est_w + (j.weight_lb() if kind == "board" else 0.0), s.world.airfield_elev(dst))
		strip = "%.0f / %.0f m" % [dst.length, roll]
		# a roll close to the strip length is the trap the board warns about
		strip_col = UIStyle.RED if roll > 0.85 * dst.length else (UIStyle.AMBER if roll > 0.65 * dst.length else UIStyle.GREEN)
	var tag := "HOT" if j.hot() else ("TAKEN" if kind == "active" else "")
	var col := Color(1, 0.62, 0.48) if j.hot() else Color(0.9, 0.92, 0.95)
	list.add_row([tag, j.title, "$" + Py.money(j.payout), "%.0f lb" % j.weight_lb(), str(pax) if pax else "-",
		"%.1f km" % dist, strip], {"color": col, "cell_colors": {6: strip_col, 0: UIStyle.RED if j.hot() else UIStyle.CAPTION}})
	rows.append([kind, j])


func _show_detail() -> void:
	var i := list.selected_row()
	card_title.text = ""
	card_facts.text = ""
	detail.text = ""
	if i < 0 or i >= rows.size() or rows[i] == null:
		return
	var j: Jobs.Job = rows[i][1]
	card_title.text = ("HOT  " if j.hot() else "") + j.title
	var facts := ["$%s" % Py.money(j.payout), "%.0f lb" % j.weight_lb(), "%d items" % j.items.size()]
	if j.deadline_s:
		facts.append("%d min deadline" % int(j.deadline_s / 60))
	if not j.is_airdrop():
		facts.append("to " + World.airfield(j.dest).name)
	if j.hot() and Economy.REALISM:
		var now := int(round(j.payout * s.econ.job_mult(j) / maxf(0.05, j.price_mult)))
		facts.append("street now $%s" % Py.money(now))
	card_facts.text = "   ".join(facts)
	detail.text = j.notes if j.notes else ("Paid per bale landed at the cove." if j.is_airdrop() else "")


func key(k: String) -> void:
	if k in ["left", "right"]:
		page = 1 - page
		refresh()
		return
	if page == 1:
		return
	match k:
		"up":
			list.move(-1)
			_show_detail()
		"down":
			list.move(1)
			_show_detail()
		"enter":
			var i := list.selected_row()
			if i < 0 or rows[i] == null:
				return
			var job: Jobs.Job = rows[i][1]
			if rows[i][0] == "board":
				var err = s.accept_job(job)
				s.say(err if err != null else "Accepted: %s. Check your load [L]!" % job.title)
			else:
				s.drop_job(job)
			refresh()
