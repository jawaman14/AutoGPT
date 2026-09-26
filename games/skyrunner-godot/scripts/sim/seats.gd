class_name Seats
extends RefCounted
## Who sits in each role: the AI, a human (by name, with a reconnect token), a
## seat held for a human who dropped, or nobody (off).
##
## Every role runs on the AI until a human claims it; leaving hands it back.
## A dropped connection keeps the seat `reserved` for HOLD_S with the AI
## driving, and the same token takes it back. This is the single place seats
## change hands: HostServer calls claim/release, the Session's seat_driver
## flips each system between its AI and the human (the copilot aboard, the
## desk's controller, the HQ planners, the police pilot's unit, the cutter's
## captain, the ground war's commanders).

const HOLD_S := 30.0

var sess  ## Session
var seats := {}  ## role -> {who: "ai" | "human" | "reserved" | "off", name, token, until}
var rev := 0  ## bumped on every change (the server broadcasts the roster)


func _init(sess_, local := {}) -> void:
	sess = sess_
	for role in Roles.ALL:
		var who := "ai"
		if role == Roles.PILOT and not sess.runner_active():
			who = "off"
		seats[role] = {"who": who, "name": "", "token": "", "until": 0.0}
	for role in local:
		if seats.has(role):
			seats[role].who = "human"
			seats[role].name = str(local[role])


func who(role: String) -> String:
	return seats[role].who if seats.has(role) else "off"


func human(role: String) -> bool:
	return who(role) == "human"


## Roles a newcomer may take: anything the AI holds (or a reserved seat,
## with its token).
func open(token := "") -> Array:
	return Roles.ALL.filter(func(r): return who(r) == "ai" or (who(r) == "reserved" and token != "" and seats[r].token == token))


## A human takes `role`. Returns "" or why not.
func claim(role: String, name: String, token: String) -> String:
	if not seats.has(role):
		return "No such role."
	var s: Dictionary = seats[role]
	match s.who:
		"off":
			return "There's no %s in this game." % role
		"human":
			return "%s is taken by %s." % [role, s.name]
		"reserved":
			if token == "" or token != s.token:
				return "%s is held for %s for a few seconds." % [role, s.name]
	s.who = "human"
	s.name = name
	s.token = token
	s.until = 0.0
	rev += 1
	sess.humans[role] = name
	sess.seat_driver(role, true)
	return ""


## The human leaves `role`. hold: they dropped - keep it for them for HOLD_S.
func release(role: String, hold := false) -> void:
	if not seats.has(role) or seats[role].who != "human":
		return
	var s: Dictionary = seats[role]
	s.who = "reserved" if hold else "ai"
	s.until = sess.time + HOLD_S if hold else 0.0
	if not hold:
		s.name = ""
		s.token = ""
	rev += 1
	sess.humans.erase(role)
	sess.seat_driver(role, false)


## The role a returning token was holding (reserved), or "".
func held_for(token: String) -> String:
	if token == "":
		return ""
	for r in seats:
		if seats[r].who == "reserved" and seats[r].token == token:
			return r
	return ""


## Expire held seats: the AI keeps them.
func tick(now: float) -> void:
	for r in seats:
		var s: Dictionary = seats[r]
		if s.who == "reserved" and now >= s.until:
			s.who = "ai"
			s.name = ""
			s.token = ""
			rev += 1


func roster() -> Array:
	return Roles.ALL.map(func(r): return {"role": r, "side": Roles.side(r), "who": seats[r].who, "name": seats[r].name})
