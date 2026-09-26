class_name HostServer
extends Node
## Listen server: the host runs the only simulation; remote seats send commands
## and receive role-filtered snapshots (port of net/server.py).
##
## Transport: TCP, one JSON object per line (protocol v3; v2 clients that name
## their role in the hello still join straight into it).
##   client -> server  {"t":"hello","v":3,"name":"Rosa","role":"copilot"?,"token":"..."?}
##                     {"t":"claim","role":"lieutenant"}  {"t":"release"}
##                     {"t":"say","text":"...","to":"all"|"side"}
##                     {"t":"cmd","seq":7,"name":"kick","args":{"count":2}}
##                     {"t":"input","roll":0.2,"pitch":-0.1,"throttle":0.8}  (police pilot)
##   server -> client  {"t":"welcome","role":"","mode":"coop","seed":7,"token":"..."}
##                     {"t":"seats","seats":[{role,side,who,name}],"players":[{name,role}],"you":"..."}
##                     {"t":"claimed","role":"..."}  {"t":"claim_failed","msg":"..."}
##                     {"t":"chat","from":"Rosa","role":"copilot","side":"runner","text":"...","to":"all"}
##                     {"t":"error","msg":"..."}  {"t":"ack","seq":7,"ok":true,"msg":"ok"}
##                     {"t":"snap",...}  (Snapshot.build; only to players in a seat)
## Every role is the AI's until someone claims it (Session.seats). Joining
## without a role puts you in the lobby with the live seat list; a dropped
## player's seat is held for Seats.HOLD_S and the welcome's token takes it back.
## Sockets are polled from _process; commands reach the Session in pump(),
## which the game loop calls around its update.

const DEFAULT_PORT := 47800
const MAX_LINE := 1 << 20
const SNAPSHOT_HZ := 20.0
const HELLO_TIMEOUT_MS := 10000


class Conn:
	var peer: StreamPeerTCP
	var buf := PackedByteArray()
	var role := ""
	var name := ""
	var token := ""
	var v := 3
	var joined := false
	var t0 := 0


var tcp := TCPServer.new()
var port := DEFAULT_PORT
var mode := Roles.COOP
var world_seed := 7
var conns: Array = []
var clients := {}  ## role -> Conn
var inbox: Array = []  ## [role, seq, name, args]
var sticks := {}  ## role -> [roll, pitch, throttle]
var sess = null  ## the Session the seats belong to (set by attach or the first pump)
var chat_log: Array = []  ## [from, role, side, text, to]
var _seats_rev := -1
var _seats_t := 0.0
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


func attach(sess_) -> void:
	sess = sess_


func _hello(c: Conn, hello: Dictionary) -> void:
	var role := str(hello.get("role", ""))
	var name := str(hello.get("name", "player")).substr(0, 32)
	var v := int(hello.get("v", -1))
	var err := ""
	if hello.get("t") != "hello" or not (v in [2, Snapshot.PROTOCOL_VERSION]):
		err = "Protocol mismatch (server v%d)." % Snapshot.PROTOCOL_VERSION
	elif sess == null:
		err = "The host isn't ready yet."
	elif role != "" and not Roles.valid(role):
		err = "No such role %s." % role
	elif v == 2 and role == "":
		err = "Protocol v2 needs a role."
	if err != "":
		c.peer.put_data(line({"t": "error", "msg": err}))
		_drop(c)
		return
	c.name = name
	c.v = v
	c.token = str(hello.get("token", "")).substr(0, 64)
	if c.token == "":
		c.token = "%08x%08x" % [randi(), randi()]
	# a returning player takes back the seat held for them
	var held: String = sess.seats.held_for(c.token)
	if held != "" and role == "":
		role = held
	if role != "":
		var why: String = sess.seats.claim(role, name, c.token)
		if why != "":
			c.peer.put_data(line({"t": "error", "msg": why}))
			_drop(c)
			return
		c.role = role
		clients[role] = c
	c.joined = true
	c.peer.put_data(line({"t": "welcome", "role": c.role, "mode": mode, "seed": world_seed, "token": c.token, "v": Snapshot.PROTOCOL_VERSION}))
	_seats_rev = -1  # everyone gets the new roster


func _message(c: Conn, msg: Dictionary) -> void:
	match msg.get("t"):
		"claim":
			var role := str(msg.get("role", ""))
			if c.role != "":
				sess.seats.release(c.role)
				clients.erase(c.role)
				c.role = ""
			var why: String = sess.seats.claim(role, c.name, c.token)
			if why != "":
				c.peer.put_data(line({"t": "claim_failed", "msg": why}))
			else:
				c.role = role
				clients[role] = c
				c.peer.put_data(line({"t": "claimed", "role": role}))
			_seats_rev = -1
			return
		"release":
			if c.role != "":
				sess.seats.release(c.role)
				clients.erase(c.role)
				sticks.erase(c.role)
				c.role = ""
				c.peer.put_data(line({"t": "claimed", "role": ""}))
				_seats_rev = -1
			return
		"say":
			var text := str(msg.get("text", "")).strip_edges().substr(0, 200)
			if text != "":
				chat(c.name, c.role, text, "side" if msg.get("to") == "side" else "all")
			return
	if c.role == "":
		if msg.get("t") == "cmd":
			c.peer.put_data(line({"t": "ack", "seq": int(msg.get("seq", 0)), "ok": false, "msg": "Claim a seat first."}))
		return
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
	if c.joined and c.role != "" and clients.get(c.role) == c:
		clients.erase(c.role)
		sticks.erase(c.role)
		if sess != null:
			sess.seats.release(c.role, true)  # held for them: the token takes it back
		_seats_rev = -1
	c.peer.disconnect_from_host()


## A chat line: to everyone, or to one side's players (and the host, who sees
## both sides' as a spectator of the table's talk only when it's to all).
func chat(from: String, role: String, text: String, to := "all") -> void:
	var side := Roles.side(role) if role != "" else ""
	var msg := {"t": "chat", "from": from, "role": role, "side": side, "text": text, "to": to}
	chat_log.append([from, role, side, text, to])
	Py.keep_last(chat_log, 50)
	for c in conns:
		if c.joined and (to == "all" or (c.role != "" and Roles.side(c.role) == side)):
			c.peer.put_data(line(msg))
	if sess != null:
		var t := "[%s%s] %s: %s" % ["team " if to == "side" else "", role if role != "" else "lobby", from, text]
		if to == "all" or side == "runner":
			sess.say(t)
		if to == "all" or side == "law":
			sess.law_say(t)


func _broadcast_seats() -> void:
	var roster: Array = sess.seats.roster()
	var players := conns.filter(func(c): return c.joined).map(func(c): return {"name": c.name, "role": c.role})
	for c in conns:
		if c.joined:
			c.peer.put_data(line({"t": "seats", "seats": roster, "players": players, "you": c.role}))


func _send(role: String, msg: Dictionary) -> void:
	var c: Conn = clients.get(role)
	if c != null and c.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		c.peer.put_data(line(msg))


# ------------------------------------------------------------ game side
## Apply joins/leaves and queued commands. Call from the game loop.
func pump(sess_: Session) -> void:
	sess = sess_
	sess.seats.tick(sess.time)
	var now := Time.get_ticks_msec() / 1000.0
	if sess.seats.rev != _seats_rev or now - _seats_t > 1.0:
		_seats_rev = sess.seats.rev
		_seats_t = now
		_broadcast_seats()
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
