class_name CGChart
extends Control
## Weight-and-balance envelope: x = CG arm (in), y = weight (lb). Green polygon
## = certified limits, red line = MTOW, big dot = take-off, ring = zero fuel,
## the blue line between them is how the CG walks as fuel burns off.

var spec: Aircraft.Spec
var tow := Vector2.ZERO  ## (cg_in, weight_lb)
var zfw := Vector2.ZERO
var ok := true


func _init() -> void:
	custom_minimum_size = Vector2(360, 240)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_data(spec_: Aircraft.Spec, tow_: Vector2, zfw_: Vector2, ok_: bool) -> void:
	spec = spec_
	tow = tow_
	zfw = zfw_
	ok = ok_
	queue_redraw()


func _draw() -> void:
	if spec == null:
		return
	var env: Array = spec.envelope
	var xs := env.map(func(p): return float(p[0])) + [tow.x, zfw.x]
	var ys := env.map(func(p): return float(p[1])) + [tow.y, zfw.y, spec.mtow_lb]
	var x0: float = xs.min() - 2
	var x1: float = xs.max() + 2
	var y0: float = ys.min() - 150
	var y1: float = ys.max() + 150
	var pad := Vector2(44, 18)
	var W := size.x - pad.x - 8
	var H := size.y - pad.y - 22
	var P := func(cg: float, w: float) -> Vector2:
		return Vector2(pad.x + (cg - x0) / (x1 - x0) * W, 8 + H - (w - y0) / (y1 - y0) * H)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var font := UIStyle.mono()
	var axis := Color(0.45, 0.45, 0.45)
	draw_line(P.call(x0, y0), P.call(x1, y0), axis, 1.5)
	draw_line(P.call(x0, y0), P.call(x0, y1), axis, 1.5)
	for k in 5:
		var w := y0 + (y1 - y0) * k / 4.0
		draw_string(font, P.call(x0, w) + Vector2(-42, 4), "%4.0f" % w, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UIStyle.DIM)
	for k in 5:
		var cg := x0 + (x1 - x0) * k / 4.0
		draw_string(font, P.call(cg, y0) + Vector2(-10, 14), "%.0f" % cg, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UIStyle.DIM)
	var poly := PackedVector2Array()
	for p in env:
		poly.append(P.call(p[0], p[1]))
	draw_colored_polygon(poly, Color(0.3, 1, 0.4, 0.12))
	poly.append(poly[0])
	draw_polyline(poly, Color(0.3, 1, 0.4), 2.0)
	draw_line(P.call(x0, spec.mtow_lb), P.call(x1, spec.mtow_lb), Color(1, 0.4, 0.3), 1.5)
	draw_string(font, P.call(x1, spec.mtow_lb) + Vector2(-40, -4), "MTOW", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 0.4, 0.3))
	draw_line(P.call(zfw.x, zfw.y), P.call(tow.x, tow.y), Color(0.6, 0.6, 1), 2.0)
	draw_arc(P.call(zfw.x, zfw.y), 5, 0, TAU, 16, Color(0.6, 0.6, 1), 2.0)
	draw_circle(P.call(tow.x, tow.y), 6, UIStyle.GREEN if ok else UIStyle.RED)
	draw_string(font, Vector2(pad.x, size.y - 2), "CG (in)   dot=take-off  ring=zero fuel", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UIStyle.DIM)
