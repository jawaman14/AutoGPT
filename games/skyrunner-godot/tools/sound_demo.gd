extends SceneTree
## Writes the synthesized sounds to WAV files for listening (docs/audio/ via ffmpeg):
##   godot --headless --script res://tools/sound_demo.gd -- <out dir>


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var out: String = a[0] if a.size() > 0 else "user://"
	# the engine run-up: idle to full power, the loop resampled by RPM as the game does
	var eng := Soundscape.engine_loop()
	var src := PackedFloat32Array()
	src.resize(eng.data.size() / 2)
	for i in src.size():
		src[i] = eng.data.decode_s16(i * 2) / 32000.0
	var n := Soundscape.RATE * 6
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / Soundscape.RATE
		var rpm := lerpf(700.0, 2500.0, smoothstep(0.5, 4.0, t))
		ph = fmod(ph + rpm / 1200.0, src.size())
		s[i] = src[int(ph)] * (0.4 + 0.6 * (rpm - 700.0) / 1800.0)
	Soundscape.wav(s).save_to_wav(out.path_join("engine-runup.wav"))
	Soundscape.music_loop().save_to_wav(out.path_join("radio-costa-88.wav"))
	var shots := PackedFloat32Array()
	for tier in ["pistol", "pistol", "rifle", "rifle", "rifle", "mg", "mg", "mg", "mg", "rpg"]:
		var w := Soundscape.shot(tier)
		for i in w.data.size() / 2:
			shots.append(w.data.decode_s16(i * 2) / 32000.0)
		for i in int(Soundscape.RATE * 0.12):
			shots.append(0.0)
	Soundscape.wav(shots).save_to_wav(out.path_join("gunfire.wav"))
	var sir := Soundscape.siren_loop()
	var rot := Soundscape.rotor_loop()
	var mix := PackedFloat32Array()
	mix.resize(Soundscape.RATE * 4)
	for i in mix.size():
		mix[i] = sir.data.decode_s16((i % (sir.data.size() / 2)) * 2) / 32000.0 * 0.6 + rot.data.decode_s16((i % (rot.data.size() / 2)) * 2) / 32000.0 * 0.6
	Soundscape.wav(mix).save_to_wav(out.path_join("siren-and-rotor.wav"))
	print("written to ", out)
	quit()
