class_name UIStyle
extends RefCounted
## Shared colours, fonts and widget helpers for the HUD, menus and stations.

const WHITE := Color(1, 1, 1)
const AMBER := Color(1, 0.75, 0.2)
const RED := Color(1, 0.25, 0.2)
const GREEN := Color(0.4, 1, 0.45)
const CYAN := Color(0.5, 0.9, 1)
const DIM := Color(0.8, 0.8, 0.8)
const PANEL := Color(0.02, 0.03, 0.05, 0.88)

static var _mono: SystemFont


static func mono() -> Font:
	if _mono == null:
		_mono = SystemFont.new()
		_mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Consolas", "Menlo", "monospace"])
	return _mono


static func label(text := "", size := 16, color := WHITE, font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	if font != null:
		l.add_theme_font_override("font", font)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func panel_box(color := PANEL) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	return sb


static func bearing_to(x0: float, y0: float, x1: float, y1: float) -> float:
	return fposmod(rad_to_deg(atan2(x1 - x0, y1 - y0)), 360.0)


## PAPI lights left->right: 'W' white, 'R' red. 2W2R = on a 3.5 deg path.
static func papi(alt: float, dist_m: float, field_elev: float) -> String:
	if dist_m <= 1:
		return "...."
	var ang := rad_to_deg(atan2(alt - field_elev, dist_m))
	var whites := 0
	for t in [2.9, 3.3, 3.7, 4.1]:
		if ang > t:
			whites += 1
	return "W".repeat(whites) + "R".repeat(4 - whites)
