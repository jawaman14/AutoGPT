class_name HostServer
extends Node
## Listen server: the host runs the only simulation; remote seats send commands
## and receive role-filtered snapshots (port of net/server.py).
##
## Transport: TCP, one JSON object per line - the same wire protocol as the
## Python game, so Python station clients can join a Godot host and vice versa.
##   client -> server  {"t":"hello","v":2,"name":"Rosa","role":"copilot"}
##                     {"t":"cmd","seq":7,"name":"kick","args":{"count":2}}
##                     {"t":"input","roll":0.2,"pitch":-0.1,"throttle":0.8}  (police pilot)
##   server -> client  {"t":"welcome","role":"copilot","mode":"coop","seed":7}
##                     {"t":"error","msg":"..."}
##                     {"t":"ack","seq":7,"ok":true,"msg":"ok"}
##                     {"t":"snap",...}  (Snapshot.build)
## Sockets are polled from _process; the Session is only touched in pump() and
## publish(), which the game loop calls around its update.

const DEFAULT_PORT := 47800
const MAX_LINE := 1 << 20
const SNAPSHOT_HZ := 20.0
const HELLO_TIMEOUT_MS := 10000


class Conn:
	var peer: StreamPeerTCP
	var buf := PackedByteArray()
	var role := ""
	var name := ""
	var joined := false
	var t0 := 0


var tcp := TCPServer.new()
var port := DEFAULT_PORT
var mode := Roles.COOP
var world_seed := 7
var conns: Array = []
var clients := {}  ## role -> Conn
var inbox: Array = []  ## [role, seq, name, args]
var joins: Array = []  ## ["join"|"leave", role, name]
var sticks := {}  ## role -> [roll, pitch, throttle]
var _seq := 0
var _last_pub := -1e9


## Returns an error string, or null. Port 0 picks a free port (see `port`).
func start(port_ := DEFAULT_PORT, mode_ := Roles.COOP, bind := "*", seed := 7):
	mode = mode_
	world_seed = seed
	if port_ == 0:
		for p in range(47900, 48900):
			if tcp.listen(p, bind) == OK:
				port = p
				return null
		return "No free port."
	var err := tcp.listen(port_, bind)
	if err != OK:
		return "Can't listen on port %d (%s)." % [port_, error_string(err)]
	port = port_
	return null


func stop() -> void:
	for c in conns:
		c.peer.disconnect_from_host()
	conns.clear()
	clients.clear()
	tcp.stop()


func _exit_tree() -> void:
	stop()


static func line(msg: Dictionary) -> PackedByteArray:
	return (JSON.stringify(msg) + "\n").to_utf8_buffer()


## Pull complete lines out of a connection's buffer.
static func read_lines(peer: StreamPeerTCP, buf: PackedByteArray) -> Array:
	var n := peer.get_available_bytes()
	if n > 0:
		var r := peer.get_partial_data(n)
		if r[0] == OK:
			buf.append_array(r[1])
	var out := []
	while true:
		var i := buf.find(10)
		if i < 0:
			break
		out.append(buf.slice(0, i).get_string_from_utf8())
		var rest := buf.slice(i + 1)
		buf.clear()
		buf.append_array(rest)
	return out


func _process(_dt: float) -> void:
	while tcp.is_listening() and tcp.is_connection_available():
		var c := Conn.new()
		c.peer = tcp.take_connection()
		c.peer.set_no_delay(true)
		c.t0 = Time.get_ticks_msec()
		conns.append(c)
	for c in conns.duplicate():
		c.peer.poll()
		var st: int = c.peer.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			_drop(c)
			continue
		var lines := read_lines(c.peer, c.buf)
		if c.buf.size() > MAX_LINE:
			_drop(c)
			continue
		for l in lines:
			var msg = JSON.parse_string(l)
			if not (msg is Dictionary):
				continue
			if not c.joined:
				_hello(c, msg)
				if not c.joined:
					break
			else:
				_message(c, msg)
		if not c.joined and Time.get_ticks_msec() - c.t0 > HELLO_TIMEOUT_MS and conns.has(c):
			_drop(c)


func _hello(c: Conn, hello: Dictionary) -> void:
	var role := str(hello.get("role", ""))
	var name := str(hello.get("name", "player")).substr(0, 32)
	var err := ""
	if hello.get("t") != "hello" or int(hello.get("v", -1)) != Snapshot.PROTOCOL_VERSION:
		err = "Protocol mismatch (server v%d)." % Snapshot.PROTOCOL_VERSION
	elif not Roles.valid(role) or role == Roles.PILOT or not (role in Roles.MODE_ROLES.get(mode, [])):
		err = "Role %s isn't open in %s mode." % [role, mode]
	elif clients.has(role):
		err = "%s is already taken." % role
	if err != "":
		c.peer.put_data(line({"t": "error", "msg": err}))
		_drop(c)
		return
	c.role = role
	c.name = name
	c.joined = true
	clients[role] = c
	c.peer.put_data(line({"t": "welcome", "role": role, "mode": mode, "seed": world_seed}))
	joins.append(["join", role, name])


func _message(c: Conn, msg: Dictionary) -> void:
	if msg.get("t") == "cmd" and msg.get("args", {}) is Dictionary:
		var args := {}
		var raw: Dictionary = msg.get("args", {})
		for k in raw.keys().slice(0, 8):
			args[str(k).substr(0, 32)] = raw[k]
		inbox.append([c.role, int(msg.get("seq", 0)), str(msg.get("name", "")).substr(0, 32), args])
	elif msg.get("t") == "input" and c.role == Roles.INTERCEPTOR:
		var v := []
		for k in ["roll", "pitch", "throttle"]:  # latest stick position wins; no queueing, no acks
			var x = msg.get(k, 0.0)
			v.append(clampf(float(x), -1.0, 1.0) if (x is float or x is int) else 0.0)
		sticks[c.role] = v


func _drop(c: Conn) -> void:
	conns.erase(c)
	if c.joined and clients.get(c.role) == c:
		clients.erase(c.role)
		sticks.erase(c.role)
		joins.append(["leave", c.role, c.name])
	c.peer.disconnect_from_host()


func _send(role: String, msg: Dictionary) -> void:
	var c: Conn = clients.get(role)
	if c != null and c.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		c.peer.put_data(line(msg))


# ------------------------------------------------------------ game side
## Apply joins/leaves and queued commands. Call from the game loop.
func pump(sess: Session) -> void:
	for j in joins:
		var role: String = j[1]
		var name: String = j[2]
		if j[0] == "join":
			sess.humans[role] = name
			if role == Roles.COPILOT:
				sess.set_copilot("human")
			elif role == Roles.CONTROLLER:
				sess.police.controller = "human"
			elif role == Roles.BOSS and sess.nights != null:
				sess.nights.runner_ai = null
			elif role == Roles.CHIEF and sess.nights != null:
				sess.nights.law_ai = null
			sess.say("%s joined as %s." % [name, role])
			sess.law_say("%s joined as %s." % [name, role])
		else:
			sess.humans.erase(role)
			if role == Roles.COPILOT:
				sess.set_copilot(null)
			elif role == Roles.CONTROLLER:
				sess.police.controller = "ai"
			elif role == Roles.INTERCEPTOR:
				sess.command(role, "release_unit", {})
			elif role == Roles.CHIEF and sess.nights != null and not sess.humans.has(Roles.CONTROLLER):
				sess.nights.law_ai = "adaptive"
			sess.say("%s (%s) left." % [name, role])
	joins.clear()
	for role in sticks:
		sess.set_pilot_input(role, sticks[role][0], sticks[role][1], sticks[role][2])
	for m in inbox:
		var r: Array = sess.command(m[0], m[2], m[3])
		_send(m[0], {"t": "ack", "seq": m[1], "ok": r[0], "msg": r[1]})
	inbox.clear()


func publish(sess: Session, force := false) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not force and now - _last_pub < 1.0 / SNAPSHOT_HZ:
		return
	_last_pub = now
	_seq += 1
	for role in clients.keys():
		_send(role, Snapshot.build(sess, role, _seq))
