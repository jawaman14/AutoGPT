class_name UpgradeTree
extends VBoxContainer
## One side's upgrade trees (Upgrades.TREES) as a table: a section per tree,
## each node indented under the one it needs, with its state - OWNED, the price
## when it can be bought now, or what's in the way. The owner feeds it what's
## owned and the money with `update`; ENTER or a double-click emits `buy`.
##
##   var t := UpgradeTree.new().setup("law")
##   t.buy.connect(func(id): link.send_command("upgrade", {"id": id}))
##   t.update(snap.upgrades, snap.law_funds)

signal buy(id: String)

var side := "runner"
var table: DataTable
var detail: Label
var ids: Array = []  ## node id per table row ("" for section rows)
var owned := {}
var funds := 0


func setup(side_: String) -> UpgradeTree:
	side = side_
	add_theme_constant_override("separation", 6)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	table = DataTable.new().setup([
		{"title": "Upgrade", "expand": true, "ratio": 3, "min": 220},
		{"title": "Cost", "align": "right", "mono": true, "min": 80},
		{"title": "State", "expand": true, "ratio": 2, "min": 140},
	])
	table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	table.row_activated.connect(func(_i): activate())
	table.row_selected.connect(func(_i): _detail())
	add_child(table)
	detail = UIStyle.label("", 14, UIStyle.DIM)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.custom_minimum_size = Vector2(0, 40)
	add_child(detail)
	return self


## How deep a node sits in its tree: 0 for a root, else one more than its first parent.
static func depth(side_: String, id: String) -> int:
	var n := Upgrades.node(side_, id)
	if n.is_empty() or n.req.is_empty():
		return 0
	return 1 + depth(side_, n.req[0])


func update(owned_: Variant, funds_: int) -> void:
	owned = {}
	for k in (owned_ if owned_ is Array else (owned_ as Dictionary).keys()):
		owned[k] = true
	funds = funds_
	var keep := table.selected_row()
	table.clear_rows()
	ids = []
	for tree in Upgrades.TREES[side]:
		table.section(str(tree[1]).to_upper())
		ids.append("")
		for n in tree[2]:
			var why := Upgrades.blocker(side, n.id, owned, funds)
			var state := "OWNED" if owned.has(n.id) else ("buy" if why == "" else why.trim_suffix("."))
			var col := UIStyle.GREEN if owned.has(n.id) else (UIStyle.WHITE if why == "" else UIStyle.CAPTION)
			var indent := "    ".repeat(depth(side, n.id))
			table.add_row([indent + ("└ " if indent != "" else "") + str(n.name), "$" + Py.money(int(n.cost)), state],
				{"color": col, "cell_colors": {2: UIStyle.GREEN if owned.has(n.id) else (UIStyle.AMBER if why == "" else UIStyle.CAPTION)}})
			ids.append(n.id)
	table.select_near(keep if keep >= 0 else 1)
	_detail()


func selected_id() -> String:
	var i := table.selected_row()
	return ids[i] if i >= 0 and i < ids.size() else ""


func move(d: int) -> void:
	table.move(d)
	_detail()


func activate() -> void:
	var id := selected_id()
	if id != "":
		buy.emit(id)


func _detail() -> void:
	var id := selected_id()
	detail.text = str(Upgrades.node(side, id).get("desc", "")) if id != "" else ""
