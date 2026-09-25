class_name GameMenu
extends PanelContainer
## Base for the ground menus: a titled panel that the pilot app opens with a
## hotkey, driven by mouse or keyboard (`key(name)` receives up/down/left/right/
## enter/a/+/-/f). Subclasses build their content in `_build` and refresh it
## from the session in `refresh`.

signal closed

var s: Session
var title: Label
var content: VBoxContainer
var footer: Label


func setup(sess: Session) -> GameMenu:
	s = sess
	add_theme_stylebox_override("panel", UIStyle.panel_box())
	set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor_left = 0.06
	anchor_right = 0.94
	anchor_top = 0.06
	anchor_bottom = 0.94
	offset_left = 0
	offset_right = 0
	offset_top = 0
	offset_bottom = 0
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	title = UIStyle.label("", 24, UIStyle.AMBER)
	v.add_child(title)
	content = VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	v.add_child(content)
	footer = UIStyle.label("", 14, UIStyle.DIM, UIStyle.mono())
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(footer)
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


## An ItemList styled for the menus, with the mono font.
static func make_list() -> ItemList:
	var l := ItemList.new()
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	l.add_theme_font_override("font", UIStyle.mono())
	l.add_theme_font_size_override("font_size", 15)
	l.max_text_lines = 3
	l.auto_height = false
	l.focus_mode = Control.FOCUS_ALL
	return l


static func list_move(l: ItemList, d: int) -> void:
	var n := l.item_count
	if n == 0:
		return
	var cur := l.get_selected_items()[0] if l.is_anything_selected() else 0
	var nxt := posmod(cur + d, n)
	for k in n:  # skip non-selectable separators
		if l.is_item_selectable(nxt):
			break
		nxt = posmod(nxt + d, n)
	l.select(nxt)
	l.ensure_current_is_visible()


static func selected(l: ItemList) -> int:
	return l.get_selected_items()[0] if l.is_anything_selected() else -1
