class_name MassData
extends RefCounted
## Mass numbers read from the aircraft data files (empty weight and CG, the
## fuel tanks, the gear height), and the tiny XML DOM the flight model's loader
## shares.

const DATA_ROOT := "res://data/jsbsim"
const _UNIT_TO_IN := {"IN": 1.0, "FT": 12.0, "M": 39.3701}
const _UNIT_TO_LB := {"LBS": 1.0, "KG": 2.20462}

var empty_lb: float
var empty_cg_x_in: float
var tanks: Array  ## [[x_in, capacity_lb]]
var gear_height_ft: float  ## CG height above ground when sitting on the gear

static var _cache := {}


func fuel_capacity_lb() -> float:
	var s := 0.0
	for t in tanks:
		s += t[1]
	return s


# ------------------------------------------------------------------ tiny DOM
class XNode:
	var tag: String
	var attrs := {}
	var text := ""
	var children: Array[XNode] = []

	func find(t: String) -> XNode:
		for c in children:
			if c.tag == t:
				return c
		return null

	func find_where(t: String, attr: String, value: String) -> XNode:
		for c in children:
			if c.tag == t and c.attrs.get(attr, "") == value:
				return c
		return null

	func iter(t: String, out: Array[XNode] = []) -> Array[XNode]:
		if tag == t:
			out.append(self)
		for c in children:
			c.iter(t, out)
		return out

	func attr(k: String, default := "") -> String:
		return attrs.get(k, default)


static func parse_xml(path: String) -> XNode:
	var p := XMLParser.new()
	if p.open(path) != OK:
		push_error("can't open " + path)
		return null
	var root: XNode = null
	var stack: Array[XNode] = []
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := XNode.new()
				n.tag = p.get_node_name()
				for i in p.get_attribute_count():
					n.attrs[p.get_attribute_name(i)] = p.get_attribute_value(i)
				if stack.is_empty():
					root = n
				else:
					stack.back().children.append(n)
				if not p.is_empty():
					stack.append(n)
			XMLParser.NODE_ELEMENT_END:
				stack.pop_back()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if not stack.is_empty():
					stack.back().text += p.get_node_data()
	return root


static func _loc_in(el: XNode, axis: String) -> float:
	var loc := el if el.tag == "location" else el.find("location")
	return float(loc.find(axis).text.strip_edges()) * _UNIT_TO_IN[loc.attr("unit", "IN").to_upper()]


static func read(model: String, root := DATA_ROOT) -> MassData:
	var key := root + "|" + model
	if _cache.has(key):
		return _cache[key]
	var tree := parse_xml("%s/aircraft/%s/%s.xml" % [root, model, model])
	var mb := tree.find("mass_balance")
	var empty := mb.find("emptywt")
	var md := MassData.new()
	md.empty_lb = float(empty.text.strip_edges()) * _UNIT_TO_LB[empty.attr("unit", "LBS").to_upper()]
	var cg := mb.find_where("location", "name", "CG")
	md.empty_cg_x_in = _loc_in(cg, "x")
	md.tanks = []
	for t in tree.iter("tank"):
		if t.attr("type", "FUEL").to_upper() != "FUEL":
			continue
		var cap := t.find("capacity")
		md.tanks.append([_loc_in(t, "x"), float(cap.text.strip_edges()) * _UNIT_TO_LB[cap.attr("unit", "LBS").to_upper()]])
	var gear_z := []
	for c in tree.find("ground_reactions").iter("contact"):
		if c.attr("type") == "BOGEY":
			gear_z.append(_loc_in(c, "z"))
	md.gear_height_ft = (_loc_in(cg, "z") - gear_z.min()) / 12.0
	_cache[key] = md
	return md


## The aircraft data root the flight model reads (res://, so exported builds
## read it from the pack). The flight model places the game's load stations
## itself, so nothing is patched any more.
static func patched_root() -> String:
	return DATA_ROOT
