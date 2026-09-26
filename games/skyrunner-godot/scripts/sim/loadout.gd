class_name Loadout
extends RefCounted
## Weight & balance.
##
## The numbers computed here are a *prediction* shown in the load planner. What
## the aircraft actually does is decided by JSBSim, which receives the same
## masses as point masses at the same arms, so a bad load really flies badly.

const PILOT_LB := 180.0
const FERRY_TANK_EMPTY_LB := 25.0


class Item:
	var id: int
	var label: String
	var kind: String  ## passenger | cargo | tank
	var weight_lb: float
	var job_id: int  ## 0 = the aircraft's own equipment
	var hot := false  ## contraband / fugitive -> police interest
	var fragile := false
	var droppable := false  ## can be kicked out of the door in flight
	var fuel_lb := 0.0  ## ferry tanks only
	var fuel_cap_lb := 0.0

	func _init(id_: int, label_: String, kind_: String, weight_lb_: float, job_id_: int, opts := {}) -> void:
		id = id_
		label = label_
		kind = kind_
		weight_lb = weight_lb_
		job_id = job_id_
		for k in opts:
			set(k, opts[k])

	func set_fuel(lb: float) -> void:
		fuel_lb = maxf(0.0, minf(fuel_cap_lb, lb))
		weight_lb = FERRY_TANK_EMPTY_LB + fuel_lb


class WBResult:
	var weight_lb: float
	var cg_in: float
	var in_envelope: bool
	var overweight_lb: float
	var station_overloads: Array
	var fwd_limit_in: float
	var aft_limit_in: float

	func ok() -> bool:
		return in_envelope and overweight_lb <= 0 and station_overloads.is_empty()


static func ferry_tank(item_id: int, capacity_lb: float) -> Item:
	return Item.new(item_id, "Ferry tank", "tank", FERRY_TANK_EMPTY_LB, 0, {"fuel_cap_lb": capacity_lb})


## Crew-seconds to move one item (walking a bladder tank in is slow too).
static func load_time_s(item: Item) -> float:
	return 4.0 + 0.02 * item.weight_lb


static func point_in_polygon(x: float, y: float, poly: Array) -> bool:
	var inside := false
	var n := poly.size()
	for i in n:
		var x1: float = poly[i][0]
		var y1: float = poly[i][1]
		var x2: float = poly[(i + 1) % n][0]
		var y2: float = poly[(i + 1) % n][1]
		if (y1 > y) != (y2 > y):
			var xin := x1 + (y - y1) * (x2 - x1) / (y2 - y1)
			if x < xin:
				inside = not inside
	return inside


## Forward/aft CG limit at a weight: intersect the envelope with a horizontal line.
static func cg_limits_at(weight: float, poly: Array) -> Array:
	var xs := []
	var n := poly.size()
	for i in n:
		var x1: float = poly[i][0]
		var y1: float = poly[i][1]
		var x2: float = poly[(i + 1) % n][0]
		var y2: float = poly[(i + 1) % n][1]
		if minf(y1, y2) <= weight and weight <= maxf(y1, y2) and y1 != y2:
			xs.append(x1 + (weight - y1) * (x2 - x1) / (y2 - y1))
	if xs.is_empty():
		return [NAN, NAN]
	return [xs.min(), xs.max()]


var spec: Aircraft.Spec
var mass: MassData
var fuel_lb: float
var assignment := {}  ## item id -> station idx
var items := {}  ## item id -> Item
var pending := {}  ## item id -> crew-seconds still needed before it's actually in its station
var copilot_aboard := false


func _init(spec_: Aircraft.Spec, mass_: MassData, fuel_lb_: float, copilot_aboard_ := false) -> void:
	spec = spec_
	mass = mass_
	fuel_lb = fuel_lb_
	copilot_aboard = copilot_aboard_


## Weights actually in the aircraft (planned=true: as if loading were done).
func station_weights(planned := false) -> Array:
	var w := []
	w.resize(spec.stations.size())
	w.fill(0.0)
	w[spec.pilot_station()] = PILOT_LB
	if copilot_aboard:
		var cp := copilot_station()
		if cp >= 0:
			w[cp] += PILOT_LB
	for iid in assignment:
		if planned or not pending.has(iid):
			w[assignment[iid]] += items[iid].weight_lb
	return w


func copilot_station() -> int:
	for i in spec.stations.size():
		if spec.stations[i].name == "Co-pilot":
			return i
	return -1


## Bladder size: 80% of the wing tanks, but it has to fit on one cabin station.
func ferry_capacity() -> float:
	var biggest := 0.0
	for s in spec.stations:
		if s.kind != "pilot":
			biggest = maxf(biggest, s.max_lb)
	return Py.round_int(minf(mass.fuel_capacity_lb() * 0.8, biggest - FERRY_TANK_EMPTY_LB))


func ferry_tanks() -> Array:
	var out := []
	for i in items.values():
		if i.kind == "tank" and assignment.has(i.id) and not pending.has(i.id):
			out.append(i)
	return out


func ferry_fuel_lb() -> float:
	var s := 0.0
	for t in ferry_tanks():
		s += t.fuel_lb
	return s


func queue_move(item: Item) -> void:
	pending[item.id] = load_time_s(item)


## Crew members each work one pending item. Returns ids that finished.
func work(dt: float, crew: int) -> Array:
	var done := []
	var ids := pending.keys().slice(0, maxi(0, crew))
	for iid in ids:
		pending[iid] -= dt
		if pending[iid] <= 0:
			pending.erase(iid)
			done.append(iid)
	return done


func tank_fuel() -> Array:
	var cap := mass.fuel_capacity_lb()
	var out := []
	for t in mass.tanks:
		out.append(fuel_lb * t[1] / cap)
	return out


## W&B of the plan (default) or of what is physically aboard (planned=false).
func compute(fuel_override = null, planned := true) -> WBResult:
	var fuel: float = fuel_lb if fuel_override == null else fuel_override
	var w := mass.empty_lb
	var m := w * mass.empty_cg_x_in
	var sw := station_weights(planned)
	for i in spec.stations.size():
		w += sw[i]
		m += sw[i] * spec.stations[i].x_in
	var cap := mass.fuel_capacity_lb()
	for t in mass.tanks:
		var f: float = fuel * t[1] / cap
		w += f
		m += f * t[0]
	var r := WBResult.new()
	r.weight_lb = w
	r.cg_in = m / w
	r.station_overloads = []
	for i in spec.stations.size():
		if sw[i] > spec.stations[i].max_lb:
			r.station_overloads.append(spec.stations[i].name)
	var env: Array = spec.envelope
	var lim := cg_limits_at(minf(maxf(w, env[0][1]), spec.mtow_lb), env)
	r.fwd_limit_in = lim[0]
	r.aft_limit_in = lim[1]
	r.in_envelope = point_in_polygon(r.cg_in, minf(w, spec.mtow_lb - 1e-6), env) and w >= env[0][1]
	r.overweight_lb = maxf(0.0, w - spec.mtow_lb)
	return r


# -- editing ---------------------------------------------------------
func add(item: Item) -> void:
	items[item.id] = item


func remove_job(job_id: int) -> Array:
	var gone := []
	for i in items.values():
		if i.job_id == job_id:
			gone.append(i)
	for i in gone:
		remove_item(i.id)
	return gone


func remove_item(item_id: int) -> Item:
	assignment.erase(item_id)
	pending.erase(item_id)
	var it: Item = items.get(item_id)
	items.erase(item_id)
	return it


func unassigned() -> Array:
	var out := []
	for i in items.values():
		if not assignment.has(i.id):
			out.append(i)
	return out


func valid_stations(item: Item) -> Array:
	var out := []
	for i in spec.stations.size():
		if spec.stations[i].accepts(item.kind):
			out.append(i)
	return out


func seat_taken(st_idx: int, except_item := -1) -> bool:
	if copilot_aboard and st_idx == copilot_station():
		return true
	for i in assignment:
		if assignment[i] == st_idx and items[i].kind == "passenger" and i != except_item:
			return true
	return false


func can_place(item: Item, st_idx: int) -> bool:
	var st = spec.stations[st_idx]
	if not st.accepts(item.kind):
		return false
	if seat_taken(st_idx, item.id):
		return false  # one passenger per seat, nothing on top of them
	if item.kind == "passenger":
		for i in assignment:
			if assignment[i] == st_idx and i != item.id:
				return false
	return true


## Move an item to the next station that will take it (or unload it).
func cycle(item: Item, direction := 1) -> void:
	var options: Array = [null]
	for s in valid_stations(item):
		if can_place(item, s):
			options.append(s)
	var cur = assignment.get(item.id)
	var idx := options.find(cur) if options.has(cur) else 0
	var nxt = options[posmod(idx + direction, options.size())]
	if nxt == null:
		assignment.erase(item.id)
		pending.erase(item.id)
	else:
		assignment[item.id] = nxt
		queue_move(item)


func all_loaded() -> bool:
	return unassigned().is_empty()


## Loading still in progress or items left on the ramp.
func busy() -> bool:
	return not pending.is_empty() or not unassigned().is_empty()


## Greedy loader: heaviest item first, pick the station that keeps the CG
## closest to the middle of the envelope without overloading a station.
## Returns true if everything found a place.
func auto_balance() -> bool:
	assignment.clear()
	var total := 0.0
	for i in items.values():
		total += i.weight_lb
	var target_w := minf(compute().weight_lb + total, spec.mtow_lb)
	var lim := cg_limits_at(target_w, spec.envelope)
	var mid: float = (lim[0] + lim[1]) / 2
	var weights := station_weights(true)
	for item in Py.sorted_by(items.values(), func(i): return -i.weight_lb):
		var best = null
		var best_err = null
		for s in valid_stations(item):
			if not can_place(item, s):
				continue
			if weights[s] + item.weight_lb > spec.stations[s].max_lb:
				continue
			assignment[item.id] = s
			var err := absf(compute().cg_in - mid)
			assignment.erase(item.id)
			if best_err == null or err < best_err:
				best = s
				best_err = err
		if best != null:
			assignment[item.id] = best
			weights[best] += item.weight_lb
	return all_loaded()


## After an automatic re-plan, queue crew work for every item that moved.
func requeue_changed(before: Dictionary) -> void:
	for iid in pending.keys():
		if not assignment.has(iid):
			pending.erase(iid)
	for iid in assignment:
		if before.get(iid) != assignment[iid]:
			queue_move(items[iid])
