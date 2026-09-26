class_name ConfirmBox
extends Control
## A modal yes/no over the whole screen ("Leave the co-pilot seat?"). The owner
## routes keys to `key()`: ENTER confirms, ESC cancels; the buttons do the same.

signal answered(yes: bool)

var msg: Label


func setup(text: String, yes_text := "Leave", no_text := "Stay") -> ConfirmBox:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UIStyle.theme()
	visible = false
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	var center := CenterContainer.new()  # the shade covers everything; the panel sits in the middle
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UIStyle.box(Color(0.07, 0.08, 0.11, 0.98), 8, UIStyle.ACCENT, 1, Vector4(22, 18, 22, 18)))
	center.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	p.add_child(v)
	msg = UIStyle.label(text, 20, UIStyle.WHITE)
	v.add_child(msg)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var no := Button.new()
	no.text = "%s  (ESC)" % no_text
	no.pressed.connect(func(): key("esc"))
	row.add_child(no)
	var yes := Button.new()
	yes.text = "%s  (ENTER)" % yes_text
	yes.pressed.connect(func(): key("enter"))
	row.add_child(yes)
	return self


func ask() -> void:
	visible = true


## Returns true when the key was consumed.
func key(k: String) -> bool:
	if not visible:
		return false
	if k == "enter" or k == "esc":
		visible = false
		answered.emit(k == "enter")
		return true
	return true  # modal: swallow everything else
