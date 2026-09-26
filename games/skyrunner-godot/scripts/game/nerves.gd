class_name Nerves
extends CanvasLayer
## The pilot's nerves. Stress rises with what a real smuggling pilot feared:
## the wanted level, a police aircraft in sight, flying low at night or in a
## storm, fuel running out; a crew in the right seat takes the edge off.
##
## It follows the Yerkes-Dodson curve: moderate arousal is focus (nothing bad
## happens below 0.6), past that it costs you. The screen tunnels and drains
## of colour, you hear your heartbeat, and your hands shake - a physiological
## tremor at 8-12 Hz, the band adrenaline amplifies - on top of your inputs
## (Session.hand_tremor; bots and the autopilot are immune). Rises in seconds,
## settles over half a minute: fear is quick, calm is slow.

const RISE_S := 4.0
const FALL_S := 25.0
const TREMOR_FROM := 0.6
const TREMOR_MAX := 0.12  ## of full aileron/elevator travel at stress 1

var stress := 0.0
var bpm := 70.0
var overlay: ColorRect
var mat: ShaderMaterial
var beat: AudioStreamPlayer
var _beat_phase := 0.0
var _pulse := 0.0
var _t := 0.0
var enabled := true


func setup() -> Nerves:
	name = "nerves"
	layer = 5  # over the 3D view, under the HUD and menus
	overlay = ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/nerves.gdshader")
	overlay.material = mat
	overlay.visible = false
	add_child(overlay)
	beat = AudioStreamPlayer.new()
	beat.stream = heartbeat_wav()
	beat.volume_db = -40.0
	add_child(beat)
	return self


## What the situation says your stress should be, 0..1.
static func target(s: Session) -> float:
	if s.phase != "flying" or s.state == null:
		return 0.0
	var st := s.state
	var t := 0.08
	var c = s.police.cases.get("runner")
	if c != null:
		t += 0.17 * c.wanted
		if c.suspicion >= 50 and c.wanted == 0:
			t += 0.08
	var near := 1e9
	for u in s.police.units:
		if u.faction() == "police" and u.state != "crashed":
			near = minf(near, Vector2(u.x - st.x, u.y - st.y).length())
			if u.sees_player:
				t += 0.25
				break
	if near < 3000.0:
		t += 0.12
	var agl := st.alt - s.world.ground(st.x, st.y)
	var dark: bool = s.weather.get("sky", "clear") == "storm" or float(s.weather.get("moon", 0.5)) < 0.2
	if agl < 80.0:
		t += (0.08 if not dark else 0.18) * (1.0 - agl / 80.0)
	if s.weather.get("sky", "") == "storm":
		t += 0.1
	var cap: float = s.loadout.mass.fuel_capacity_lb()
	if cap > 0 and st.fuel_lb / cap < 0.12:
		t += 0.15
	if Py.truthy(s.copilot):
		t *= 0.75
	return clampf(t, 0.0, 1.0)


func update(s: Session, dt: float) -> void:
	_t += dt
	var goal := target(s) if enabled else 0.0
	var tau := RISE_S if goal > stress else FALL_S
	stress += (goal - stress) * (1.0 - exp(-dt / tau))
	bpm = 68.0 + 105.0 * stress
	# physiological tremor: incommensurate sines in the 8-12 Hz band, so it never repeats
	var amp := maxf(0.0, stress - TREMOR_FROM) / (1.0 - TREMOR_FROM) * TREMOR_MAX
	s.hand_tremor = Vector2(sin(_t * TAU * 8.7) + 0.6 * sin(_t * TAU * 11.3 + 1.7),
		sin(_t * TAU * 9.4 + 0.5) + 0.5 * sin(_t * TAU * 12.1)) * amp * 0.625 if amp > 0.0 else Vector2.ZERO
	# the heartbeat
	_beat_phase += dt * bpm / 60.0
	if _beat_phase >= 1.0:
		_beat_phase -= 1.0
		_pulse = 1.0
		if stress > 0.45 and beat.is_inside_tree():
			beat.volume_db = lerpf(-26.0, -4.0, (stress - 0.45) / 0.55)
			beat.play()
	_pulse = maxf(0.0, _pulse - dt * 4.0)
	overlay.visible = stress > 0.3
	mat.set_shader_parameter("stress", stress)
	mat.set_shader_parameter("pulse", _pulse)


## "Lub-dub": two low thumps, synthesized once (no audio files in the repo).
static func heartbeat_wav() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.45)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		for thump in [[0.0, 1.0, 52.0], [0.17, 0.7, 46.0]]:
			var u: float = t - thump[0]
			if u >= 0.0:
				v += thump[1] * sin(TAU * thump[2] * u) * exp(-u * 28.0) * minf(1.0, u * 400.0)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w
