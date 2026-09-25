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
const SURFACE := Color(0.09, 0.10, 0.13)  ## raised surfaces: buttons, table headers
const SURFACE_HI := Color(0.15, 0.17, 0.22)
const LINE := Color(1, 1, 1, 0.09)
const ACCENT := AMBER
const CAPTION := Color(0.62, 0.66, 0.72)

static var _mono: SystemFont
static var _theme: Theme


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


## A rounded flat box: the one building block of the theme.
static func box(bg: Color, radius := 5, border := Color(0, 0, 0, 0), bw := 0, margin := Vector4(10, 6, 10, 6)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.content_margin_left = margin.x
	sb.content_margin_top = margin.y
	sb.content_margin_right = margin.z
	sb.content_margin_bottom = margin.w
	return sb


## The game's one Theme: every Button, list, table, tab bar and field looks the
## same on every screen. Screens set it on their root Control (a CanvasLayer
## breaks theme inheritance, so each top-level panel sets it too).
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = 16
	var focus := box(Color(0, 0, 0, 0), 5, ACCENT, 2)
	focus.draw_center = false
	t.set_stylebox("panel", "PanelContainer", panel_box())
	t.set_stylebox("panel", "Panel", panel_box())
	t.set_color("font_color", "Label", WHITE)
	for cls in ["Button", "OptionButton", "MenuButton", "CheckButton", "CheckBox"]:
		t.set_stylebox("normal", cls, box(SURFACE, 5, LINE, 1))
		t.set_stylebox("hover", cls, box(SURFACE_HI, 5, Color(1, 1, 1, 0.18), 1))
		t.set_stylebox("pressed", cls, box(ACCENT.darkened(0.55), 5, ACCENT, 1))
		t.set_stylebox("hover_pressed", cls, box(ACCENT.darkened(0.45), 5, ACCENT, 1))
		t.set_stylebox("disabled", cls, box(Color(0.06, 0.07, 0.09), 5, Color(1, 1, 1, 0.04), 1))
		t.set_stylebox("focus", cls, focus)
		t.set_color("font_color", cls, Color(0.92, 0.94, 0.97))
		t.set_color("font_hover_color", cls, WHITE)
		t.set_color("font_pressed_color", cls, ACCENT)
		t.set_color("font_hover_pressed_color", cls, ACCENT)
		t.set_color("font_focus_color", cls, WHITE)
		t.set_color("font_disabled_color", cls, Color(0.45, 0.47, 0.5))
	var sel := box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.20), 4, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.7), 1, Vector4(4, 2, 4, 2))
	var empty := StyleBoxEmpty.new()
	for cls in ["ItemList", "Tree"]:
		t.set_stylebox("panel", cls, box(Color(0, 0, 0, 0.28), 5, LINE, 1, Vector4(4, 4, 4, 4)))
		t.set_stylebox("focus", cls, empty)
		t.set_stylebox("selected", cls, sel)
		t.set_stylebox("selected_focus", cls, sel)
		t.set_stylebox("hovered", cls, box(Color(1, 1, 1, 0.05), 4, Color(0, 0, 0, 0), 0, Vector4(4, 2, 4, 2)))
		t.set_stylebox("cursor", cls, empty)
		t.set_stylebox("cursor_unfocused", cls, empty)
		t.set_color("font_color", cls, Color(0.86, 0.88, 0.92))
		t.set_color("font_selected_color", cls, WHITE)
		t.set_color("font_hovered_color", cls, WHITE)
		t.set_color("guide_color", cls, Color(1, 1, 1, 0.05))
	t.set_constant("v_separation", "ItemList", 6)
	t.set_constant("v_separation", "Tree", 6)
	t.set_constant("h_separation", "Tree", 8)
	t.set_constant("draw_guides", "Tree", 1)
	t.set_constant("draw_relationship_lines", "Tree", 0)
	t.set_constant("item_margin", "Tree", 0)
	t.set_stylebox("title_button_normal", "Tree", box(SURFACE, 0, LINE, 0, Vector4(8, 5, 8, 5)))
	t.set_stylebox("title_button_hover", "Tree", box(SURFACE_HI, 0, LINE, 0, Vector4(8, 5, 8, 5)))
	t.set_stylebox("title_button_pressed", "Tree", box(SURFACE_HI, 0, LINE, 0, Vector4(8, 5, 8, 5)))
	t.set_color("title_button_color", "Tree", CAPTION)
	t.set_font_size("title_button_font_size", "Tree", 13)
	var tab_on := box(SURFACE_HI, 5, Color(0, 0, 0, 0), 0, Vector4(14, 6, 14, 6))
	tab_on.border_color = ACCENT
	tab_on.border_width_bottom = 2
	t.set_stylebox("tab_selected", "TabBar", tab_on)
	t.set_stylebox("tab_unselected", "TabBar", box(SURFACE, 5, Color(0, 0, 0, 0), 0, Vector4(14, 6, 14, 6)))
	t.set_stylebox("tab_hovered", "TabBar", box(SURFACE_HI, 5, Color(0, 0, 0, 0), 0, Vector4(14, 6, 14, 6)))
	t.set_stylebox("tab_focus", "TabBar", focus)
	t.set_color("font_selected_color", "TabBar", ACCENT)
	t.set_color("font_unselected_color", "TabBar", CAPTION)
	t.set_color("font_hovered_color", "TabBar", WHITE)
	t.set_stylebox("normal", "LineEdit", box(Color(0, 0, 0, 0.35), 5, Color(1, 1, 1, 0.15), 1))
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_color("font_placeholder_color", "LineEdit", Color(0.5, 0.52, 0.56))
	t.set_stylebox("background", "ProgressBar", box(Color(1, 1, 1, 0.08), 3, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
	t.set_stylebox("fill", "ProgressBar", box(GREEN, 3, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
	t.set_stylebox("slider", "HSlider", box(Color(1, 1, 1, 0.12), 3, Color(0, 0, 0, 0), 0, Vector4(0, 3, 0, 3)))
	t.set_stylebox("grabber_area", "HSlider", box(ACCENT.darkened(0.2), 3, Color(0, 0, 0, 0), 0, Vector4(0, 3, 0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(ACCENT, 3, Color(0, 0, 0, 0), 0, Vector4(0, 3, 0, 3)))
	for cls in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", cls, box(Color(1, 1, 1, 0.03), 4, Color(0, 0, 0, 0), 0, Vector4(3, 3, 3, 3)))
		t.set_stylebox("grabber", cls, box(Color(1, 1, 1, 0.16), 4))
		t.set_stylebox("grabber_highlight", cls, box(Color(1, 1, 1, 0.3), 4))
		t.set_stylebox("grabber_pressed", cls, box(ACCENT.darkened(0.3), 4))
	t.set_stylebox("panel", "PopupMenu", box(Color(0.07, 0.08, 0.1), 5, LINE, 1, Vector4(4, 4, 4, 4)))
	t.set_stylebox("hover", "PopupMenu", box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22), 3))
	t.set_color("font_hover_color", "PopupMenu", WHITE)
	_theme = t
	return t


## Section heading: small caps-style caption over a group of widgets.
static func caption(text: String) -> Label:
	var l := label(text.to_upper(), 12, CAPTION)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)
	return l


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
