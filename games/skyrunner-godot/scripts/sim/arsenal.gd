class_name Arsenal
extends RefCounted
## Weapons by tier, held by one side: the organisation, the task force or Los
## Cuervos. Gun runs bring crates in, and on delivery the runner either sells
## them at the street price or keeps them to arm the organisation's soldiers.
## Everything the police seize (a busted load, a stopped truck, a raided stash,
## a lost firefight) goes into the task force's arsenal and arms its patrols:
## weapons change hands, they don't vanish.
##
## `fire` is a weapon's weight in a firefight (GroundWar's Lanchester rate),
## relative to a pistol; an unarmed man counts 0.25. RPGs also let a squad take
## on vehicles. `price` is the street price of one weapon before the market's
## guns multiplier (Economy).
##
## Off (no gun runs, no seizures into arsenals) for the Python replays:
## Arsenal.REALISM = false.

static var REALISM := true

const TIERS := {
	"pistol": {"name": "Pistols", "fire": 1.0, "range": 50.0, "price": 300},
	"rifle": {"name": "Rifles", "fire": 2.2, "range": 300.0, "price": 900},
	"mg": {"name": "Machine guns", "fire": 4.0, "range": 600.0, "price": 3500},
	"rpg": {"name": "RPGs", "fire": 6.0, "range": 300.0, "price": 5000},
}
const ORDER := ["rpg", "mg", "rifle", "pistol"]  ## best first
const UNARMED_FIRE := 0.25
const ROUNDS_PER_WEAPON := 120  ## a crate's worth of ammunition per gun
const START := {
	"org": {"pistol": 6, "rifle": 2},
	"law": {"pistol": 16, "rifle": 6},
	"rival": {"pistol": 8, "rifle": 6, "mg": 1},
}

var side := ""
var stock := {}  ## tier -> count
var ammo := 0  ## rounds
var cache := ""  ## the organisation's: the stash house the guns are kept in ("" = the HQ)
var seized_total := 0  ## the task force's: weapons taken off the street, all time


func _init(side_ := "", start := true) -> void:
	side = side_
	for t in TIERS:
		stock[t] = 0
	if start and START.has(side):
		for t in START[side]:
			add(t, START[side][t])


func add(tier: String, n: int) -> void:
	if TIERS.has(tier) and n > 0:
		stock[tier] += n
		ammo += n * ROUNDS_PER_WEAPON


func add_all(weapons: Dictionary) -> void:
	for t in weapons:
		add(t, int(weapons[t]))


## Take up to n; returns how many were taken.
func take(tier: String, n: int) -> int:
	if not TIERS.has(tier):
		return 0
	var k := mini(n, stock[tier])
	stock[tier] -= k
	return k


func count() -> int:
	var s := 0
	for t in stock:
		s += stock[t]
	return s


func is_empty() -> bool:
	return count() == 0


## Arm n men, best weapons first: {tier: count} taken out of the stock (men
## beyond the stock go unarmed).
func issue(n_men: int) -> Dictionary:
	var out := {}
	var left := n_men
	for t in ORDER:
		if left <= 0:
			break
		var k := take(t, left)
		if k > 0:
			out[t] = k
			left -= k
	return out


## Give a squad's weapons back (the squad disbanded, the walker climbed in).
func give_back(loadout: Dictionary) -> void:
	for t in loadout:
		if TIERS.has(t):
			stock[t] += int(loadout[t])


## A squad's firepower per man: the loadout's mean fire weight over `men`.
static func power(loadout: Dictionary, men: int) -> float:
	if men <= 0:
		return 0.0
	var armed := 0
	var f := 0.0
	for t in loadout:
		var k: int = int(loadout[t])
		armed += k
		f += k * float(TIERS[t].fire)
	f += maxi(0, men - armed) * UNARMED_FIRE
	return f / men


## Can this loadout take on vehicles?
static func anti_vehicle(loadout: Dictionary) -> bool:
	return int(loadout.get("rpg", 0)) > 0


## Street value at the market's guns multiplier.
func value(mult := 1.0) -> int:
	var v := 0.0
	for t in stock:
		v += stock[t] * float(TIERS[t].price)
	return int(v * mult)


static func worth(weapons: Dictionary, mult := 1.0) -> int:
	var v := 0.0
	for t in weapons:
		v += int(weapons[t]) * float(TIERS[t].price)
	return int(v * mult)


## Move everything into `other` (a seizure); returns what moved.
func seize_into(other: Arsenal) -> Dictionary:
	var moved := {}
	for t in stock:
		if stock[t] > 0:
			moved[t] = stock[t]
			other.stock[t] += stock[t]
			stock[t] = 0
	other.ammo += ammo
	ammo = 0
	other.seized_total += Py.sum_by(moved.values(), func(v): return v)
	return moved


## Weapons seized from elsewhere (a load, a truck, a squad) into this arsenal.
func take_seized(weapons: Dictionary) -> int:
	var n := 0
	for t in weapons:
		var k: int = int(weapons[t])
		if TIERS.has(t) and k > 0:
			stock[t] += k
			n += k
	ammo += n * ROUNDS_PER_WEAPON / 2  # half a crate's rounds come with a seizure
	seized_total += n
	return n


static func describe(weapons: Dictionary) -> String:
	var parts := []
	for t in ORDER:
		if int(weapons.get(t, 0)) > 0:
			parts.append("%d %s" % [int(weapons[t]), TIERS[t].name.to_lower()])
	return ", ".join(parts) if not parts.is_empty() else "nothing"


func to_dict() -> Dictionary:
	return {"side": side, "stock": stock.duplicate(), "ammo": ammo, "cache": cache, "seized": seized_total,
		"count": count(), "value": value()}


static func from_dict(d: Dictionary) -> Arsenal:
	var a := Arsenal.new(str(d.get("side", "")), false)
	var s: Dictionary = d.get("stock", {})
	for t in s:
		if TIERS.has(t):
			a.stock[t] = int(s[t])
	a.ammo = int(d.get("ammo", 0))
	a.cache = str(d.get("cache", ""))
	a.seized_total = int(d.get("seized", 0))
	return a


# ------------------------------------------------------------------ gun runs
## A gun run from `origin` (a shady or bush strip, the arms coming in off a
## boat): weapon crates for a live stash (trucked in) or a shady strip. On
## delivery `job.gun_mode` decides: "sell" pays the street price, "stock" puts
## the weapons in the organisation's arsenal instead.
static func gun_run(origin: Airfield, airfields: Array, stash_net, rng: PyRandom, price_mult := 1.0):
	var jid := Jobs.new_id()
	var weapons := {}
	var r := rng.random()
	if r < 0.45:
		weapons = {"rifle": rng.randint(4, 8)}
	elif r < 0.75:
		weapons = {"pistol": rng.randint(6, 12), "rifle": rng.randint(2, 4)}
	elif r < 0.92:
		weapons = {"rifle": rng.randint(2, 4), "mg": rng.randint(1, 2)}
	else:
		weapons = {"mg": 1, "rpg": rng.randint(1, 2)}
	var crates := 0
	for t in weapons:
		crates += int(ceil(weapons[t] / 4.0)) if t in ["pistol", "rifle"] else int(weapons[t])
	var items := []
	for k in crates:
		items.append(Jobs.item("Weapons crate", "cargo", rng.uniform(25, 45), jid, {"hot": true}))
	var stash = null
	var dest: Airfield = null
	if stash_net != null and rng.random() < 0.6:
		var choices: Array = stash_net.live().filter(func(s): return s.strip != origin.code)
		if not choices.is_empty():
			stash = rng.choice(choices)
			dest = World.airfield(stash.strip)
	if dest == null:
		var shady := airfields.filter(func(a): return a.kind in ["shady", "bush"] and a.code != origin.code)
		if shady.is_empty():
			return null
		dest = rng.choice(shady)
	var dist := PyMath.hypot(origin.x - dest.x, origin.y - dest.y) / 1000
	var pay := int((worth(weapons) * 0.55 + dist * 100) * Jobs._difficulty(dest) * price_mult)
	var job := Jobs.Job.new(jid, "Gun run: %s -> %s" % [describe(weapons), dest.name if stash == null else stash.name],
		"contraband", origin.code, dest.code, items, pay,
		{"notes": "Weapons. Sell them on delivery, or keep them for the organisation's soldiers [G toggles]."})
	job.weapons = weapons
	if stash != null:
		job.stash = stash.id
	return job


## The weapons a load carries: a gun run's, or two rifles per unmarked crate
## (the board's old guns cargo).
static func weapons_of(job: Jobs.Job) -> Dictionary:
	if not job.weapons.is_empty():
		return job.weapons
	var n := job.items.filter(func(i): return i.label == "Unmarked crate").size()
	return {"rifle": 2 * n} if n > 0 else {}
