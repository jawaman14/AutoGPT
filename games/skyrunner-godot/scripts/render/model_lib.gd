class_name ModelLib
extends RefCounted
## The low-poly models the world is drawn with: Kenney's CC0 kits (Blocky
## Characters, Car Kit, Weapon Pack, Watercraft Kit, the Nature Kit's palms;
## assets/models/kenney/LICENSE.txt). Every model comes back wrapped in a pivot
## that puts it in the game's conventions - metres, origin at the base, facing
## -Z (Godot forward) - so callers never see the kit's own scale or facing.
##
## Scenes are loaded once and cached; a missing file returns null, and every
## caller keeps its procedural fallback (so a stripped export still draws).
##
## The cast, 1980s coast: the organisation in suits and vests (q, k, p, b),
## Los Cuervos in bandoliers and work clothes (m, a, c), the task force in
## uniform and plain clothes (j, i), SWAT in black (r); the Family in dark
## suits. Cars: a white sports coupe for the organisation, pickups and SUVs for
## Los Cuervos, black-and-whites for the police, a luxury SUV for the Family.

static var ENABLED := true

const ROOT := "res://assets/models/kenney/"
const MAN_H := 1.8  ## metres, feet to the top of the head
const CHAR_H := 2.7  ## the kit's characters, in its units
const CHARACTERS := {"org": ["q", "k", "p", "b"], "rival": ["m", "a", "c"], "police": ["j", "i"], "swat": ["r"],
	"family": ["q", "b"]}
## faction -> kind -> car model; SWAT rides the police van
const CARS := {"org": {"car": "sedan-sports", "truck": "van"}, "rival": {"car": "suv", "truck": "truck-flat"},
	"police": {"car": "police", "truck": "van"}, "family": {"car": "suv-luxury", "truck": "van"},
	"civilian": {"car": "sedan", "truck": "taxi"}}
const CAR_LEN := {"car": 4.6, "truck": 5.4}  ## metres, bumper to bumper
const WEAPONS := {"pistol": "pistol", "rifle": "sniper", "mg": "machinegun", "rpg": "rocketlauncher", "smg": "uzi"}
const WEAPON_LEN := {"pistol": 0.26, "rifle": 1.0, "mg": 1.05, "rpg": 1.2, "smg": 0.4}
## where a man carries a pistol (right hand, out front) and a long gun (both hands, at the chest)
const HOLD := [Vector3(0.18, 1.2, -0.6), Vector3(0.1, 1.12, -0.42)]
const BOATS := {"gofast": ["boat-speed-a", 12.0], "cutter": ["boat-tug-a", 30.0]}  ## model, length in m
const PALMS := ["tree_palmTall", "tree_palmBend", "tree_palm", "tree_palmShort"]

static var _cache := {}


static func scene(path: String) -> PackedScene:
	if not ENABLED:
		return null
	if _cache.has(path):
		return _cache[path]
	var full := ROOT + path + ".glb"
	var ps: PackedScene = load(full) if ResourceLoader.exists(full) else null
	_cache[path] = ps
	return ps


## The model's bounds, in its own units (every mesh, through its transforms).
static func bounds(n: Node) -> AABB:
	var acc := [null]
	_bounds(n, Transform3D.IDENTITY, acc)
	return acc[0] if acc[0] != null else AABB()


static func _bounds(n: Node, xf: Transform3D, acc: Array) -> void:
	var t: Transform3D = xf * (n as Node3D).transform if n is Node3D else xf
	if n is MeshInstance3D:
		var a: AABB = t * n.get_aabb()
		acc[0] = a if acc[0] == null else acc[0].merge(a)
	for c in n.get_children():
		_bounds(c, t, acc)


## `path` wrapped in a pivot: scaled by `s`, turned `yaw` about Y, origin at base centre.
static func wrapped(path: String, s: float, yaw := PI, centre := true) -> Node3D:
	var ps := scene(path)
	if ps == null:
		return null
	var m: Node3D = ps.instantiate()
	var pivot := Node3D.new()
	pivot.name = path.get_file()
	pivot.add_child(m)
	m.scale = Vector3.ONE * s
	m.rotation.y = yaw
	if centre:
		var b := bounds(m)
		var c := m.transform * b.get_center()
		m.position = Vector3(-c.x, 0.0, -c.z)
	return pivot


## Scale that makes `path` `length` metres along its longest horizontal axis.
static func fit_scale(path: String, length: float) -> float:
	var ps := scene(path)
	if ps == null:
		return 1.0
	var m: Node3D = ps.instantiate()
	var b := bounds(m)
	m.free()
	return length / maxf(0.01, maxf(b.size.x, b.size.z))


## A man of `faction` (variant picks among its looks), 1.8 m, facing -Z, feet at 0.
## The pivot carries meta "anim" (its AnimationPlayer) and "look" (the kit's letter).
static func character(faction: String, variant := 0) -> Node3D:
	var looks: Array = CHARACTERS.get(faction, CHARACTERS.org)
	var c: String = looks[posmod(variant, looks.size())]
	var n := wrapped("characters/character-" + c, MAN_H / CHAR_H, PI, false)
	if n == null:
		return null
	var ap: AnimationPlayer = n.find_child("AnimationPlayer", true, false)
	if ap != null:
		for a in ["walk", "sprint", "idle", "holding-both", "holding-both-shoot", "holding-right", "holding-right-shoot", "drive"]:
			if ap.has_animation(a):
				ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	n.set_meta("anim", ap)
	n.set_meta("look", c)
	return n


## Give a character a weapon (or change it); returns the weapon node (or null).
## It's carried at the chest, barrel forward: the kit's holding animations
## raise the arms onto it (the arms swing on their own clocks, so a gun parented
## to a hand would wave about).
static func arm(man: Node3D, tier: String) -> Node3D:
	if not WEAPONS.has(tier):
		return null
	var old = man.get_node_or_null("weapon")
	if old != null:
		if old.get_meta("tier", "") == tier:
			return old
		old.free()
	var w := weapon(tier)
	if w == null:
		return null
	w.name = "weapon"
	w.set_meta("tier", tier)
	w.position = HOLD[0] if tier == "pistol" else HOLD[1]
	man.add_child(w)
	return w


## A weapon `tier`, the barrel along -Z (the kit points them along +Z), in metres x `mul`.
static func weapon(tier: String, mul := 1.0) -> Node3D:
	var path: String = "weapons/" + WEAPONS.get(tier, "pistol")
	return wrapped(path, fit_scale(path, WEAPON_LEN.get(tier, 0.5)) * mul)


## A squad's vehicle, facing -Z, wheels on the ground.
static func car(faction: String, kind: String) -> Node3D:
	var k := "truck" if kind == "truck" else "car"
	var path: String = "cars/" + CARS.get(faction, CARS.civilian)[k]
	return wrapped(path, fit_scale(path, CAR_LEN[k]))


## A boat, `kind` gofast | cutter, facing -Z, waterline near 0.
static func boat(kind: String) -> Node3D:
	var b: Array = BOATS.get(kind, BOATS.gofast)
	var path: String = "boats/" + b[0]
	var n := wrapped(path, fit_scale(path, b[1]))
	if n != null:
		n.get_child(0).position.y -= 0.25 * fit_scale(path, b[1])  # sit in the water, not on it
	return n


## A palm's mesh (for MultiMesh use), `height` metres tall: [mesh, scale].
static func palm_mesh(variant: int, height: float) -> Array:
	var path: String = "nature/" + PALMS[posmod(variant, PALMS.size())]
	var ps := scene(path)
	if ps == null:
		return []
	var m: Node3D = ps.instantiate()
	var mis := m.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = mis[0].mesh if not mis.is_empty() else null
	m.free()
	if mesh == null:
		return []
	return [mesh, height / maxf(0.01, mesh.get_aabb().size.y)]  # the raw mesh: a MultiMesh ignores the scene's transforms
