class_name NetClient
extends Node
## Client for station UIs, remote seats and bots (port of net/client.py).
## Add it to the tree (it polls in _process), then `open(host, port, name, role)`.
## `snapshot()` is the latest role-filtered snapshot or null; `acks[seq]` =
## [ok, msg] once the host has answered a command.

var peer := StreamPeerTCP.new()
var host := ""
var port := 0
var name_ := "player"
var role := ""
var latest = null
var welcome = null
var error = null
var acks := {}
var token := ""  ## the host's reconnect token (from the welcome); send it again to take back a held seat
var seats: Array = []  ## the live roster: [{role, side, who, name}]
var players: Array = []  ## [{name, role}]
var chat_log: Array = []  ## [{from, role, side, text, to}]
var claim_error = null
signal role_changed(role: String)
var _buf := PackedByteArray()
var _seq := 0
var _hello_sent := false
var _closed := false


func open(host_: String, port_: int, player_name: String, role_: String) -> NetClient:
	host = host_
	port = port_
	name_ = player_name
	role = role_
	var err := peer.connect_to_host(host, port)
	if err != OK:
		error = "Can't connect to %s:%d (%s)" % [host, port, error_string(err)]
		_closed = true
	return self


func _process(_dt: float) -> void:
	poll()


func poll() -> void:
	if _closed:
		return
	peer.poll()
	var st := peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		if error == null:
			error = "Host closed the connection." if _hello_sent else "Can't connect to %s:%d" % [host, port]
		_closed = true
		return
	if not _hello_sent:
		var hello := {"t": "hello", "v": Snapshot.PROTOCOL_VERSION, "name": name_, "role": role}
		if token != "":
			hello["token"] = token
		peer.put_data(HostServer.line(hello))
		_hello_sent = true
	for l in HostServer.read_lines(peer, _buf):
		var msg = JSON.parse_string(l)
		if not (msg is Dictionary):
			continue
		match msg.get("t"):
			"welcome":
				welcome = msg
				token = str(msg.get("token", token))
				if str(msg.get("role", "")) != role:
					role = str(msg.get("role", ""))
					role_changed.emit(role)
			"seats":
				seats = msg.get("seats", [])
				players = msg.get("players", [])
			"claimed":
				claim_error = null
				role = str(msg.get("role", ""))
				latest = null
				role_changed.emit(role)
			"claim_failed":
				claim_error = str(msg.get("msg", ""))
			"chat":
				chat_log.append(msg)
				Py.keep_last(chat_log, 50)
			"error":
				error = str(msg.get("msg", "error"))
				close()
			"snap":
				latest = msg
			"ack":
				acks[int(msg.get("seq", 0))] = [bool(msg.get("ok")), str(msg.get("msg", ""))]


## Take a seat (the AI hands it over), or leave it (back to the AI).
func claim(role_: String) -> void:
	_put({"t": "claim", "role": role_})


func release() -> void:
	_put({"t": "release"})


## Table talk: to everyone, or to your side only.
func say(text: String, to := "all") -> void:
	_put({"t": "say", "text": text, "to": to})


## Reconnect with the same token (a dropped seat is held for Seats.HOLD_S).
func reconnect() -> void:
	peer = StreamPeerTCP.new()
	_buf = PackedByteArray()
	_hello_sent = false
	_closed = false
	error = null
	role = ""
	var err := peer.connect_to_host(host, port)
	if err != OK:
		error = "Can't connect to %s:%d (%s)" % [host, port, error_string(err)]
		_closed = true


func _put(msg: Dictionary) -> void:
	if not _closed and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(HostServer.line(msg))


func send_command(cmd: String, args := {}) -> int:
	_seq += 1
	if not _closed and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(HostServer.line({"t": "cmd", "seq": _seq, "name": cmd, "args": args}))
	return _seq


## Police pilot stick: fire-and-forget, the latest one wins.
func send_input(roll: float, pitch: float, throttle: float) -> void:
	if not _closed and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data(HostServer.line({"t": "input", "roll": snappedf(roll, 0.001), "pitch": snappedf(pitch, 0.001),
			"throttle": snappedf(throttle, 0.001)}))


func snapshot():
	return latest


func tick(_dt: float) -> void:
	pass  # remote sessions tick on the host


func alive() -> bool:
	return not _closed


func close() -> void:
	_closed = true
	peer.disconnect_from_host()
