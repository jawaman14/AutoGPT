class_name LocalLink
extends RefCounted
## Same interface as NetClient, backed by an in-process Session: the station
## UI runs the police-vs-AI desk, or a hot-seat HQ, with no networking.

var sess: Session
var role: String
var error = null
var last_result := [true, ""]
var acks := {}
var _seq := 0


func _init(s: Session, role_: String) -> void:
	sess = s
	role = role_


func send_command(cmd: String, args := {}) -> int:
	last_result = sess.command(role, cmd, args)
	_seq += 1
	acks[_seq] = last_result
	return _seq


func snapshot():
	_seq += 1
	return Snapshot.build(sess, role, _seq)


func send_input(roll: float, pitch: float, throttle: float) -> void:
	sess.set_pilot_input(role, roll, pitch, throttle)


func tick(dt: float) -> void:
	sess.update(dt)


func alive() -> bool:
	return true


func close() -> void:
	pass
