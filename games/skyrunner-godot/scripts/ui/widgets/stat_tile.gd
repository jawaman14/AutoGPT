class_name StatTile
extends PanelContainer
## A caption, a big value and an optional thin bar: the unit of every readout
## (IAS, fuel, dirty money, evidence...). `set_value("222 lb", colour, 0.6)`.

var cap: Label
var value: Label
var sub: Label
var bar: ProgressBar
var _fill: StyleBoxFlat


func setup(caption_: String, with_bar := false, value_size := 22) -> StatTile:
	add_theme_stylebox_override("panel", UIStyle.box(Color(1, 1, 1, 0.04), 6, UIStyle.LINE, 1, Vector4(10, 6, 10, 6)))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(80, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	cap = UIStyle.caption(caption_)
	cap.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(cap)
	value = UIStyle.label("-", value_size, UIStyle.WHITE, UIStyle.mono())
	value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS  # tiles share a row evenly
	v.add_child(value)
	sub = UIStyle.label("", 12, UIStyle.CAPTION)
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.visible = false
	v.add_child(sub)
	if with_bar:
		bar = ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = 1.0
		bar.custom_minimum_size = Vector2(0, 5)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fill = UIStyle.box(UIStyle.GREEN, 3, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0))
		bar.add_theme_stylebox_override("fill", _fill)
		bar.add_theme_stylebox_override("background", UIStyle.box(Color(1, 1, 1, 0.08), 3, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
		v.add_child(bar)
	return self


func set_value(text: String, color := UIStyle.WHITE, frac := -1.0, subtext := "") -> void:
	value.text = text
	tooltip_text = "%s: %s%s" % [cap.text, text, ("  -  " + subtext) if subtext != "" else ""]
	value.add_theme_color_override("font_color", color)
	sub.text = subtext
	sub.visible = subtext != ""
	if bar != null:
		bar.visible = frac >= 0.0
		bar.value = clampf(frac, 0.0, 1.0)
		_fill.bg_color = color
