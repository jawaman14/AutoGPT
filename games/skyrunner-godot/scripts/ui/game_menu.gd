class_name GameMenu
extends PanelContainer
## Base for the ground menus: a titled panel that the pilot app opens with a
## hotkey, driven by mouse or keyboard (`key(name)` receives up/down/left/right/
## enter/a/+/-/f). Subclasses build their content in `_build` and refresh it
## from the session in `refresh`. The footer is a row of key caps (`hints`);
## clicking one does what the key does. `footer` is a one-line note above it.

signal closed

var s: Session
var title: Label
var content: VBoxContainer
var subtitle: Label
var footer: Label
var hints: KeyHints


func setup(sess: Session) -> GameMenu:
	s = sess
	theme = UIStyle.theme()
	add_theme_stylebox_override("panel", UIStyle.box(Color(0.03, 0.04, 0.06, 0.94), 10, UIStyle.LINE, 1, Vector4(22, 16, 22, 14)))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor_left = 0.06
	anchor_right = 0.94
	anchor_top = 0.06
	anchor_bottom = 0.94
	offset_left = 0
	offset_right = 0
	offset_top = 0
	offset_bottom = 0
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	v.add_child(head)
	title = UIStyle.title("", 30)
	head.add_child(title)
	subtitle = UIStyle.label("", 15, UIStyle.CAPTION)
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(subtitle)
	var rule := ColorRect.new()
	rule.color = Color(UIStyle.ACCENT.r, UIStyle.ACCENT.g, UIStyle.ACCENT.b, 0.35)
	rule.custom_minimum_size = Vector2(0, 1)
	v.add_child(rule)
	content = VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	v.add_child(content)
	footer = UIStyle.label("", 14, UIStyle.CAPTION)
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(footer)
	hints = KeyHints.new()
	hints.hint_pressed.connect(func(a):
		if a == "esc":
			close()
		else:
			key(a))
	v.add_child(hints)
	_build()
	visible = false
	return self


func _build() -> void:
	pass


func open() -> void:
	visible = true
	refresh()


func close() -> void:
	visible = false
	closed.emit()


func refresh() -> void:
	pass


func key(_k: String) -> void:
	pass


## A table for a menu (see DataTable).
static func make_table(columns: Array) -> DataTable:
	return DataTable.new().setup(columns)


## Keyboard step through a DataTable or an ItemList.
static func list_move(l, d: int) -> void:
	if l is DataTable:
		l.move(d)
		return
	var n: int = l.item_count
	if n == 0:
		return
	var cur: int = l.get_selected_items()[0] if l.is_anything_selected() else 0
	var nxt := posmod(cur + d, n)
	for k in n:  # skip non-selectable separators
		if l.is_item_selectable(nxt):
			break
		nxt = posmod(nxt + d, n)
	l.select(nxt)
	l.ensure_current_is_visible()


static func selected(l) -> int:
	if l is DataTable:
		return l.selected_row()
	return l.get_selected_items()[0] if l.is_anything_selected() else -1
