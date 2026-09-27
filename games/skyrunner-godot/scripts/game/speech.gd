class_name Speech
extends RefCounted
## Read aloud: the conversations (who speaks, the line, the numbered answers)
## and the radio's messages, through the operating system's own voice
## (Godot's DisplayServer text-to-speech: SAPI on Windows, AVSpeech on macOS,
## speech-dispatcher on Linux). The same approach as GATO's TTS plugin, without
## the plugin. Off by default; F8 turns it on, and it's remembered.
##
## `speaker` can be swapped (tests); `spoken` keeps what was said.

static var enabled := false
static var rate := 1.1
static var spoken: Array = []  ## the last 40 things said
static var speaker := func(text: String, interrupt: bool) -> void:
	var voices := DisplayServer.tts_get_voices_for_language(OS.get_locale_language())
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		return
	DisplayServer.tts_speak(text, voices[0], 80, 1.0, rate, 0, interrupt)


## Can this machine speak at all? (no voices headless, or with no speech engine)
static func available() -> bool:
	if DisplayServer.get_name() == "headless" or not ProjectSettings.get_setting("audio/general/text_to_speech", false):
		return false
	return not DisplayServer.tts_get_voices().is_empty()


static func set_enabled(on: bool) -> void:
	enabled = on
	if not on and available():
		DisplayServer.tts_stop()


## Say it (when reading aloud is on). `interrupt` cuts off whatever was being said.
static func say(text: String, interrupt := false) -> void:
	if not enabled:
		return
	var clean := text.replace("\n", ". ").strip_edges()
	var rx := RegEx.create_from_string("\\[[^\\]]*\\]")  # BBCode tags
	clean = rx.sub(clean, "", true)
	if clean == "":
		return
	spoken.append(clean)
	if spoken.size() > 40:
		spoken.pop_front()
	speaker.call(clean, interrupt)


## A conversation's line and its answers, as one utterance.
static func line(who: String, text: String, answers: Array) -> void:
	var parts := []
	if text != "":
		parts.append(("%s: %s" % [who, text]) if who != "" else text)
	for i in answers.size():
		parts.append("%d, %s" % [i + 1, answers[i]])
	say(". ".join(parts), true)
