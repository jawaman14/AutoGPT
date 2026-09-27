class_name FlightDynamics
extends RefCounted
## The flight model, in GDScript on the Godot engine: a 6-DOF rigid body driven
## by each aircraft's own data (data/aircraft/<model>/<model>.xml, the
## JSBSim-format description files; only the data, no JSBSim code):
##   aerodynamics  the lift/drag/side/roll/pitch/yaw <function>s (FdmFunc)
##   controls      the <flight_control>/<system> channels: summer,
##                 aerosurface_scale, gain, kinematic flaps, fcs_function
##   propulsion    piston or turboprop power into the propeller's own C_THRUST /
##                 C_POWER tables, rpm from the torque balance, a governor for
##                 constant-speed props, fuel burnt from the tanks
##   gear          spring-damper contacts with rolling, braking and cornering
##                 friction against the ground plane under the aircraft
##   atmosphere    ISA, wind, and deterministic turbulence (own RNG stream)
## Internals are in the data's units: feet, slugs, pounds, seconds; body axes
## x forward, y right, z down; local frame north, east, down.

const G := 32.174
const DT := 1.0 / 120.0
const IN_TO_FT := 1.0 / 12.0
const R_AIR := 1716.49
const RHO0 := 0.0023769
const KT_FPS := 1.6878099

var dt := DT
var model := ""

# ----- configuration (from the XML)
var sw := 174.0  ## wing area ft^2
var bw := 35.8  ## span ft
var cbar := 4.9  ## chord ft
var aero_rp := Vector3.ZERO  ## structural frame, in
var empty_lb := 1500.0
var empty_cg := Vector3.ZERO  ## structural, in
var i_empty := Basis()  ## slug ft^2 about the empty CG, body axes
var stations: Array = []  ## [{loc: Vector3 (in), lb}]
var tanks: Array = []  ## [{loc, cap, lb}]
var contacts: Array = []  ## gear units
var engines: Array = []
var _aero_pre: Array = []  ## [[prop, expr]] named functions evaluated first
var _axes := {}  ## axis -> [expr...]
var _fcs: Array = []  ## FCS components in order

# ----- state
var north := 0.0  ## ft
var east := 0.0
var h := 0.0  ## CG altitude ASL ft
var quat := Quaternion.IDENTITY  ## body -> local NED
var uvw := Vector3.ZERO  ## body velocity ft/s
var pqr := Vector3.ZERO  ## body rates rad/s
var sim_time := 0.0
var terrain_ft := 0.0  ## ground plane under the aircraft
var wind_ned := Vector3.ZERO  ## air mass velocity, ft/s
var turb_severity := 0  ## 0 off, 1..3
var p := {}  ## the property map the functions read

# ----- derived each step
var weight := 0.0
var mass := 1.0
var cg := Vector3.ZERO  ## structural in
var inertia := Basis()
var inertia_inv := Basis()
var vt := 0.0
var alpha := 0.0
var beta := 0.0
var qbar := 0.0
var rho := RHO0
var _alpha_prev := 0.0
var _mass_t := 1e9
var _gust := Vector3.ZERO
var _rng := PyRandom.new()


func _init() -> void:
	_rng.seed(19791986)


# ================================================================== loading
func load_model(data_root: String, name: String) -> bool:
	model = name
	var dir := "%s/aircraft/%s" % [data_root, name]
	var tree := MassData.parse_xml("%s/%s.xml" % [dir, name])
	if tree == null:
		return false
	var met := tree.find("metrics")
	sw = _num(met.find("wingarea"), "FT2")
	bw = _num(met.find("wingspan"), "FT")
	cbar = _num(met.find("chord"), "FT")
	var arp := met.find_where("location", "name", "AERORP")
	aero_rp = _loc(arp) if arp != null else Vector3.ZERO
	var mb := tree.find("mass_balance")
	empty_lb = _num(mb.find("emptywt"), "LBS")
	empty_cg = _loc(mb.find_where("location", "name", "CG"))
	var ixx := _num(mb.find("ixx"), "SLUG*FT2")
	var iyy := _num(mb.find("iyy"), "SLUG*FT2")
	var izz := _num(mb.find("izz"), "SLUG*FT2")
	var ixz := _num(mb.find("ixz"), "SLUG*FT2")
	i_empty = Basis(Vector3(ixx, 0, -ixz), Vector3(0, iyy, 0), Vector3(-ixz, 0, izz))  # columns; symmetric
	for t in tree.iter("tank"):
		if t.attr("type", "FUEL").to_upper() != "FUEL":
			continue
		var cap := _num(t.find("capacity"), "LBS")
		var cont := t.find("contents")
		tanks.append({"loc": _loc(t.find("location")), "cap": cap, "lb": _num(cont, "LBS") if cont != null else 0.0})
	for c in tree.find("ground_reactions").iter("contact"):
		contacts.append({"name": c.attr("name"), "bogey": c.attr("type", "BOGEY") == "BOGEY", "loc": _loc(c.find("location")),
			"k": _num(c.find("spring_coeff"), "LBS/FT"), "c": _num(c.find("damping_coeff"), "LBS/FT/SEC"),
			"mu_s": _f(c, "static_friction", 0.8), "mu_d": _f(c, "dynamic_friction", 0.5), "mu_r": _f(c, "rolling_friction", 0.02),
			"steer": deg_to_rad(_f(c, "max_steer", 0.0)), "brake": _txt(c, "brake_group", "NONE").to_upper(), "wow": false, "comp": 0.0})
	_load_engines(tree, data_root, dir)
	_load_aero(tree.find("aerodynamics"))
	var fc := tree.find("flight_control")
	if fc != null:
		_load_fcs(fc)
	for s in tree.children:
		if s.tag == "system" and s.attrs.has("file"):
			var f := "%s/Systems/%s" % [dir, s.attr("file")]
			if not f.ends_with(".xml"):
				f += ".xml"
			if FileAccess.file_exists(f):
				_load_fcs(MassData.parse_xml(f))
	for k in ["gear/gear-pos-norm", "gear/gear-cmd-norm"]:
		p[k] = 1.0
	_update_mass()
	return true


static func _txt(n: MassData.XNode, tag: String, default := "") -> String:
	var c := n.find(tag)
	return c.text.strip_edges() if c != null else default


static func _f(n: MassData.XNode, tag: String, default := 0.0) -> float:
	var c := n.find(tag)
	return float(c.text.strip_edges()) if c != null else default


const _UNITS := {"FT2": 1.0, "M2": 10.7639, "FT": 1.0, "M": 3.28084, "IN": 1.0 / 12.0, "LBS": 1.0, "KG": 2.20462,
	"SLUG*FT2": 1.0, "KG*M2": 0.737562, "LBS/FT": 1.0, "N/M": 0.0685218, "LBS/FT/SEC": 1.0, "N/M/SEC": 0.0685218, "DEG": 1.0}


static func _num(n: MassData.XNode, want: String) -> float:
	if n == null:
		return 0.0
	var v := float(n.text.strip_edges())
	var u := n.attr("unit", want).to_upper()
	if u == want:
		return v
	return v * float(_UNITS.get(u, 1.0)) / float(_UNITS.get(want, 1.0))


## A <location> in the structural frame, inches.
static func _loc(n: MassData.XNode) -> Vector3:
	if n == null:
		return Vector3.ZERO
	var k := 1.0
	match n.attr("unit", "IN").to_upper():
		"FT":
			k = 12.0
		"M":
			k = 39.3701
	return Vector3(_f(n, "x"), _f(n, "y"), _f(n, "z")) * k


## Structural (x aft, y right, z up; in) -> body (x fwd, y right, z down; ft) relative to the CG.
func _body(loc: Vector3) -> Vector3:
	return Vector3(-(loc.x - cg.x), loc.y - cg.y, -(loc.z - cg.z)) * IN_TO_FT


func _load_aero(a: MassData.XNode) -> void:
	for c in a.children:
		if c.tag == "function":
			_aero_pre.append([c.attr("name"), FdmFunc.compile(c)])
		elif c.tag == "axis":
			var fs := []
			for f in c.children:
				if f.tag == "function":
					fs.append(FdmFunc.compile(f))
			_axes[c.attr("name")] = fs


func _engine_file(data_root: String, dir: String, name: String) -> MassData.XNode:
	for f in ["%s/Engines/%s.xml" % [dir, name], "%s/engine/%s.xml" % [data_root, name]]:
		if FileAccess.file_exists(f):
			return MassData.parse_xml(f)
	push_error("FlightDynamics: no engine file " + name)
	return null


func _load_engines(tree: MassData.XNode, data_root: String, dir: String) -> void:
	var prop_node := tree.find("propulsion")
	if prop_node == null:
		return
	for e in prop_node.children:
		if e.tag != "engine":
			continue
		var ef := _engine_file(data_root, dir, e.attr("file"))
		var th := e.find("thruster")
		var tf := _engine_file(data_root, dir, th.attr("file"))
		var eng := {"type": ef.tag, "running": false, "rpm": 0.0, "pitch": 0.0, "thrust": 0.0, "flow_pps": 0.0, "q_prop": 0.0,
			"loc": _loc(th.find("location")), "sense": _f(th, "sense", 1.0)}
		if ef.tag == "piston_engine":
			eng.maxhp = _f(ef, "maxhp", 160.0)
			eng.bsfc = _f(ef, "bsfc", 0.45)
			eng.idlerpm = _f(ef, "idlerpm", 600.0)
			eng.maxrpm = _f(ef, "maxrpm", 2700.0)
			eng.minmp = _f(ef, "minmp", 10.0)
			eng.maxmp = _f(ef, "maxmp", 28.5)
		else:  # turboprop (the PT6): shaft power
			eng.maxhp = _num(ef.find("maxpower"), "HP") if ef.find("maxpower") != null else 600.0
			eng.bsfc = _f(ef, "psfc", 0.6)
			eng.idlerpm = 0.0
		eng.d = _num(tf.find("diameter"), "FT") if tf.find("diameter").attr("unit", "IN").to_upper() != "IN" else _f(tf, "diameter") / 12.0
		eng.ixx = _f(tf, "ixx", 1.7)
		eng.gear = _f(tf, "gearratio", 1.0)
		eng.minpitch = _f(tf, "minpitch", 20.0)
		eng.maxpitch = _f(tf, "maxpitch", 20.0)
		eng.minrpm = _f(tf, "minrpm", 0.0)
		eng.govrpm = _f(tf, "maxrpm", eng.get("maxrpm", 2700.0) / eng.gear)
		eng.ct = FdmFunc.named_table(tf, "C_THRUST")
		eng.cp = FdmFunc.named_table(tf, "C_POWER")
		eng.ctf = _f(tf, "ct_factor", 1.0)  # the calibration multipliers JSBSim's prop files use
		eng.cpf = _f(tf, "cp_factor", 1.0)
		eng.pitch = eng.minpitch
		engines.append(eng)


# ------------------------------------------------------------------ FCS
static func _default_out(name: String) -> String:
	return "fcs/" + name.to_lower().replace(" ", "-")


func _load_fcs(root: MassData.XNode) -> void:
	for ch in root.children:
		if ch.tag != "channel":
			continue
		for c in ch.children:
			var comp := {"type": c.tag, "name": c.attr("name"), "inputs": [], "out": [], "clip": null}
			for k in c.children:
				match k.tag:
					"input":
						comp.inputs.append(k.text.strip_edges())
					"output":
						comp.out.append(k.text.strip_edges())
					"clipto":
						comp.clip = [_f(k, "min", -INF), _f(k, "max", INF)]
					"gain":
						comp.gain = float(k.text.strip_edges())
					"bias":
						comp.bias = float(k.text.strip_edges())
					"domain":
						comp.domain = [_f(k, "min", -1.0), _f(k, "max", 1.0)]
					"range":
						comp.range = [_f(k, "min", -1.0), _f(k, "max", 1.0)]
					"traverse":
						var st := []
						for s in k.children:
							if s.tag == "setting":
								st.append([_f(s, "position"), _f(s, "time")])
						comp.settings = st
					"function":
						comp.fn = FdmFunc.compile(k)
			if comp.name != "":
				comp.out.push_front(_default_out(comp.name))
			if c.tag in ["summer", "aerosurface_scale", "pure_gain", "gain", "kinematic", "fcs_function"]:
				# (autopilot inputs, ap/*, read as 0: the game flies its own autopilot)
				comp.state = 0.0
				_fcs.append(comp)


func _in(name: String) -> float:
	if name.begins_with("-"):
		return -float(p.get(name.substr(1), 0.0))
	return float(p.get(name, 0.0))


func _run_fcs(step: float) -> void:
	for c in _fcs:
		var out := 0.0
		match c.type:
			"summer":
				for i in c.inputs:
					out += _in(i)
				out += c.get("bias", 0.0)
			"pure_gain", "gain":
				out = _in(c.inputs[0]) * c.get("gain", 1.0) if not c.inputs.is_empty() else 0.0
			"aerosurface_scale":
				var x := _in(c.inputs[0]) if not c.inputs.is_empty() else 0.0
				var dom: Array = c.get("domain", [-1.0, 1.0])
				var rng: Array = c.get("range", [-1.0, 1.0])
				if x >= 0.0:
					out = x * (rng[1] / dom[1]) if dom[1] != 0.0 else 0.0
				else:
					out = x * (rng[0] / dom[0]) if dom[0] != 0.0 else 0.0
				out *= c.get("gain", 1.0)
			"kinematic":
				var st: Array = c.get("settings", [[0.0, 0.0], [1.0, 1.0]])
				var top: float = st[st.size() - 1][0]
				var target: float = clampf(_in(c.inputs[0]), 0.0, 1.0) * top if not c.inputs.is_empty() else 0.0
				var pos: float = c.state
				if pos != target:
					var rate := 1e9
					for k in range(1, st.size()):
						if pos >= st[k - 1][0] - 1e-9 and pos <= st[k][0] + 1e-9 and st[k][1] > 0.0:
							rate = (st[k][0] - st[k - 1][0]) / st[k][1]
							break
					pos = move_toward(pos, target, rate * step)
				c.state = pos
				out = pos
			"fcs_function":
				out = FdmFunc.eval(c.fn, p) if c.has("fn") else 0.0
		if c.clip != null:
			out = clampf(out, c.clip[0], c.clip[1])
		for o in c.out:
			p[o] = out


# ================================================================== state setup
func set_state(n_ft: float, e_ft: float, h_ft: float, psi: float, theta: float, phi: float, u_fps: float) -> void:
	north = n_ft
	east = e_ft
	h = h_ft
	quat = _euler_to_quat(phi, theta, psi)
	uvw = Vector3(u_fps, 0, 0)
	pqr = Vector3.ZERO
	_alpha_prev = 0.0
	_gust = Vector3.ZERO
	for c in contacts:  # a teleport: the gear is loaded only once the next step says so
		c.wow = terrain_ft - (h - (Basis(quat) * _body(c.loc)).z) > 0.0
		c.comp = 0.0


## ZYX (psi, theta, phi) body -> NED rotation as a quaternion.
static func _euler_to_quat(phi: float, theta: float, psi: float) -> Quaternion:
	var cr := cos(phi / 2)
	var sr := sin(phi / 2)
	var cp := cos(theta / 2)
	var sp := sin(theta / 2)
	var cy := cos(psi / 2)
	var sy := sin(psi / 2)
	return Quaternion(sr * cp * cy - cr * sp * sy, cr * sp * cy + sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy)


func euler() -> Vector3:  ## (phi, theta, psi) rad
	var q := quat
	var phi := atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
	var theta := asin(clampf(2 * (q.w * q.y - q.z * q.x), -1.0, 1.0))
	var psi := atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
	return Vector3(phi, theta, psi)


func v_ned() -> Vector3:
	return Basis(quat) * uvw


# ================================================================== mass
func _update_mass() -> void:
	var total := empty_lb
	var moment := empty_cg * empty_lb
	for s in stations:
		total += s.lb
		moment += s.loc * s.lb
	for t in tanks:
		total += t.lb
		moment += t.loc * t.lb
	weight = total
	mass = total / G
	cg = moment / total if total > 0.0 else empty_cg
	# inertia about the new CG: the empty inertia moved over, plus each point mass
	var ii := _shift(i_empty, _body(empty_cg), empty_lb / G)
	for s in stations:
		ii = _add(ii, _point(_body(s.loc), s.lb / G))
	for t in tanks:
		ii = _add(ii, _point(_body(t.loc), t.lb / G))
	inertia = ii
	inertia_inv = ii.inverse()


static func _point(r: Vector3, m: float) -> Basis:
	return Basis(Vector3(m * (r.y * r.y + r.z * r.z), -m * r.x * r.y, -m * r.x * r.z),
		Vector3(-m * r.x * r.y, m * (r.x * r.x + r.z * r.z), -m * r.y * r.z),
		Vector3(-m * r.x * r.z, -m * r.y * r.z, m * (r.x * r.x + r.y * r.y)))


static func _shift(i0: Basis, r: Vector3, m: float) -> Basis:
	return _add(i0, _point(r, m))


static func _add(a: Basis, b: Basis) -> Basis:
	return Basis(a.x + b.x, a.y + b.y, a.z + b.z)


func fuel_total() -> float:
	var s := 0.0
	for t in tanks:
		s += t.lb
	return s


# ================================================================== atmosphere
func _atmosphere(alt_ft: float) -> Array:  ## [rho slug/ft3, P psf, a fps, T R]
	var t := 518.67 - 0.00356616 * clampf(alt_ft, -2000.0, 36089.0)
	var pr := 2116.22 * pow(t / 518.67, 5.2559)
	return [pr / (R_AIR * t), pr, sqrt(1.4 * R_AIR * t), t]


# ================================================================== the step
func run(controls: Dictionary) -> void:
	for k in controls:
		p[k] = controls[k]
	var rb := Basis(quat)  # body -> NED
	var rt := rb.transposed()
	var atm := _atmosphere(h)
	rho = atm[0]
	# turbulence: a Gauss-Markov gust in the air mass (MIL-F-8785C-ish scale)
	if turb_severity > 0:
		var sigma: float = [0.0, 3.0, 7.0, 15.0][clampi(turb_severity, 0, 3)]
		var tau := 1.5
		var k := sqrt(2.0 * dt / tau)
		_gust = _gust * (1.0 - dt / tau) + Vector3(_rng.gauss(0, 1), _rng.gauss(0, 1), _rng.gauss(0, 1) * 0.6) * sigma * k
	else:
		_gust = Vector3.ZERO
	var air_body := uvw - rt * (wind_ned + _gust)
	vt = air_body.length()
	alpha = atan2(air_body.z, air_body.x) if vt > 0.1 else 0.0
	beta = asin(clampf(air_body.y / vt, -1.0, 1.0)) if vt > 0.1 else 0.0
	qbar = 0.5 * rho * vt * vt
	var hagl := h - terrain_ft
	var adot := (alpha - _alpha_prev) / dt
	_alpha_prev = alpha
	p["aero/qbar-psf"] = qbar
	p["metrics/Sw-sqft"] = sw
	p["metrics/bw-ft"] = bw
	p["metrics/cbarw-ft"] = cbar
	p["aero/alpha-rad"] = alpha
	p["aero/beta-rad"] = beta
	p["aero/mag-beta-rad"] = absf(beta)
	p["aero/alphadot-rad_sec"] = clampf(adot, -2.0, 2.0)
	p["aero/bi2vel"] = bw / (2.0 * vt) if vt > 1.0 else 0.0
	p["aero/ci2vel"] = cbar / (2.0 * vt) if vt > 1.0 else 0.0
	p["aero/h_b-mac-ft"] = maxf(hagl, 0.0) / bw
	p["velocities/p-aero-rad_sec"] = pqr.x
	p["velocities/q-aero-rad_sec"] = pqr.y
	p["velocities/r-aero-rad_sec"] = pqr.z
	p["velocities/p-rad_sec"] = pqr.x
	p["velocities/q-rad_sec"] = pqr.y
	p["velocities/r-rad_sec"] = pqr.z
	p["velocities/mach"] = vt / atm[2]
	p["velocities/u-aero-fps"] = air_body.x
	p["velocities/vc-kts"] = vt * sqrt(rho / RHO0) / KT_FPS
	p["velocities/ve-kts"] = p["velocities/vc-kts"]
	p["atmosphere/rho-slugs_ft3"] = rho
	p["atmosphere/P-psf"] = atm[1]
	p["position/h-agl-ft"] = hagl
	p["position/h-sl-ft"] = h
	# controls
	_run_fcs(dt)
	for s in ["elevator", "rudder", "left-aileron", "right-aileron"]:
		p["fcs/%s-pos-deg" % s] = rad_to_deg(float(p.get("fcs/%s-pos-rad" % s, 0.0)))
	p["fcs/mag-elevator-pos-rad"] = absf(float(p.get("fcs/elevator-pos-rad", 0.0)))
	for s in ["elevator", "rudder", "left-aileron", "right-aileron"]:
		if not p.has("fcs/%s-pos-norm" % s):
			p["fcs/%s-pos-norm" % s] = 0.0
	if p.has("fcs/flap-pos-deg") and not p.has("fcs/flap-pos-norm"):
		p["fcs/flap-pos-norm"] = 0.0
	# aerodynamics
	for f in _aero_pre:
		p[f[0]] = FdmFunc.eval(f[1], p)
	var drag := _axis("DRAG")
	var side := _axis("SIDE")
	var lift := _axis("LIFT")
	var ca := cos(alpha)
	var sa := sin(alpha)
	var cb := cos(beta)
	var sb := sin(beta)
	# wind axes (-D, S, -L) -> body
	var fw := Vector3(-drag, side, -lift)
	var f_aero := Vector3(ca * cb * fw.x - ca * sb * fw.y - sa * fw.z, sb * fw.x + cb * fw.y, sa * cb * fw.x - sa * sb * fw.y + ca * fw.z)
	var m_aero := Vector3(_axis("ROLL"), _axis("PITCH"), _axis("YAW")) + _body(aero_rp).cross(f_aero)
	# propulsion
	var f_prop := Vector3.ZERO
	var m_prop := Vector3.ZERO
	_propulsion(air_body.x, atm)
	for e in engines:
		var r := _body(e.loc)
		var f := Vector3(e.thrust, 0, 0)
		f_prop += f
		m_prop += r.cross(f) + Vector3(-e.sense * e.q_prop, 0, 0)  # the prop's torque rolls the other way
	# gear
	var gear := _gear(rb, rt)
	# gravity
	var f_grav := rt * Vector3(0, 0, weight)
	var f: Vector3 = f_aero + f_prop + gear[0] + f_grav
	var m: Vector3 = m_aero + m_prop + gear[1]
	# integrate: body-axis rigid body, semi-implicit Euler
	var udot: Vector3 = f / mass - pqr.cross(uvw)
	var pdot := inertia_inv * (m - pqr.cross(inertia * pqr))
	uvw += udot * dt
	pqr += pdot * dt
	var wq := Quaternion(pqr.x, pqr.y, pqr.z, 0.0)
	var qd := quat * wq
	quat = Quaternion(quat.x + 0.5 * qd.x * dt, quat.y + 0.5 * qd.y * dt, quat.z + 0.5 * qd.z * dt, quat.w + 0.5 * qd.w * dt).normalized()
	var vn := Basis(quat) * uvw
	north += vn.x * dt
	east += vn.y * dt
	h -= vn.z * dt
	sim_time += dt
	_mass_t += dt
	if _mass_t > 0.5:
		_mass_t = 0.0
		_update_mass()
	p["accelerations/udot-ft_sec2"] = udot.x


func _axis(name: String) -> float:
	var s := 0.0
	for e in _axes.get(name, []):
		s += FdmFunc.eval(e, p)
	return s


# ------------------------------------------------------------------ engines
func _propulsion(u_air: float, atm: Array) -> void:
	var sigma: float = atm[0] / RHO0
	var burn := 0.0
	var dry := fuel_total() <= 0.0
	for i in engines.size():
		var e: Dictionary = engines[i]
		var thr := clampf(float(p.get("fcs/throttle-cmd-norm[%d]" % i, p.get("fcs/throttle-cmd-norm", 0.0))), 0.0, 1.0)
		if dry:
			e.running = false
		var n: float = e.rpm / 60.0
		var d: float = e.d
		var j := u_air / (n * d) if n > 0.5 else 4.0
		var ct: float = FdmFunc.at(e.ct, j, e.pitch) * e.ctf
		var cpw: float = maxf(FdmFunc.at(e.cp, j, e.pitch), 0.0) * e.cpf
		e.thrust = ct * rho * n * n * pow(d, 4)
		var p_abs := cpw * rho * n * n * n * pow(d, 5)  # ft lb/s
		var omega := TAU * maxf(n, 1.0)
		e.q_prop = p_abs / omega
		var hp := 0.0
		if e.running:
			if e.type == "piston_engine":
				var eng_rpm: float = e.rpm * e.gear
				# manifold pressure: the idle stop up to what the air outside gives (capped
				# at the rated MAP); power follows the charge above the pumping loss, times
				# rpm, less the friction that grows with rpm squared
				var amb_inhg: float = atm[1] / 70.7262
				var mp: float = minf(e.minmp + thr * (amb_inhg - e.minmp), e.maxmp)
				var mp0: float = e.minmp * 0.8
				var rf: float = eng_rpm / e.maxrpm
				hp = e.maxhp * maxf(0.0, 1.08 * (mp - mp0) / (e.maxmp - mp0) * rf - 0.08 * rf * rf)
				if eng_rpm < e.idlerpm:  # the idle governor (the carburettor's idle stop, the starter)
					hp = maxf(hp, e.maxhp * 0.12 * (1.0 - eng_rpm / e.idlerpm))
			else:
				hp = e.maxhp * (0.03 + 0.97 * thr) * pow(sigma, 0.8)  # flight idle is a few per cent
			e.flow_pps = e.bsfc * hp / 3600.0
			burn += e.flow_pps * dt
		else:
			e.flow_pps = 0.0
		var q_eng := hp * 550.0 / maxf(omega, TAU * 5.0)
		var friction: float = 0.02 * e.maxhp * 550.0 / (TAU * 45.0) * (e.rpm / maxf(e.govrpm, 1.0))
		e.rpm = maxf(0.0, e.rpm + (q_eng - e.q_prop - friction) / e.ixx * dt * 60.0 / TAU)
		# constant-speed prop: the governor trades blade pitch for rpm
		if e.maxpitch > e.minpitch:
			var err: float = e.rpm - e.govrpm
			e.pitch = clampf(e.pitch + clampf(err * 0.02, -15.0, 15.0) * dt, e.minpitch, e.maxpitch)
	if burn > 0.0:
		_burn(burn)


func _burn(lb: float) -> void:
	var live := tanks.filter(func(t): return t.lb > 0.0)
	var each := lb / maxf(1, live.size())
	for t in live:
		t.lb = maxf(0.0, t.lb - each)


# ------------------------------------------------------------------ gear
func _gear(rb: Basis, rt: Basis) -> Array:
	var f_tot := Vector3.ZERO
	var m_tot := Vector3.ZERO
	var steer_cmd := clampf(float(p.get("fcs/steer-cmd-norm", 0.0)), -1.0, 1.0)
	var bl := clampf(float(p.get("fcs/left-brake-cmd-norm", 0.0)), 0.0, 1.0)
	var br := clampf(float(p.get("fcs/right-brake-cmd-norm", 0.0)), 0.0, 1.0)
	var bc := clampf(float(p.get("fcs/center-brake-cmd-norm", 0.0)), 0.0, 1.0)
	for c in contacts:
		var r := _body(c.loc)
		var r_ned := rb * r
		var depth := terrain_ft - (h - r_ned.z)  # contact point below the ground plane
		c.wow = depth > 0.0
		c.comp = maxf(depth, 0.0)
		if not c.wow:
			continue
		var v_cp := rb * (uvw + pqr.cross(r))  # NED velocity of the contact point
		var n_force := maxf(0.0, c.k * depth + c.c * v_cp.z)
		# the wheel's rolling direction on the ground
		var yaw: float = euler().z + (c.steer * steer_cmd if c.steer != 0.0 else 0.0)
		var fwd := Vector3(cos(yaw), sin(yaw), 0)
		var right := Vector3(-sin(yaw), cos(yaw), 0)
		var v_roll := v_cp.dot(fwd)
		var v_side := v_cp.dot(right)
		var brake := 0.0
		match c.brake:
			"LEFT":
				brake = maxf(bl, bc)
			"RIGHT":
				brake = maxf(br, bc)
			"CENTER":
				brake = bc
		var mu_roll: float = c.mu_r + brake * c.mu_s * 0.9 if c.bogey else c.mu_d
		var f_roll := -mu_roll * n_force * clampf(v_roll / 0.6, -1.0, 1.0)
		var mu_side: float = c.mu_s if c.bogey else c.mu_d
		var f_side := -mu_side * n_force * clampf(v_side / 0.5, -1.0, 1.0)
		var f_ned := fwd * f_roll + right * f_side + Vector3(0, 0, -n_force)
		var f_body := rt * f_ned
		f_tot += f_body
		m_tot += r.cross(f_body)
	return [f_tot, m_tot]


func wow_count() -> int:
	var n := 0
	for c in contacts:
		if c.wow and c.bogey:
			n += 1
	return n


# ================================================================== property façade
## The few property paths the game and its tests still address by name (tank
## contents, wind, turbulence), so callers didn't have to change.
func set_property(path: String, v: float) -> void:
	if path.begins_with("propulsion/tank[") and path.ends_with("]/contents-lbs"):
		var i := int(path.get_slice("[", 1).get_slice("]", 0))
		if i < tanks.size():
			tanks[i].lb = clampf(v, 0.0, tanks[i].cap)
			_update_mass()
		return
	match path:
		"atmosphere/wind-north-fps":
			wind_ned.x = v
		"atmosphere/wind-east-fps":
			wind_ned.y = v
		"atmosphere/wind-down-fps":
			wind_ned.z = v
		"atmosphere/turb-type":
			p["atmosphere/turb-type"] = v
			turb_severity = int(p.get("atmosphere/turbulence/milspec/severity", 0)) if v > 0 else 0
		"atmosphere/turbulence/milspec/severity":
			p[path] = v
			if int(p.get("atmosphere/turb-type", 0)) > 0:
				turb_severity = int(v)
		_:
			p[path] = v


func get_property(path: String) -> float:
	if path.begins_with("propulsion/tank[") and path.ends_with("]/contents-lbs"):
		var i := int(path.get_slice("[", 1).get_slice("]", 0))
		return tanks[i].lb if i < tanks.size() else 0.0
	match path:
		"atmosphere/wind-north-fps":
			return wind_ned.x
		"atmosphere/wind-east-fps":
			return wind_ned.y
		"propulsion/total-fuel-lbs":
			return fuel_total()
		"inertia/weight-lbs":
			return weight
		"inertia/cg-x-in":
			return cg.x
	return float(p.get(path, 0.0))


func has_property(path: String) -> bool:
	return path.begins_with("atmosphere/") or path.begins_with("propulsion/tank[") or p.has(path)
