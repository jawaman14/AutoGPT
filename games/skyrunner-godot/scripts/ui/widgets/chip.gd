class_name Chip
extends PanelContainer
## A status pill: XPDR, AP, PUMP, CREW, WX... Lit chips are tinted in their
## colour; dark ones are a quiet outline, so the eye finds what's ON.

var lbl: Label
var _on := false
var _text := ""
var _color := UIStyle.WHITE


func setup(text := "") -> Chip:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl = UIStyle.label(text, 13, UIStyle.CAPTION, UIStyle.mono())
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	add_child(lbl)
	set_state(text, UIStyle.CAPTION, false)
	return self


func set_state(text: String, color: Color, on: bool) -> void:
	if text == _text and color == _color and on == _on and get_theme_stylebox("panel") != null:
		return
	_text = text
	_color = color
	_on = on
	lbl.text = text
	lbl.add_theme_color_override("font_color", color if on else UIStyle.CAPTION)
	# a dark base first, so a chip reads the same over sky, sea or a panel
	var dark := Color(0.03, 0.04, 0.06, 0.82)
	var bg := dark.lerp(Color(color.r, color.g, color.b, 0.9), 0.2) if on else dark
	var border := Color(color.r, color.g, color.b, 0.85) if on else Color(1, 1, 1, 0.14)
	add_theme_stylebox_override("panel", UIStyle.box(bg, 10, border, 1, Vector4(9, 2, 9, 3)))


func text() -> String:
	return _text


func is_on() -> bool:
	return _on
