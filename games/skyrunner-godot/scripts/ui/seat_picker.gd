class_name SeatPicker
extends Control
## The multiplayer lobby's role picker: joined to a host without a seat, you
## see every role in the game - run by the AI, free to take, or held by a
## named player - and claim one (the AI hands it over). The table talk is here
## too. `seated(role)` fires when the host gives you a seat.

signal seated(role: String)

var link: NetClient
var table: DataTable
var log_lbl: Label
var status: Label
var chat: LineEdit
var hints: KeyHints
var _keys: Array = []
var _sig := ""

const ABOUT := {
	"pilot": "flies the aircraft (JSBSim)", "copilot": "loads, kicks bales, pumps fuel, runs the scanner and the boat",
	"spotter": "watches a strip for police", "boat": "the go-fast at the rendezvous", "boss": "the organisation's HQ, night by night",
	"lieutenant": "the organisation's soldiers on the streets", "controller": "the task force's radar and dispatch desk",
	"interceptor": "flies a police helicopter or jet in 3D", "cutter": "the Coast Guard cutter", "chief": "the task force's HQ and budget",
	"patrol": "the narcotics squads on the streets",
}


func setup(link_: NetClient) -> SeatPicker:
	link = link_
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UIStyle.theme()
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.04, 0.055)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for k in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + k, 28)
	add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)
	v.add_child(UIStyle.title("Take a seat", 36))
	v.add_child(UIStyle.label("Every role is played by the AI until someone takes it. Leave, and the AI takes it back.", 15, UIStyle.CAPTION))
	table = DataTable.new().setup([{"title": "Role", "min": 110}, {"title": "Side", "min": 80}, {"title": "Seat", "min": 160},
		{"title": "What you do", "expand": true, "ratio": 3}])
	table.custom_minimum_size = Vector2(0, 360)
	table.row_activated.connect(func(_i): claim_selected())
	v.add_child(table)
	status = UIStyle.label("", 15, UIStyle.RED)
	v.add_child(status)
	log_lbl = UIStyle.label("", 14, UIStyle.DIM)
	log_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(log_lbl)
	chat = LineEdit.new()
	chat.placeholder_text = "Talk to the table - ENTER sends"
	chat.max_length = 200
	chat.text_submitted.connect(func(t):
		if t.strip_edges() != "":
			link.say(t.strip_edges())
		chat.text = ""
		chat.release_focus())
	v.add_child(chat)
	hints = KeyHints.new()
	hints.set_hints([["UP/DOWN", "role", "down"], ["ENTER", "take the seat", "enter"], ["T", "talk", "t"]])
	hints.hint_pressed.connect(func(a): key(a))
	v.add_child(hints)
	link.role_changed.connect(func(r):
		if r != "":
			seated.emit(r))
	return self


func _process(_dt: float) -> void:
	if link.error != null:
		status.text = str(link.error)
	elif link.claim_error != null:
		status.text = str(link.claim_error)
	var sig := JSON.stringify(link.seats)
	if sig != _sig:
		_sig = sig
		var keep := table.selected_row()
		table.clear_rows()
		_keys.clear()
		for side in ["runner", "law"]:
			table.section("THE ORGANISATION" if side == "runner" else "THE TASK FORCE")
			_keys.append("")
			for s in link.seats.filter(func(x): return x.side == side):
				var seat: String = {"ai": "AI - free", "human": "taken: " + str(s.name), "reserved": "held for " + str(s.name),
					"off": "not in this game"}.get(s.who, s.who)
				var col: Color = UIStyle.GREEN if s.who == "ai" else (UIStyle.CAPTION if s.who == "off" else UIStyle.AMBER)
				table.add_row([s.role, side, seat, ABOUT.get(s.role, "")], {"cell_colors": {2: col}})
				_keys.append(s.role)
		table.select(keep if keep >= 0 else 1)
	var lines := ["Players: " + ", ".join(link.players.map(func(p): return "%s%s" % [p.name, " (%s)" % p.role if p.role != "" else ""]))]
	for c in link.chat_log.slice(-8):
		lines.append("%s: %s" % [c.get("from", "?"), c.get("text", "")])
	log_lbl.text = "\n".join(lines)


func claim_selected() -> void:
	var i := table.selected_row()
	if i >= 0 and i < _keys.size() and _keys[i] != "":
		link.claim(_keys[i])


func key(k: String) -> void:
	match k:
		"up":
			table.move(-1)
		"down":
			table.move(1)
		"enter":
			claim_selected()
		"t":
			chat.grab_focus()


func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed) or chat.has_focus():
		return
	match ev.keycode:
		KEY_UP: key("up")
		KEY_DOWN: key("down")
		KEY_ENTER, KEY_KP_ENTER: key("enter")
		KEY_T: key("t")
		_: return
	get_viewport().set_input_as_handled()
