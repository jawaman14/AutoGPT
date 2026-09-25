class_name Airfield
extends RefCounted
## One strip. Positions are metres in the island frame (x east, y north).

var code: String
var name: String
var x: float
var y: float
var heading: float  ## runway direction, deg true
var length: float  ## m
var width: float  ## m
var elev  ## null -> take natural terrain height at the centre
var surface: String  ## asphalt | gravel | grass | dirt | sand
var kind: String  ## hub | regional | bush | shady
var shop := false
var police := false  ## police presence: inspections when wanted
var radar_km := 0.0
var setting := "flat"  ## flat | plateau | pit | beach
var tree_lines := false
var haul_road  ## pit strips: runway end (0/1) with a graded exit to take off over, else null
var ux: float
var uy: float


func _init(p_code: String, p_name: String, p_x: float, p_y: float, p_heading: float, p_length: float,
		p_width: float, p_elev, p_surface: String, p_kind: String, opts := {}) -> void:
	code = p_code
	name = p_name
	x = p_x
	y = p_y
	heading = p_heading
	length = p_length
	width = p_width
	elev = p_elev
	surface = p_surface
	kind = p_kind
	for k in opts:
		set(k, opts[k])
	var h := deg_to_rad(heading)
	ux = sin(h)
	uy = cos(h)


func dir() -> Array:
	return [ux, uy]


## (along, across) in runway coordinates, origin at the centre.
func to_local(px: float, py: float) -> Array:
	var dx := px - x
	var dy := py - y
	return [dx * ux + dy * uy, dx * uy - dy * ux]


func contains(px: float, py: float, margin := 0.0) -> bool:
	var dx := px - x
	var dy := py - y
	return absf(dx * ux + dy * uy) <= length / 2 + margin and absf(dx * uy - dy * ux) <= width / 2 + margin


## World position of runway end 0 (start of heading) or 1.
func threshold(end: int) -> Array:
	var s := -1.0 if end == 0 else 1.0
	return [x + s * ux * length / 2, y + s * uy * length / 2]


func is_short() -> bool:
	return length < 500


func to_dict() -> Dictionary:
	return {"code": code, "x": x, "y": y, "heading": heading, "length": length, "width": width, "elev": elev,
		"setting": setting, "tree_lines": tree_lines, "haul_road": haul_road}
