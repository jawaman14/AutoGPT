class_name ToastFeed
extends VBoxContainer
## Radio and crew messages as toasts: each new line slides in at the bottom,
## holds, then fades. `sync(messages, now)` takes the session's [[t, text]] list
## and only adds what's new, so it can be called every frame.

const LIFE_S := 9.0
const FADE_S := 1.5
const MAX := 6

var _last = null  ## the newest [t, text] already shown


func _init() -> void:
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push(text: String, now: float, color := UIStyle.WHITE) -> void:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := UIStyle.box(Color(0.02, 0.03, 0.05, 0.72), 5, Color(0, 0, 0, 0), 0, Vector4(10, 4, 10, 5))
	sb.border_color = color
	sb.border_width_left = 3
	p.add_theme_stylebox_override("panel", sb)
	var l := UIStyle.label(text, 15, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(l)
	p.set_meta("t", now)
	add_child(p)
	while get_child_count() > MAX:
		var old := get_child(0)
		remove_child(old)
		old.queue_free()


## Colour a message by who's talking.
static func tone(text: String) -> Color:
	if text.begins_with("[copilot]"):
		return UIStyle.CYAN
	if "!" in text and ("police" in text.to_lower() or "wanted" in text.to_lower() or "rival" in text.to_lower()):
		return UIStyle.RED
	if text.begins_with("Accepted") or "paid" in text.to_lower() or text.begins_with("Delivered"):
		return UIStyle.GREEN
	return UIStyle.WHITE


func sync(messages: Array, now: float) -> void:
	var start := 0
	if _last != null:
		start = messages.size()
		for i in range(messages.size() - 1, -1, -1):
			if messages[i][0] == _last[0] and messages[i][1] == _last[1]:
				start = i + 1
				break
			if messages[i][0] > _last[0]:
				start = i  # the last one we showed has scrolled out of the session's log
	for i in range(start, messages.size()):
		var m: Array = messages[i]
		if now - float(m[0]) < LIFE_S:
			push(str(m[1]), float(m[0]), tone(str(m[1])))
	if not messages.is_empty():
		_last = messages.back()
	fade(now)


func fade(now: float) -> void:
	for c in get_children():
		var age: float = now - float(c.get_meta("t", now))
		if age > LIFE_S:
			remove_child(c)
			c.queue_free()
		else:
			c.modulate.a = clampf((LIFE_S - age) / FADE_S, 0.0, 1.0)


func lines() -> Array:
	return get_children().map(func(c): return c.get_child(0).text)
