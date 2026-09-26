class_name RadioNet
extends RefCounted
## Radio: police dispatch, runner calls, scanners and direction finding.
##
## - Police traffic is plain voice unless the task force pays for encryption.
##   A runner scanner hears plain traffic verbatim, static when encrypted.
## - Every runner transmission (calling the boat) can be heard by DF stations.
##   One bearing gives a line, two give a fix with a few hundred metres of error.

##
## REALISM (the Godot radio; off for the Python parity replays):
##   - VHF line of sight: range 4.12 (sqrt h1 + sqrt h2) km with h in metres
##     above the ground, and the terrain in between must not block the path
##   - channels: police dispatch, police tactical, runner crew, boat. A scanner
##     hears only the channels it's programmed for
##   - a transmission lasts: a brevity codeword is a ~1 s burst, a real call ~5 s.
##     DF bearings sharpen with the length of the transmission
##   - DF fixes by least squares over every bearing, with an error ellipse, and
##     police helicopters with DF gear add mobile bearings
##   - jamming: a transmission from inside a jammed zone never gets through

const DF_RANGE_M := 30000.0
const DF_SIGMA_DEG := 2.5
static var REALISM := true
const CHANNELS := ["police", "police_tac", "runner", "boat"]
const DF_MAST_M := 30.0


class RadioMsg:
	var t: float
	var channel: String  ## police | runner
	var sender: String
	var text: String
	var x = null
	var y = null
	var z = null  ## m MSL (REALISM); null = on the ground
	var dur := 3.0  ## s on the air (REALISM)
	var encrypted := false
	var jammed := false


class Bearing:
	var station: String
	var x: float
	var y: float
	var deg: float

	func _init(s: String, x_: float, y_: float, d: float) -> void:
		station = s
		x = x_
		y = y_
		deg = d


class DFResult:
	var bearings: Array
	var fix  ## [x, y] or null
	var ellipse = null  ## [semi-major m, semi-minor m, major-axis bearing deg] (REALISM)
	var t := 0.0

	func _init(b: Array, f) -> void:
		bearings = b
		fix = f


static func intersect(b1: Bearing, b2: Bearing):
	var d1 := [sin(Py.radians(b1.deg)), cos(Py.radians(b1.deg))]
	var d2 := [sin(Py.radians(b2.deg)), cos(Py.radians(b2.deg))]
	var det: float = d1[0] * -d2[1] - d1[1] * -d2[0]
	if absf(det) < 0.08:  # nearly parallel: useless fix
		return null
	var rx := b2.x - b1.x
	var ry := b2.y - b1.y
	var t1: float = (rx * -d2[1] - ry * -d2[0]) / det
	var t2: float = (d1[0] * ry - d1[1] * rx) / det
	if t1 < 0 or t2 < 0:
		return null
	return [b1.x + d1[0] * t1, b1.y + d1[1] * t1]


var rng: PyRandom
var encrypted := false
var log: Array = []
var df_stations: Array = []  ## [[code, x, y]]
var df_enabled := false
var world: World  ## REALISM: terrain for line of sight
var police_channel := "police"  ## where dispatch talks (switching to tactical dodges a basic scanner)
var jammed_zones: Array = []  ## [[x, y, radius(, until t)]]
var df_log: Array = []  ## recent DFResults for the controller's map


func _init(rng_: PyRandom = null) -> void:
	rng = rng_ if rng_ != null else PyRandom.new()


func transmit(t: float, channel: String, sender: String, text: String, pos = null, dur := -1.0) -> RadioMsg:
	var m := RadioMsg.new()
	m.t = t
	m.channel = channel
	m.sender = sender
	m.text = text
	if pos != null:
		m.x = pos[0]
		m.y = pos[1]
		if pos.size() > 2:
			m.z = pos[2]
	m.encrypted = encrypted and channel == "police"
	if REALISM:
		if channel == "police":
			m.channel = police_channel
		m.encrypted = encrypted and m.channel.begins_with("police")
		# a burst of words: about 2.5 words a second, a second or two of keying
		m.dur = dur if dur > 0 else clampf(1.0 + text.split(" ").size() / 2.5, 1.0, 8.0)
		if m.x != null:
			for z in jammed_zones:
				if PyMath.hypot(m.x - z[0], m.y - z[1]) < z[2] and (z.size() < 4 or t < z[3]):
					m.jammed = true
	log.append(m)
	Py.keep_last(log, 300)
	return m


## Can a receiver at rx [x, y, z MSL] hear a transmitter at tx? VHF is line of
## sight: the radio horizon of both antennas, and no hill in the way.
func can_hear(tx: Array, rx: Array) -> bool:
	var h1: float = maxf(2.0, tx[2] - world.ground(tx[0], tx[1])) if tx.size() > 2 and tx[2] != null else 2.0
	var h2: float = maxf(2.0, rx[2] - world.ground(rx[0], rx[1])) if rx.size() > 2 and rx[2] != null else 2.0
	var d := PyMath.hypot(tx[0] - rx[0], tx[1] - rx[1])
	if d > 4120.0 * (sqrt(h1) + sqrt(h2)):
		return false
	var z1: float = world.ground(tx[0], tx[1]) + h1
	var z2: float = world.ground(rx[0], rx[1]) + h2
	return world.line_of_sight([tx[0], tx[1], z1], [rx[0], rx[1], z2], 300.0)


func _pos(m: RadioMsg) -> Array:
	return [m.x, m.y, m.z]


## REALISM scanner: [[t, text]] for the programmed channels, only what the
## receiver at `rx` [x, y, z] can hear (jammed calls come through as a carrier).
func scanner_at(since: float, rx: Array, channels: Array) -> Array:
	var out := []
	for m in log:
		if m.t <= since or not (m.channel in channels):
			continue
		if m.x != null and not can_hear(_pos(m), rx):
			continue
		var tag := "" if m.channel == "police" else "[%s] " % m.channel.replace("police_", "")
		if m.jammed:
			out.append([m.t, tag + "[carrier - jammed]"])
		elif m.encrypted:
			out.append([m.t, tag + "[scrambled: encrypted traffic]"])
		else:
			out.append([m.t, tag + "%s: %s" % [m.sender, m.text]])
	return out


## What a runner scanner hears on the police channel: [[t, text]].
func scanner(since: float) -> Array:
	var out := []
	for m in log:
		if m.t <= since or m.channel != "police":
			continue
		out.append([m.t, "[scrambled: encrypted traffic]" if m.encrypted else "%s: %s" % [m.sender, m.text]])
	return out


func channel(name: String, since := -1.0) -> Array:
	var out := []
	for m in log:
		if m.channel == name and m.t > since:
			out.append(m)
	return out


func direction_find(msg: RadioMsg, mobile: Array = []) -> DFResult:
	if not df_enabled or msg.x == null:
		return DFResult.new([], null)
	if REALISM and world != null:
		return _df_real(msg, mobile)
	var bearings := []
	for st in df_stations:
		var d := PyMath.hypot(msg.x - st[1], msg.y - st[2])
		if d > DF_RANGE_M or d < 1:
			continue
		var true_deg := Py.degrees(atan2(msg.x - st[1], msg.y - st[2]))
		bearings.append(Bearing.new(st[0], st[1], st[2], Py.fmod(true_deg + rng.gauss(0, DF_SIGMA_DEG), 360)))
	var fix = null
	for i in bearings.size():
		for j in range(i + 1, bearings.size()):
			if fix == null:
				fix = intersect(bearings[i], bearings[j])
	return DFResult.new(bearings, fix)


## Least-squares DF: every station that hears the call gives a bearing whose
## error shrinks with the call's length; the fix minimises the squared
## perpendicular distances to all the bearing lines, and its covariance gives an
## error ellipse. `mobile`: [[code, x, y, z]] (police helicopters with DF gear).
func _df_real(msg: RadioMsg, mobile: Array) -> DFResult:
	var sigma := DF_SIGMA_DEG * clampf(3.0 / msg.dur, 0.5, 3.0)
	var bearings := []
	for st in df_stations + mobile:
		var sz: float = st[3] if st.size() > 3 else world.ground(st[1], st[2]) + DF_MAST_M
		var d := PyMath.hypot(msg.x - st[1], msg.y - st[2])
		if d > DF_RANGE_M or d < 1 or msg.jammed or not can_hear(_pos(msg), [st[1], st[2], sz]):
			continue
		var true_deg := rad_to_deg(atan2(msg.x - st[1], msg.y - st[2]))
		bearings.append(Bearing.new(st[0], st[1], st[2], fposmod(true_deg + rng.gauss(0, sigma), 360.0)))
	var res := DFResult.new(bearings, null)
	res.t = msg.t
	if bearings.size() >= 2:
		# normal equations: sum (I - d d^T) p = sum (I - d d^T) s
		var a11 := 0.0
		var a12 := 0.0
		var a22 := 0.0
		var b1 := 0.0
		var b2 := 0.0
		for b in bearings:
			var dx := sin(deg_to_rad(b.deg))
			var dy := cos(deg_to_rad(b.deg))
			var m11 := 1.0 - dx * dx
			var m12 := -dx * dy
			var m22 := 1.0 - dy * dy
			a11 += m11
			a12 += m12
			a22 += m22
			b1 += m11 * b.x + m12 * b.y
			b2 += m12 * b.x + m22 * b.y
		var det := a11 * a22 - a12 * a12
		if det > 0.02 * bearings.size():  # not all (nearly) parallel
			var px := (a22 * b1 - a12 * b2) / det
			var py := (a11 * b2 - a12 * b1) / det
			# covariance ~ (sigma * range)^2 * A^-1: eigen-decompose for the ellipse
			var rng_m := 0.0
			for b in bearings:
				rng_m += PyMath.hypot(px - b.x, py - b.y)
			rng_m /= bearings.size()
			var k := pow(deg_to_rad(sigma) * rng_m, 2) / det
			var c11 := a22 * k
			var c22 := a11 * k
			var c12 := -a12 * k
			var tr := c11 + c22
			var disc := sqrt(maxf(0.0, pow((c11 - c22) / 2.0, 2) + c12 * c12))
			var l1 := tr / 2.0 + disc
			var l2 := maxf(0.0, tr / 2.0 - disc)
			var ang := rad_to_deg(0.5 * atan2(2.0 * c12, c22 - c11))
			res.fix = [px, py]
			res.ellipse = [2.0 * sqrt(l1), 2.0 * sqrt(l2), fposmod(ang, 180.0)]  # 2-sigma
	df_log.append(res)
	Py.keep_last(df_log, 6)
	return res
