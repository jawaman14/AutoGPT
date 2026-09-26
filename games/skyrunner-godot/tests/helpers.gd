class_name T
extends RefCounted
## Shared test helpers (the pytest conftest/fixtures of the Python suite).

const FLAT := 0.0


static func inp(held: Array = [], pressed: Array = []) -> ControlMapper.InputFrame:
	var f := ControlMapper.InputFrame.new()
	for h in held:
		f.held[h] = true
	for p in pressed:
		f.pressed[p] = true
	return f


## idle(sess, secs, held): run the session at 60 Hz
static func idle(sess: Session, secs: float, held: Array = []) -> void:
	for i in int(secs * 60):
		sess.update(1.0 / 60, inp(held))


static func sess(seed := 3, opts := {}) -> Session:
	var o := {"seed": seed}
	o.merge(opts, true)
	return Session.new(o)


static func masses(key: String) -> MassData:
	return MassData.read(Aircraft.spec(key).jsbsim_model)


static func flat(x: float, y: float) -> float:
	return 0.0


static func first(items: Array, pred: Callable):
	return Py.first(items, pred)
