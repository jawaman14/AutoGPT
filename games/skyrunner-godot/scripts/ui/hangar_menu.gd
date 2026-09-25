class_name HangarMenu
extends GameMenu
## Aircraft dealer, gear shop and services (spotters, crew).

var list: ItemList
var rows: Array = []


func _build() -> void:
	list = GameMenu.make_list()
	list.item_activated.connect(func(_i): key("enter"))
	content.add_child(list)


func _rows() -> Array:
	var out := []
	for a in Aircraft.ROSTER.values():
		out.append(["aircraft", a])
	for g in Session.GEAR:
		if s.features.has({"ferry_tank": "ferry"}.get(g, g)):
			out.append(["gear", g])
	if s.features.has("spotters"):
		out.append(["spotter", s.location])
	if s.features.has("copilot"):
		out.append(["copilot", null])
	return out


func refresh() -> void:
	title.text = "HANGAR, GEAR & SERVICES"
	var keep := maxi(0, GameMenu.selected(list))
	list.clear()
	rows = _rows()
	for r in rows:
		var text := ""
		match r[0]:
			"aircraft":
				var a: Aircraft.Spec = r[1]
				var owned := "OWNED" if s.owned.has(a.key) else "$" + Py.money(a.price)
				text = "%-24s %10s%s   MTOW %.0f lb, %d seats, roll ~%.0f m" % [a.name, owned,
					" (current)" if a.key == s.aircraft_key else "", a.mtow_lb, a.seat_count(), a.ground_roll_m]
			"gear":
				var g: Array = Session.GEAR[r[1]]
				var have: bool = s.gear.has(r[1]) or (r[1] == "ferry_tank" and Py.any(s.loadout.items.values(), func(i): return i.kind == "tank"))
				text = "%-52s %8s" % [g[1], "FITTED" if have else "$" + Py.money(g[0])]
			"spotter":
				var watching := ", ".join(s.spotters.map(func(sp): return sp.code))
				text = "Hire a spotter to watch this strip ($%d)   [watching: %s]" % [Session.SPOTTER_FEE, watching if watching else "none"]
			"copilot":
				var who: String = {"human": "human (online)", "ai": "Rosa (AI)"}.get(s.copilot, "none")
				text = "Co-pilot: %s  - loads 2x faster, kicks bales, pumps ferry fuel. ENTER toggles." % who
		list.add_item(text)
	list.select(mini(keep, list.item_count - 1))
	var shop: bool = s.airfield != null and s.airfield.shop
	footer.text = ("ENTER buy / hire / toggle   " if shop else "No aircraft dealer here (gear and services OK).   ") + "ESC close"


func key(k: String) -> void:
	match k:
		"up":
			GameMenu.list_move(list, -1)
		"down":
			GameMenu.list_move(list, 1)
		"enter":
			var i := GameMenu.selected(list)
			if i < 0:
				return
			var r: Array = rows[i]
			var err = null
			match r[0]:
				"aircraft":
					err = s.buy_or_switch(r[1].key)
				"gear":
					err = s.buy_gear(r[1])
				"spotter":
					err = s.hire_spotter(r[1])
				"copilot":
					if s.copilot == "human":
						err = "Your co-pilot is a real person - ask them."
					else:
						s.set_copilot(null if s.copilot else "ai")
						s.say("Co-pilot aboard." if s.copilot else "Co-pilot stays on the ground.")
			if err:
				s.say(err)
			refresh()
