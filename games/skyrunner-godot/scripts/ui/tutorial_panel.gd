class_name TutorialPanel
extends PanelContainer
## The tutorial on screen (Tutorial.view()): the current lesson top-centre,
## a tip under it in amber for a while. Hidden when the tutorial is off or has
## nothing to teach right now.

var title: Label
var body: Label
var tip: Label
var foot: Label


func _ready() -> void:
	add_theme_stylebox_override("panel", UIStyle.box(Color(0.05, 0.03, 0.09, 0.9), 8, UIStyle.CYAN, 1, Vector4(16, 10, 16, 10)))
	anchor_left = 0.5
	anchor_right = 0.5
	offset_left = -330
	offset_right = 330
	offset_top = 84
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	title = UIStyle.label("", 17, UIStyle.CYAN)
	v.add_child(title)
	body = UIStyle.label("", 15, UIStyle.WHITE)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(body)
	tip = UIStyle.label("", 14, UIStyle.AMBER)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(tip)
	foot = UIStyle.caption("F10 skip this step   SHIFT+F10 tutorial off")
	v.add_child(foot)
	visible = false


## At the desks: over the map (left), low, clear of the tables on the right.
func dock_left() -> void:
	anchor_left = 0.0
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 16
	offset_right = -16
	offset_top = -16
	offset_bottom = -16
	grow_vertical = Control.GROW_DIRECTION_BEGIN  # as tall as the lesson, growing up from the bottom


func show_view(tv: Dictionary) -> void:
	if tv.is_empty() or not bool(tv.get("on", false)) or (str(tv.id) == "" and str(tv.tip) == ""):
		visible = false
		return
	visible = true
	title.visible = str(tv.id) != ""
	body.visible = title.visible
	title.text = "TUTORIAL %d/%d  -  %s" % [int(tv.step), int(tv.of), tv.title]
	body.text = str(tv.text)
	tip.visible = str(tv.tip) != ""
	tip.text = "TIP: " + str(tv.tip)
