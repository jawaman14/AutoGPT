class_name FdmFunc
extends RefCounted
## The aircraft data's maths: <function> trees (product, sum, difference,
## quotient, value, property, table) compiled once from the aircraft XML into
## nested arrays, then evaluated against a property Dictionary each step.
## Tables are 1-D, 2-D (a header row of column breakpoints) or 3-D (one 2-D
## table per <tableData breakPoint="...">), linearly interpolated and clamped
## at the ends, as the aircraft files expect.

const OP_CONST := 0
const OP_PROP := 1
const OP_PRODUCT := 2
const OP_SUM := 3
const OP_DIFF := 4
const OP_QUOT := 5
const OP_TABLE := 6
const OP_ABS := 7


## A <function> element (or any expression element) -> an expression array.
static func compile(n: MassData.XNode) -> Array:
	match n.tag:
		"function":
			for c in n.children:
				if c.tag != "description":
					return compile(c)
			return [OP_CONST, 0.0]
		"value":
			return [OP_CONST, float(n.text.strip_edges())]
		"property":
			var name := n.text.strip_edges()
			var neg := name.begins_with("-")
			return [OP_PROP, name.trim_prefix("-"), -1.0 if neg else 1.0]
		"product", "sum", "difference", "quotient":
			var args := []
			for c in n.children:
				if c.tag != "description":
					args.append(compile(c))
			var op: int = {"product": OP_PRODUCT, "sum": OP_SUM, "difference": OP_DIFF, "quotient": OP_QUOT}[n.tag]
			return [op, args]
		"abs":
			return [OP_ABS, compile(n.children[0])]
		"table":
			return [OP_TABLE, table(n)]
	push_warning("FdmFunc: unsupported <%s>, read as 0" % n.tag)
	return [OP_CONST, 0.0]


static func eval(e: Array, p: Dictionary) -> float:
	match int(e[0]):
		OP_CONST:
			return e[1]
		OP_PROP:
			return float(p.get(e[1], 0.0)) * e[2]
		OP_PRODUCT:
			var v := 1.0
			for a in e[1]:
				v *= eval(a, p)
			return v
		OP_SUM:
			var v := 0.0
			for a in e[1]:
				v += eval(a, p)
			return v
		OP_DIFF:
			var args: Array = e[1]
			var v := eval(args[0], p)
			for i in range(1, args.size()):
				v -= eval(args[i], p)
			return v
		OP_QUOT:
			var d := eval(e[1][1], p)
			return eval(e[1][0], p) / d if d != 0.0 else 0.0
		OP_ABS:
			return absf(eval(e[1], p))
		OP_TABLE:
			return lookup(e[1], p)
	return 0.0


# ------------------------------------------------------------------ tables
## {vars: [row, column, table], rows, cols, data (row-major), slices (3-D: [[bp, table], ...])}
static func table(n: MassData.XNode) -> Dictionary:
	var t := {"vars": [], "rows": PackedFloat64Array(), "cols": PackedFloat64Array(), "data": PackedFloat64Array(), "slices": []}
	for c in n.children:
		if c.tag == "independentVar":
			var look: String = c.attr("lookup", "row" if t.vars.is_empty() else ("column" if t.vars.size() == 1 else "table"))
			var idx: int = {"row": 0, "column": 1, "table": 2}.get(look, t.vars.size())
			while t.vars.size() <= idx:
				t.vars.append("")
			t.vars[idx] = c.text.strip_edges()
	var datas := n.children.filter(func(c): return c.tag == "tableData")
	if datas.size() > 1 or (datas.size() == 1 and datas[0].attrs.has("breakPoint")):
		for d in datas:
			var sub := _grid(d.text)
			t.slices.append([float(d.attr("breakPoint", "0")), sub])
		return t
	if not datas.is_empty():
		var g := _grid(datas[0].text)
		t.rows = g.rows
		t.cols = g.cols
		t.data = g.data
	return t


## Parse tableData text: 1-D (two numbers a line) or 2-D (a first line of
## column breakpoints, then a row value and one number per column).
static func _grid(text: String) -> Dictionary:
	var lines := []
	for ln in text.split("\n"):
		var nums := PackedFloat64Array()
		for tok in ln.strip_edges().split(" ", false):
			for tt in tok.split("\t", false):
				nums.append(float(tt))
		if not nums.is_empty():
			lines.append(nums)
	var g := {"rows": PackedFloat64Array(), "cols": PackedFloat64Array(), "data": PackedFloat64Array()}
	if lines.is_empty():
		return g
	var two_d: bool = lines.size() > 1 and (lines[0] as PackedFloat64Array).size() + 1 == (lines[1] as PackedFloat64Array).size()
	var start := 0
	if two_d:
		g.cols = lines[0]
		start = 1
	for i in range(start, lines.size()):
		var l: PackedFloat64Array = lines[i]
		g.rows.append(l[0])
		for k in range(1, l.size()):
			g.data.append(l[k])
	return g


## Index and fraction of x among ascending breakpoints, clamped at the ends.
static func _seg(bps: PackedFloat64Array, x: float) -> Array:
	var n := bps.size()
	if n <= 1 or x <= bps[0]:
		return [0, 0.0]
	if x >= bps[n - 1]:
		return [n - 2, 1.0]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if bps[mid] <= x:
			lo = mid
		else:
			hi = mid
	return [lo, (x - bps[lo]) / (bps[lo + 1] - bps[lo])]


static func _grid_at(g: Dictionary, x: float, y: float) -> float:
	var rows: PackedFloat64Array = g.rows
	var cols: PackedFloat64Array = g.cols
	var data: PackedFloat64Array = g.data
	if rows.is_empty():
		return 0.0
	var r := _seg(rows, x)
	var i: int = r[0]
	var fr: float = r[1]
	if cols.is_empty():  # 1-D
		if rows.size() == 1:
			return data[0]
		return data[i] + (data[i + 1] - data[i]) * fr
	var nc := cols.size()
	var c := _seg(cols, y)
	var j: int = c[0]
	var fc: float = c[1]
	var i2 := mini(i + 1, rows.size() - 1)
	var j2 := mini(j + 1, nc - 1)
	var a := data[i * nc + j]
	var b := data[i * nc + j2]
	var cc := data[i2 * nc + j]
	var d := data[i2 * nc + j2]
	return (a + (b - a) * fc) + ((cc + (d - cc) * fc) - (a + (b - a) * fc)) * fr


static func lookup(t: Dictionary, p: Dictionary) -> float:
	var vars: Array = t.vars
	var x: float = float(p.get(vars[0], 0.0)) if vars.size() > 0 else 0.0
	var y: float = float(p.get(vars[1], 0.0)) if vars.size() > 1 else 0.0
	if t.slices.is_empty():
		return _grid_at(t, x, y)
	var z: float = float(p.get(vars[2], 0.0)) if vars.size() > 2 else 0.0
	var sl: Array = t.slices
	if z <= sl[0][0]:
		return _grid_at(sl[0][1], x, y)
	for k in range(1, sl.size()):
		if z <= sl[k][0]:
			var f: float = (z - sl[k - 1][0]) / (sl[k][0] - sl[k - 1][0])
			var a := _grid_at(sl[k - 1][1], x, y)
			return a + (_grid_at(sl[k][1], x, y) - a) * f
	return _grid_at(sl[sl.size() - 1][1], x, y)


## A table from an engine/propeller file by name (C_THRUST, C_POWER, ...), or {}.
static func named_table(root: MassData.XNode, name: String) -> Dictionary:
	for t in root.iter("table"):
		if t.attr("name") == name:
			return table(t)
	return {}


## Evaluate a named table with explicit row/column values (no property map).
static func at(t: Dictionary, x: float, y := 0.0) -> float:
	if t.is_empty():
		return 0.0
	return _grid_at(t, x, y)
