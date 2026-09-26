class_name HQMenu
extends GameMenu
## The organisation's orders, from the boss's desk in the villa (walk in and
## press E). The same HQBoard as the boss station: headline tiles, tonight's
## conditions, the order table (LEFT/RIGHT sets an order, ENTER issues it).
## `intel` mode is the map table: what the organisation knows about Los Cuervos,
## their turf, tonight's leak and the news.

var intel := false
var board: HQBoard
var list: DataTable  ## the board's order table (kept for callers that drive it)
var rows: Array = []
var info: Label
var turf: VBoxContainer


func _build() -> void:
	board = HQBoard.new().setup("runner")
	content.add_child(board)
	list = board.table
	info = UIStyle.label("", 15, UIStyle.WHITE)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(info)
	turf = VBoxContainer.new()
	turf.add_theme_constant_override("separation", 6)
	content.add_child(turf)
	list.row_activated.connect(func(_i): key("enter"))


func _view():
	return s.nights.view("runner") if s.nights != null else null


func refresh() -> void:
	var ss = _view()
	board.visible = ss != null and not intel
	turf.visible = ss != null and intel
	if ss == null:
		title.text = "THE VILLA"
		subtitle.text = ""
		info.text = "No season is running: the organisation and its HQ orders come with the fifth rule layer\n(--players 5 or more, or --layer 5)."
		info.visible = true
		hints.set_hints([["ESC", "close", "esc"]])
		return
	var head := "NIGHT %d/%d  -  %s" % [int(ss.night), int(ss.nights), str(ss.phase).to_upper()]
	if intel:
		_intel(ss, head)
		return
	info.visible = false
	title.text = "THE BOSS'S DESK"
	subtitle.text = head
	board.update(ss)
	rows = board.rows
	footer.text = ""
	hints.set_hints([["UP/DOWN", "order", "down"], ["LEFT/RIGHT", "change it", "right"], ["ENTER", "issue", "enter"],
		["ESC", "close", "esc"]])


func _intel(ss: Dictionary, head: String) -> void:
	title.text = "MAP TABLE"
	subtitle.text = head
	info.visible = true
	for c in turf.get_children():
		turf.remove_child(c)
		c.queue_free()
	var rv = ss.get("rival")
	var lines := []
	if rv is Dictionary:
		lines.append("%s: %s%s%s" % [rv.name, rv.band, ("   -   truce %d nights" % int(rv.truce_nights)) if rv.truce_nights else "",
			"   -   OUT FOR REVENGE" if rv.grudge else ""])
		turf.add_child(UIStyle.caption("Their share of each market"))
		for z in HQOrders.ZONES:
			var t := StatTile.new().setup(z, true, 16)
			var share := float(rv.turf[z])
			t.set_value("%d%%" % int(share * 100), UIStyle.RED if share > 0.5 else UIStyle.AMBER, share)
			turf.add_child(t)
	else:
		lines.append("No rival outfit on this island.")
	if ss.get("patrol_leak"):
		lines.append("Our man in dispatch: the patrol goes %s tonight." % ss.patrol_leak)
	lines += HQOrders.realism_lines(ss, "runner")
	lines += ["", "NEWS"] + ss.get("news", []).slice(-5).map(func(n): return "  " + str(n))
	lines += ["", "LOG"] + ss.get("log", []).slice(-6).map(func(n): return "  " + str(n))
	info.text = "\n".join(lines)
	hints.set_hints([["ESC", "close", "esc"]])


func _detail() -> void:
	board._detail()


func key(k: String) -> void:
	var ss = _view()
	if ss == null or intel:
		return
	match k:
		"up":
			list.move(-1)
			_detail()
			return
		"down":
			list.move(1)
			_detail()
			return
		"left", "right":
			board.adjust(1 if k == "right" else -1, ss)
		"enter":
			var args := board.command_args()
			if not args.is_empty():
				var res: Array = s.command(Roles.PILOT, "hq", args)
				if not res[0]:
					s.say(res[1])
	refresh()
