class_name TalkBalloon
extends CanvasLayer
## A conversation on screen: the speaker's name in neon script, the line, and
## the answers you can give (numbered; 1-6 or a click). ENTER or SPACE moves
## on when there's nothing to choose; ESC walks away. Drives Talk's Dialogue
## Manager scripts one line at a time, re-reading the game (State.refresh)
## before each so the numbers are current.

signal finished

var resource: DialogueResource
var state: Talk.State
var line: DialogueLine = null
var lines_shown := 0
var panel: PanelContainer
var who: Label
var text: Label
var choices: VBoxContainer
var hint: Label
var _answers: Array = []  ## the DialogueResponses offered now


func _ready() -> void:
	layer = 60
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UIStyle.theme()
	add_child(root)
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.box(Color(0.06, 0.02, 0.09, 0.94), 10, UIStyle.PINK, 2, Vector4(22, 14, 22, 14)))
	panel.anchor_left = 0.18
	panel.anchor_right = 0.82
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -250
	panel.offset_bottom = -24
	root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	who = UIStyle.title("", 26, UIStyle.PINK)
	v.add_child(who)
	text = UIStyle.label("", 19, UIStyle.WHITE)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(text)
	choices = VBoxContainer.new()
	choices.add_theme_constant_override("separation", 4)
	v.add_child(choices)
	hint = UIStyle.caption("")
	v.add_child(hint)


## Start `title` of `resource` with `state`; `finished` fires when it ends.
func start(resource_: DialogueResource, title: String, state_: Talk.State) -> void:
	resource = resource_
	state = state_
	await _next(title)


func _next(id: String) -> void:
	if state != null:
		state.refresh()
	line = await Talk.manager().get_next_dialogue_line(resource, id, [state])
	if line == null:
		_close()
		return
	if line.text != "" or line.responses.is_empty():
		# (a line that's only answers keeps the last speaker's words on screen)
		lines_shown += 1
		who.text = line.character
		who.visible = line.character != ""
		text.text = line.text
	for c in choices.get_children():
		c.queue_free()
	_answers = line.responses.filter(func(r): return r.is_allowed)
	for i in _answers.size():
		var b := Button.new()
		b.text = "%d   %s" % [i + 1, _answers[i].text]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(choose.bind(i))
		choices.add_child(b)
	hint.text = "1-%d answer   ESC walk away" % _answers.size() if not _answers.is_empty() else "ENTER go on   ESC walk away"
	panel.offset_top = -150.0 - 38.0 * _answers.size()  # room for every answer


## Answer with the i-th allowed response.
func choose(i: int) -> void:
	if line == null or i < 0 or i >= _answers.size():
		return
	await _next(_answers[i].next_id)


## Move past a line with nothing to answer.
func advance() -> void:
	if line == null or not _answers.is_empty():
		return
	await _next(line.next_id)


func _close() -> void:
	line = null
	finished.emit()
	queue_free()


func _input(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed and not ev.echo):
		return
	var k: int = ev.keycode
	if k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		advance()
	elif k >= KEY_1 and k <= KEY_6:
		choose(k - KEY_1)
	elif k == KEY_ESCAPE:
		_close()
	else:
		return
	get_viewport().set_input_as_handled()
