class_name DataTable
extends Tree
## A real table for the menus and desks: titled columns, numbers right-aligned in
## the mono font, per-row colours, non-selectable section rows, and the same
## keyboard contract the old ItemLists had (`move`, `select`, `selected_row`).
## Mouse: click selects, double-click activates.
##
##   var t := DataTable.new().setup([{"title": "Job", "expand": true},
##       {"title": "Pay", "align": "right", "mono": true, "min": 80}])
##   t.add_row(["Mail x3 -> QRY", "$918"], {"color": UIStyle.WHITE})

signal row_selected(i: int)
signal row_activated(i: int)

var defs: Array = []
var _items: Array = []  ## TreeItem per row
var _ok: Array = []  ## selectable per row


func setup(columns_: Array) -> DataTable:
	hide_root = true
	column_titles_visible = true
	select_mode = Tree.SELECT_ROW
	focus_mode = Control.FOCUS_CLICK
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_horizontal_enabled = false
	theme = UIStyle.theme()
	item_selected.connect(func(): row_selected.emit(selected_row()))
	item_activated.connect(func(): row_activated.emit(selected_row()))
	configure(columns_)
	return self


## Swap the column set (the station desk shows different tables per tab).
func configure(columns_: Array) -> void:
	defs = columns_
	clear()
	_items.clear()
	_ok.clear()
	columns = defs.size()
	for i in defs.size():
		var d: Dictionary = defs[i]
		set_column_title(i, str(d.get("title", "")).to_upper())
		set_column_title_alignment(i, _align(d))
		set_column_expand(i, d.get("expand", false))
		set_column_expand_ratio(i, int(d.get("ratio", 1)))
		set_column_custom_minimum_width(i, int(d.get("min", 70)))
		set_column_clip_content(i, true)
	create_item()


static func _align(d: Dictionary) -> HorizontalAlignment:
	return {"right": HORIZONTAL_ALIGNMENT_RIGHT, "center": HORIZONTAL_ALIGNMENT_CENTER}.get(d.get("align", ""), HORIZONTAL_ALIGNMENT_LEFT)


func clear_rows() -> void:
	clear()
	create_item()
	_items.clear()
	_ok.clear()


func row_count() -> int:
	return _items.size()


## Append a row. opts: color, cell_colors {col: Color}, selectable, tooltip.
func add_row(cells: Array, opts := {}) -> int:
	var it := create_item(get_root())
	var col: Color = opts.get("color", Color(0.9, 0.92, 0.95))
	var cc: Dictionary = opts.get("cell_colors", {})
	for i in mini(cells.size(), defs.size()):
		it.set_text(i, str(cells[i]))
		it.set_text_alignment(i, _align(defs[i]))
		it.set_custom_color(i, cc.get(i, col))
		if defs[i].get("mono", false):
			it.set_custom_font(i, UIStyle.mono())
		if opts.has("tooltip"):
			it.set_tooltip_text(i, opts["tooltip"])
	var ok: bool = opts.get("selectable", true)
	for i in defs.size():
		it.set_selectable(i, ok)
	_items.append(it)
	_ok.append(ok)
	return _items.size() - 1


## A non-selectable group heading, written in the first wide column.
func section(text: String) -> int:
	var col := 0
	for c in defs.size():
		if defs[c].get("expand", false):
			col = c
			break
	var cells := []
	for c in col:
		cells.append("")
	cells.append(text.to_upper())
	var i := add_row(cells, {"selectable": false, "color": UIStyle.ACCENT})
	for c in defs.size():
		_items[i].set_custom_bg_color(c, Color(1, 1, 1, 0.03))
	return i


func set_cell(row: int, col: int, text: String, color = null) -> void:
	if row < 0 or row >= _items.size():
		return
	_items[row].set_text(col, text)
	if color != null:
		_items[row].set_custom_color(col, color)


func set_row_color(row: int, color: Color) -> void:
	if row < 0 or row >= _items.size():
		return
	for c in defs.size():
		_items[row].set_custom_color(c, color)


func cell(row: int, col: int) -> String:
	return _items[row].get_text(col) if row >= 0 and row < _items.size() else ""


func selectable(row: int) -> bool:
	return row >= 0 and row < _ok.size() and _ok[row]


func selected_row() -> int:
	var it := get_selected()
	return _items.find(it) if it != null else -1


func select(row: int) -> void:
	if not selectable(row):
		return
	_items[row].select(0)
	scroll_to_item(_items[row])


## Keyboard step, skipping section rows and wrapping round.
func move(d: int) -> void:
	var n := _items.size()
	if n == 0:
		return
	var cur := selected_row()
	var nxt := posmod((cur if cur >= 0 else (-1 if d > 0 else 0)) + d, n)
	for k in n:
		if _ok[nxt]:
			break
		nxt = posmod(nxt + d, n)
	select(nxt)


## First selectable row at or after `row` (or the last one).
func select_near(row: int) -> void:
	for k in range(maxi(0, row), _items.size()):
		if _ok[k]:
			select(k)
			return
	for k in range(mini(row, _items.size() - 1), -1, -1):
		if _ok[k]:
			select(k)
			return
