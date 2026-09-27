class_name Soundscape
extends Node
## The game's sound, synthesized (no recordings to license) except the UI's
## clicks (Kenney's UI Audio, CC0, in assets/audio/kenney_ui/):
##
##   the aircraft  the engine and propeller (blade-pass harmonics, pitched by
##                 the engine RPM, louder with power), the wind (filtered noise
##                 rising with airspeed), the stall horn, the tyres' rumble
##   the radio     squelch and static when a call comes in
##   the world     gunfire at the ground war's fights and from your own gun,
##                 police helicopters' rotors and cruisers' sirens, go-fast
##                 outboards, surf when you're low over the coast, rain and
##                 thunder with the weather
##   the music     Radio Costa 88 (F7): a synth loop out of 1985 - bass, arp,
##                 gated drums - built note by note the first time it plays
##
## Every sound is a looped or one-shot AudioStreamWAV made once (static cache);
## loops are cut to whole cycles so they don't click. Headless, the dummy audio
## driver plays nothing and nothing breaks.

const RATE := 22050
const ENGINE_F0 := 40.0  ## the loop's blade-pass frequency, Hz (1200 rpm on a two-blade prop)
const MUSIC_BPM := 112.0

static var _cache := {}

var app  ## PilotApp
var engine: AudioStreamPlayer
var wind: AudioStreamPlayer
var horn: AudioStreamPlayer
var rumble: AudioStreamPlayer
var surf: AudioStreamPlayer
var rain: AudioStreamPlayer
var radio: AudioStreamPlayer
var ui: AudioStreamPlayer
var music: AudioStreamPlayer
var world := {}  ## key -> AudioStreamPlayer3D (rotors, sirens, outboards)
var _last_msg = null  ## the newest radio message heard
var _last_msg_set := false
var _law := 0
var _mag := -1
var _t := 0.0
var master_db := 0.0


func setup(app_) -> Soundscape:
	app = app_
	name = "soundscape"
	engine = _player(engine_loop(), -60.0)
	wind = _player(noise_loop("wind", 0.08), -60.0)
	horn = _player(horn_loop(), -60.0)
	rumble = _player(noise_loop("rumble", 0.02), -60.0)
	surf = _player(surf_loop(), -60.0)
	rain = _player(noise_loop("rain", 0.5), -60.0)
	radio = _player(null, -10.0)
	ui = _player(null, -8.0)
	music = _player(null, -12.0)  # Radio Costa 88: built on first play
	var fx = app.scene.fx if app.scene != null else null
	if fx != null and fx.has_signal("lightning"):
		fx.lightning.connect(func(): get_tree().create_timer(1.5).timeout.connect(on_lightning))
	return self


func _player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	add_child(p)
	if stream != null:
		p.play()
	return p


# ------------------------------------------------------------------ synthesis
static func wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


static func _cached(key: String, fn: Callable) -> AudioStreamWAV:
	if not _cache.has(key):
		_cache[key] = fn.call()
	return _cache[key]


## The engine: blade-pass harmonics with a little combustion roughness; one second
## holds exactly ENGINE_F0 cycles, so it loops cleanly. Pitch by RPM / 1200.
static func engine_loop() -> AudioStreamWAV:
	return _cached("engine", func():
		var n := RATE
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 172
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			var v := 0.0
			for k in range(1, 9):
				v += sin(TAU * ENGINE_F0 * k * t + k * 0.7) / pow(k, 0.85)
			v += 0.35 * sin(TAU * ENGINE_F0 * 0.5 * t)  # the firing pulse, half the blade rate
			lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.2
			s[i] = 0.18 * v + 0.12 * lp
		return wav(s, true))


## Filtered noise: `k` is the one-pole filter's step (small = dark rumble, large = hiss).
static func noise_loop(key: String, k: float, seconds := 2.0) -> AudioStreamWAV:
	return _cached("noise-" + key, func():
		var n := int(RATE * seconds)
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = key.hash()
		var lp := 0.0
		for i in n:
			lp += (rng.randf_range(-1.0, 1.0) - lp) * k
			s[i] = lp * (0.9 / sqrt(maxf(k, 0.01)) * 0.3)
		# cross-fade the seam so the loop doesn't tick
		var fade := int(RATE * 0.05)
		for i in fade:
			var a := float(i) / fade
			s[i] = s[i] * a + s[n - fade + i] * (1.0 - a)
		return wav(s.slice(0, n - fade), true))


## The stall horn: a reed at about 1.6 kHz with a little wobble.
static func horn_loop() -> AudioStreamWAV:
	return _cached("horn", func():
		var n := RATE / 2
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			var t := float(i) / RATE
			var ph := fmod(1600.0 * t, 1.0)
			s[i] = 0.25 * (1.0 if ph < 0.5 else -1.0) * (0.85 + 0.15 * sin(TAU * 8.0 * t))
		return wav(s, true))


## Surf: noise under a slow swell (one wave per five-second loop).
static func surf_loop() -> AudioStreamWAV:
	return _cached("surf", func():
		var n := RATE * 5
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 88
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.15
			var swell := pow(0.5 - 0.5 * cos(TAU * t / 5.0), 2.0)
			s[i] = lp * (0.2 + 0.8 * swell) * 0.9
		return wav(s, true))


## A gunshot: a crack of noise and a thump, decaying; the RPG a long boom.
static func shot(tier: String) -> AudioStreamWAV:
	return _cached("shot-" + tier, func():
		var boom := tier == "rpg"
		var n := int(RATE * (1.4 if boom else 0.35))
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = tier.hash()
		var lp := 0.0
		var k: float = {"pistol": 0.6, "rifle": 0.8, "mg": 0.75, "rpg": 0.08}.get(tier, 0.6)
		var decay: float = {"pistol": 28.0, "rifle": 22.0, "mg": 30.0, "rpg": 3.5}.get(tier, 25.0)
		for i in n:
			var t := float(i) / RATE
			lp += (rng.randf_range(-1.0, 1.0) - lp) * k
			var thump := sin(TAU * (90.0 if boom else 140.0) * t) * exp(-t * (6.0 if boom else 40.0))
			s[i] = (lp * 1.4 + 0.7 * thump) * exp(-t * decay)
		return wav(s))


## Radio squelch: a click, a breath of static.
static func squelch() -> AudioStreamWAV:
	return _cached("squelch", func():
		var n := int(RATE * 0.22)
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in n:
			var t := float(i) / RATE
			var click := 0.8 * exp(-t * 400.0)
			s[i] = (rng.randf_range(-1.0, 1.0) * 0.35 + click) * (1.0 - t / 0.22)
		return wav(s))


## Thunder: a long low rumble that rolls and fades.
static func thunder() -> AudioStreamWAV:
	return _cached("thunder", func():
		var n := RATE * 4
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 1986
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.03
			s[i] = lp * 6.0 * exp(-t * 0.9) * (0.6 + 0.4 * sin(TAU * 1.3 * t))
		return wav(s))


## A helicopter: blade slaps at 18 Hz (a whole number per one-second loop).
static func rotor_loop() -> AudioStreamWAV:
	return _cached("rotor", func():
		var n := RATE
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 60
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.1
			var ph := fmod(18.0 * t, 1.0)
			s[i] = lp * 2.2 * exp(-ph * 9.0) + 0.1 * sin(TAU * 36.0 * t)
		return wav(s, true))


## A police siren: the two-tone wail (1 s up, 1 s down, phase kept continuous).
static func siren_loop() -> AudioStreamWAV:
	return _cached("siren", func():
		var n := RATE * 2
		var s := PackedFloat32Array()
		s.resize(n)
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			var f := 700.0 + 500.0 * (0.5 - 0.5 * cos(PI * t))
			ph += f / RATE
			s[i] = 0.3 * sin(TAU * ph)
		return wav(s, true))


## A go-fast's outboards: a raspy 100 Hz buzz (whole cycles per second).
static func outboard_loop() -> AudioStreamWAV:
	return _cached("outboard", func():
		var n := RATE
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 350
		for i in n:
			var t := float(i) / RATE
			var saw := 2.0 * fmod(100.0 * t, 1.0) - 1.0
			s[i] = 0.25 * saw + 0.08 * rng.randf_range(-1.0, 1.0)
		return wav(s, true))


## Radio Costa 88: four bars of 1985 - A minor, F, C, G - bass, a square-wave
## arpeggio, gated kick and snare, hats. Built once, looped.
static func music_loop() -> AudioStreamWAV:
	return _cached("music", func():
		var beat := 60.0 / MUSIC_BPM
		var n := int(RATE * beat * 16.0)
		var s := PackedFloat32Array()
		s.resize(n)
		var chords := [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]  # MIDI: Am F C G
		var rng := RandomNumberGenerator.new()
		rng.seed = 88
		for i in n:
			var t := float(i) / RATE
			var b := t / beat  # beats
			var bar := int(b / 4.0) % 4
			var ch: Array = chords[bar]
			var v := 0.0
			# bass: eighth notes on the root, an octave down
			var bf := 440.0 * pow(2.0, (float(ch[0]) - 12.0 - 69.0) / 12.0)
			var e8 := fmod(b * 2.0, 1.0)
			v += 0.22 * (2.0 * fmod(bf * t, 1.0) - 1.0) * exp(-e8 * 2.5)
			# arpeggio: sixteenths up the chord, square wave
			var step := int(b * 4.0) % 3
			var af := 440.0 * pow(2.0, (float(ch[step]) + 12.0 - 69.0) / 12.0)
			var e16 := fmod(b * 4.0, 1.0)
			v += 0.09 * (1.0 if fmod(af * t, 1.0) < 0.5 else -1.0) * exp(-e16 * 4.0)
			# pad: the chord, soft
			for m in ch:
				v += 0.035 * sin(TAU * 440.0 * pow(2.0, (float(m) - 69.0) / 12.0) * t)
			# drums: kick on every beat, a gated snare on 2 and 4, hats on the eighths
			var eb := fmod(b, 1.0)
			v += 0.5 * sin(TAU * (55.0 + 90.0 * exp(-eb * 30.0)) * t) * exp(-eb * 9.0)
			if int(b) % 2 == 1:
				v += 0.28 * rng.randf_range(-1.0, 1.0) * (1.0 if eb < 0.18 else 0.0)
			v += 0.05 * rng.randf_range(-1.0, 1.0) * exp(-e8 * 40.0)
			s[i] = v * 0.8
		return wav(s, true))


# ------------------------------------------------------------------ playing it
func click(kind := "click") -> void:
	var f: String = {"click": "click1", "choose": "click3", "hover": "rollover2", "toggle": "switch3", "alert": "switch7"}.get(kind, "click1")
	var path := "res://assets/audio/kenney_ui/%s.wav" % f
	if ResourceLoader.exists(path):
		ui.stream = load(path)
		ui.play()


func toggle_music() -> bool:
	if music.playing:
		music.stop()
	else:
		if music.stream == null:
			music.stream = music_loop()
		music.play()
	return music.playing


## A one-shot at a world position (3D, falls off with distance).
func play_at(stream: AudioStream, pos: Vector3, db := 0.0) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = db
	p.unit_size = 40.0
	p.max_distance = 3000.0
	add_child(p)
	p.global_position = pos
	p.play()
	p.finished.connect(p.queue_free)


func _loop3d(key: String, stream: AudioStream, pos: Vector3, db: float) -> void:
	var p: AudioStreamPlayer3D = world.get(key)
	if p == null:
		p = AudioStreamPlayer3D.new()
		p.stream = stream
		p.unit_size = 60.0
		p.max_distance = 4000.0
		p.volume_db = db
		add_child(p)
		p.play()
		world[key] = p
	p.global_position = pos
	p.set_meta("seen", true)


static func _db(x: float) -> float:
	return -60.0 if x <= 0.001 else linear_to_db(x)


func _process(dt: float) -> void:
	if app == null or app.s == null:
		return
	var s = app.s
	var st = s.state
	var flying: bool = st != null and s.runner_active() and not s.phase in ["crashed", "busted", "custody"] and not app.on_foot
	var inside: bool = app.cam_mode == "cockpit"
	# the aircraft
	if flying and st.engine_running:
		engine.pitch_scale = clampf(st.rpm / 1200.0, 0.3, 3.0)
		engine.volume_db = _db((0.35 + 0.65 * clampf((st.rpm - 600.0) / 2100.0, 0.0, 1.0)) * (1.0 if inside else 0.55)) + master_db
	else:
		engine.volume_db = -60.0
	if flying:
		var ias: float = maxf(0.0, st.ias_kts)
		wind.volume_db = _db(clampf(ias / 160.0, 0.0, 1.0) * (0.45 if inside else 0.8)) + master_db
		wind.pitch_scale = clampf(0.6 + ias / 120.0, 0.5, 2.5)
		horn.volume_db = (-6.0 if st.stall_warning and not st.on_ground else -60.0) + master_db
		rumble.volume_db = _db(clampf(st.gs_kts / 40.0, 0.0, 1.0) * 0.8 if st.on_ground else 0.0) + master_db
		rumble.pitch_scale = clampf(0.6 + st.gs_kts / 60.0, 0.5, 2.0)
	else:
		wind.volume_db = -60.0
		horn.volume_db = -60.0
		rumble.volume_db = -60.0
	# the coast and the weather
	var cam: Vector3 = app.cam.global_position if app.cam != null else Vector3.ZERO
	var low: float = clampf(1.0 - (cam.y - 0.0) / 150.0, 0.0, 1.0)
	var near_water: bool = s.world.is_water(cam.x, -cam.z) or s.world.is_water(cam.x + 300.0, -cam.z) or s.world.is_water(cam.x - 300.0, -cam.z)
	surf.volume_db = _db(low * (0.6 if near_water else 0.0)) + master_db
	var sky: String = str(s.weather.get("sky", "clear")) if s.weather is Dictionary else "clear"
	rain.volume_db = _db(0.5 if sky == "storm" else (0.15 if sky == "rain" else 0.0)) + master_db
	# our own gun
	var foot = s.foot
	if foot != null and foot.active and foot.tier != "":
		if _mag >= 0 and foot.mag < _mag:
			radio.stream = shot(foot.tier)
			radio.play()
		_mag = foot.mag
	else:
		_mag = -1
	_radio(s, flying)
	_t += dt
	if _t < 0.1:
		return
	_t = 0.0
	_world_sounds(s)


## The radio: a squelch when a call comes in, and the call read aloud when
## that's on. (The log keeps only the last 8 lines: compare the newest.)
func _radio(s, flying: bool) -> void:
	var newest = s.messages.back() if not s.messages.is_empty() else null
	if newest == _last_msg:
		return
	if newest != null and _last_msg_set:
		if flying and radio != null:
			radio.stream = squelch()
			radio.play()
		Speech.say(str(newest[1]))
	_last_msg = newest
	_last_msg_set = true


func _world_sounds(s) -> void:
	for k in world:
		world[k].set_meta("seen", false)
	for u in s.police.units:
		if u.state == "crashed":
			continue
		var pos := Vector3(u.x, u.z, -u.y)
		if u.kind == "heli":
			_loop3d("rotor-" + u.id, rotor_loop(), pos, 6.0)
	for b in s.maritime.boats:
		if b.kind == "gofast" and not b.state in ["seized", "delivered", "waiting"]:
			_loop3d("boat-" + b.id, outboard_loop(), Vector3(b.x, 1.0, -b.y), 2.0)
	if s.ground != null:
		for q in s.ground.squads:
			if q.faction == "police" and q.kind == "car" and q.state == "moving" and q.order.get("type", "") in ["raid", "attack"]:
				_loop3d("siren-" + q.id, siren_loop(), Vector3(q.x, s.world.ground(q.x, q.y) + 1.5, -q.y), -2.0)
		# gunfire at the fights: a few shots a second each, from where they are
		for f in s.ground.fights:
			if randf() < 0.45:
				var tier := "rifle" if randf() < 0.7 else "pistol"
				play_at(shot(tier), Vector3(f.x + randf_range(-20, 20), s.world.ground(f.x, f.y) + 1.5, -(f.y + randf_range(-20, 20))), -4.0)
	for k in world.keys():
		if not world[k].get_meta("seen", false):
			world[k].queue_free()
			world.erase(k)


## Lightning: thunder a moment later.
func on_lightning() -> void:
	radio.stream = thunder()
	radio.play()


func stats() -> Dictionary:
	return {"engine_db": engine.volume_db, "wind_db": wind.volume_db, "horn_db": horn.volume_db, "world": world.size(),
		"music": music.playing}
