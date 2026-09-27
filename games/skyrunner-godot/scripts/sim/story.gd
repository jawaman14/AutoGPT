class_name Story
extends RefCounted
## The story: Costa Brava, 1979-1989. From a bush pilot flying square grouper
## for a boat dealer to the organisation the whole coast answers to.
##
## Each chapter opens part of the game - a system (Session.SYSTEMS) or a lock
## (guns, the payroll's soldiers and mules) - and sets a few goals that the
## systems themselves measure. The ramp is the point: you learn the trade before
## the war, the war before the Family, the Family before the court, and only
## then the island and the Company, each one alone first. The open mode (no
## Story) has every faction and mechanic from the first minute.
##
## Chapters reuse Campaign.Chapter/Objective, so the HUD, the briefing card and
## the desks show a chapter whichever mode set it.

## Keys a chapter can open besides the systems: what Session.unlocked() asks.
const LOCKS := ["guns", "role_soldier", "role_mule"]

## [year, title, briefing, opens, goals [[key, text, target]]]
const CHAPTERS := [
	[1979, "Square Grouper",
		"San Telmo, 1979. The Cessna is half the bank's, the charters don't cover the fuel,\n"
		+ "and Benny Ruiz at the boatyard knows men up in the hills with bales of grass.\n"
		+ "Buy it at the bush strips, fly it into our stash houses, and hire a kid or two\n"
		+ "to sell it on the corners [SHIFT+W]. Low money, low risk - for now.",
		["trade", "payroll", "chronicle"],
		[["weed_lb", "Fly 300 lb of marijuana into our stash houses", 300], ["dealers", "Put a street dealer on a corner", 1],
			["trade_earned", "Make $4,000 from the trade", 4000]]],
	[1980, "The Connection",
		"The boatlift brings a hundred thousand people across the straits, and a few of them\n"
		+ "know the Colombians. Grass pays by the ton; the white stuff pays by the ounce.\n"
		+ "And it's a business now: product sits in a stash, the money piles up on the corners,\n"
		+ "and the growers want cash on the strip. Truck it, fly it, count it [SHIFT+H].",
		["logistics"],
		[["cash_home", "Truck or fly $3,000 of street money home", 3000],
			["connected", "Get the call from the Colombian connection", 1]]],
	[1981, "Cocaine Cowboys",
		"Kilo bricks now, at the shady strips. And the money brings Los Cuervos: a crew\n"
		+ "from the west side who'd rather take our corners than build their own.\n"
		+ "Machine guns in the malls, bodies in the canals. Arm up: gun runs are on the\n"
		+ "boards, soldiers in the hiring hall, and the war is on the streets [TAB on foot].",
		["ground_war", "guns", "role_soldier"],
		[["coke_lb", "Fly 60 lb of cocaine home", 60], ["arsenal", "Stock 8 weapons in the armoury", 8]]],
	[1982, "Family Business",
		"Word reaches Tampa. Sal Moretti's people run the unions, the casinos and the\n"
		+ "judges who owe them favours - and they want a piece of Costa Brava. Their help\n"
		+ "is real. Sometimes. Read the offer before you take it [SHIFT+F].",
		["family"],
		[["family_deal", "Do business with the Morettis (an offer, a loan or a bulk sale)", 1], ["bank", "Have $30,000 in the bank", 30000]]],
	[1983, "The Task Force",
		"Washington sends a task force: federal prosecutors, a grand jury, and agents who\n"
		+ "follow the money. A bust is no longer a fine - it's a case, with bail, lawyers,\n"
		+ "and men of ours who might decide to talk [SHIFT+L].",
		["court"],
		[["hot_loads", "Deliver 3 hot loads with the task force watching", 3], ["clean", "Keep their case under 60% at the end", 1]]],
	[1984, "Isla Soberana",
		"Twenty-three kilometres south, the General's island sells product at a third of\n"
		+ "the street price and doesn't extradite. Captain Ibarra will see you on the ramp.\n"
		+ "Fly it, walk it through the airport on mules, or ship it in a container [SHIFT+G].",
		["island", "role_mule"],
		[["island_runs", "Bring a load home from Isla Soberana", 1]]],
	[1985, "The Company",
		"A man with a government haircut and no government ID. His friends fight a war in\n"
		+ "Central America that Congress won't pay for. Fly his crates south, bring his\n"
		+ "product north, sell him guns - and pray nobody ever holds the hearings.",
		["agency"],
		[["agency_jobs", "Fly a job for the Company", 1], ["guns_to_company", "Sell the Company 4 guns", 4]]],
	[1986, "Kingpin",
		"The mandatory minimums pass, the Commission trial starts in New York, and every\n"
		+ "faction on the coast wants what's ours. Build it big enough that it doesn't\n"
		+ "matter who talks: sixty-five grand in cash and product, and walk away.",
		[],
		[["net_worth", "Be worth $65,000 (cash and product)", 65000]]],
]

var index := 0
var progress := {}  ## goal key -> value this chapter
var opened := {}  ## every system and lock opened so far
var completed_all := false
var show_briefing := true
var sess = null
var _chapter: Campaign.Chapter = null


func _init(index_ := 0, progress_ = null) -> void:
	index = clampi(index_, 0, CHAPTERS.size() - 1)
	progress = progress_.duplicate() if progress_ is Dictionary else {}


var chapter: Campaign.Chapter:
	get:
		if _chapter == null or _chapter.num != index + 1:
			var c: Array = CHAPTERS[index]
			var goals := []
			for g in c[4]:
				goals.append(Campaign.Objective.new(g[0], g[1], g[2]))
			_chapter = Campaign.Chapter.new(index + 1, c[0], c[1], c[2], [], [], goals)
		return _chapter


func to_dict() -> Dictionary:
	return {"index": index, "progress": progress, "done": completed_all}


static func from_dict(d) -> Story:
	if not (d is Dictionary):
		d = {}
	var st := Story.new(int(d.get("index", 0)), d.get("progress"))
	st.completed_all = bool(d.get("done", false))
	return st


func is_unlocked(key: String) -> bool:
	return completed_all or opened.has(key)


## Every system and lock chapters 1..n open.
static func opens_through(n: int) -> Array:
	var out := []
	for i in mini(n, CHAPTERS.size()):
		out += CHAPTERS[i][3]
	return out


# ------------------------------------------------------------ wiring
## Takes over the session: everything the chapters so far opened is built, the
## rest waits. The trade starts in career mode (grass until the connection).
func attach(s) -> void:
	sess = s
	s.story = self
	s.bus.subscribe("*", _on_event)
	if s.trade == null:
		s.enable_system("trade", true)
	for i in index + 1:
		_open(i, i == index)
	if index >= 2 and s.trade != null:
		s.trade.connected = true  # a saved game past 1980 already has the call
	if completed_all:
		for k in Session.SYSTEMS:
			s.enable_system(k)
	show_briefing = true
	s.say("CHAPTER %d (%d): %s" % [index + 1, chapter.year, chapter.title])


func _open(i: int, announce: bool) -> void:
	var names := []
	for key in CHAPTERS[i][3]:
		opened[key] = true
		if key in Session.SYSTEMS and sess.enable_system(key, true):
			names.append(NAMES.get(key, key))
		elif key in LOCKS:
			names.append(NAMES.get(key, key))
	if announce and i > 0 and not names.is_empty():
		sess.say("Unlocked: " + ", ".join(names))
	for code in sess.boards.keys():
		sess.refresh_board(code)
	if sess.payroll != null:
		for o in sess.payroll.candidates.keys():
			sess.payroll._refresh(o)  # the hall hires for what's open now


const NAMES := {"logistics": "logistics (stock and cash have to be moved)", "trade": "the trade", "payroll": "the hiring hall", "chronicle": "the papers",
	"ground_war": "the street war with Los Cuervos", "guns": "gun runs and gun sales", "role_soldier": "soldiers",
	"family": "the Moretti family", "court": "the federal court", "island": "Isla Soberana", "role_mule": "mules",
	"agency": "the Company"}


func objective_lines() -> Array:
	var out := []
	for o in chapter.objectives:
		var v: float = progress.get(o.key, 0.0)
		var mark := "x" if v >= o.target else " "
		var count := ""
		if o.key in ["trade_earned", "bank", "net_worth", "cash_home"]:
			count = " ($%s/$%s)" % [Py.money(int(v)), Py.money(int(o.target))]
		elif o.target > 1:
			count = " (%d/%d)" % [int(v), int(o.target)]
		out.append("[%s] %s%s" % [mark, o.text, count])
	return out


# ------------------------------------------------------------ progress
func _bump(key: String, amount := 1.0) -> void:
	if Py.any(chapter.objectives, func(o): return o.key == key):
		progress[key] = progress.get(key, 0.0) + amount


func _put(key: String, v: float) -> void:
	if Py.any(chapter.objectives, func(o): return o.key == key):
		progress[key] = v


func _on_event(ev: EventBus.Event) -> void:
	var d := ev.data
	match ev.kind:
		"job_delivered":
			var good := str(d.get("good", ""))
			if good == "marijuana":
				_bump("weed_lb", float(d.get("lb", 0.0)))
			elif good == "cocaine":
				_bump("coke_lb", float(d.get("lb", 0.0)))
			if d.get("hot", false):
				_bump("hot_loads")
			if d.get("agency", false):
				_bump("agency_jobs")
			if str(d.get("origin", "")) == Island.CODE:
				_bump("island_runs")
		"island_shipment":
			_bump("island_runs")
		"cash_home":
			_bump("cash_home", float(d.get("amount", 0.0)))
		"bulk_sale":
			if d.get("buyer") == "family":
				_bump("family_deal")
			if d.get("buyer") == "agency" and d.get("good") == "guns":
				_bump("guns_to_company", float(d.get("qty", 0)))


## Polled goals (state, not events), then the chapter check.
func tick(s) -> void:
	if completed_all:
		return
	if s.trade != null:
		_put("trade_earned", float(s.trade.earned))
		_put("dealers", float(s.trade.dealers("org").size()))
		_put("connected", 1.0 if s.trade.connected else 0.0)
	if s.arsenals.has("org"):
		_put("arsenal", float(s.arsenals["org"].count()))
	if s.family != null and s.family.accepted + s.family.loans_taken > 0:
		_put("family_deal", maxf(progress.get("family_deal", 0.0), 1.0))
	# no softlocks: a faction that's gone (convicted, burned, cut us loose) can't be dealt with
	if s.family != null and s.family.gone and progress.get("family_deal", 0.0) < 1.0:
		_put("family_deal", 1.0)
		s.say("The Commission trial took the Morettis before we could deal with them. The story moves on.")
	if s.agency != null and (not s.agency.active() or s.agency.hung_out) and index == 6 and progress.get("agency_jobs", 0.0) < 99.0:
		for k in ["agency_jobs", "guns_to_company"]:
			_put(k, 99.0)
		s.say("The Company has cut us loose. So much for friends in Washington - the story moves on.")
	_put("bank", float(s.money))
	_put("net_worth", float(s.money) + (s.trade.stock_value() if s.trade != null else 0.0)
		+ (s.logistics.cash_out() if s.logistics != null else 0.0))
	if progress.get("hot_loads", 0.0) >= 3.0:
		_put("clean", 1.0 if s.police.case("runner").suspicion < 60.0 else 0.0)
	var ch := chapter
	if not Py.all(ch.objectives, func(o): return progress.get(o.key, 0.0) >= o.target):
		return
	s.say("Chapter %d complete: %s!" % [ch.num, ch.title])
	advance()


## On to the next chapter (or the end): what finishing one does, and what a
## chapter jump (--chapter N) does.
func advance() -> void:
	var s = sess
	if completed_all:
		return
	if index + 1 < CHAPTERS.size():
		index += 1
		progress = {}
		_open(index, true)
		if index == 2 and s.trade != null:
			s.trade.connected = true
		show_briefing = true
		s.say("CHAPTER %d (%d): %s" % [index + 1, chapter.year, chapter.title])
	else:
		completed_all = true
		for k in Session.SYSTEMS:
			s.enable_system(k)
		s.say("1989. The story is told - the coast is yours, for as long as it lasts. Everything stays open.")
	s.save()
