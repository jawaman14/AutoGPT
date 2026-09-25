class_name RadioNet
extends RefCounted
## Radio: police dispatch, runner calls, scanners and direction finding.
##
## - Police traffic is plain voice unless the task force pays for encryption.
##   A runner scanner hears plain traffic verbatim, static when encrypted.
## - Every runner transmission (calling the boat) can be heard by DF stations.
##   One bearing gives a line, two give a fix with a few hundred metres of error.

const DF_RANGE_M := 30000.0
const DF_SIGMA_DEG := 2.5


class RadioMsg:
	var t: float
	var channel: String  ## police | runner
	var sender: String
	var text: String
	var x = null
	var y = null
	var encrypted := false


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


func _init(rng_: PyRandom = null) -> void:
	rng = rng_ if rng_ != null else PyRandom.new()


func transmit(t: float, channel: String, sender: String, text: String, pos = null) -> RadioMsg:
	var m := RadioMsg.new()
	m.t = t
	m.channel = channel
	m.sender = sender
	m.text = text
	if pos != null:
		m.x = pos[0]
		m.y = pos[1]
	m.encrypted = encrypted and channel == "police"
	log.append(m)
	Py.keep_last(log, 300)
	return m


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


func direction_find(msg: RadioMsg) -> DFResult:
	if not df_enabled or msg.x == null:
		return DFResult.new([], null)
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
