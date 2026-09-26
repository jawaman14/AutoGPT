class_name EventBus
extends RefCounted
## Tiny synchronous event bus.
##
## Game systems emit facts ("bale_delivered", "busted", ...). The campaign,
## scoring, network layer and HUD subscribe. Events carry the side(s) allowed
## to hear about them, so the network layer can keep fog of war.


class Event:
	var kind: String
	var t: float
	var data: Dictionary
	var audience: Array  ## sides that may see it
	var text: String

	func _init(kind_: String, t_: float, data_: Dictionary, audience_: Array, text_: String) -> void:
		kind = kind_
		t = t_
		data = data_
		audience = audience_
		text = text_


var _subs := {}
var log: Array = []


## kind "*" receives everything.
func subscribe(kind: String, fn: Callable) -> void:
	if not _subs.has(kind):
		_subs[kind] = []
	_subs[kind].append(fn)


func emit(kind: String, t: float, text := "", audience := ["runner", "law"], data := {}) -> Event:
	var ev := Event.new(kind, t, data, audience, text)
	log.append(ev)
	Py.keep_last(log, 400)
	var fns: Array = _subs.get(kind, []).duplicate() + _subs.get("*", []).duplicate()
	for fn in fns:
		fn.call(ev)
	return ev


func since(t: float, side = null) -> Array:
	var out := []
	for e in log:
		if e.t > t and (side == null or e.audience.has(side)):
			out.append(e)
	return out
