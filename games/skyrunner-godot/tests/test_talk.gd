extends TestCase
## Conversations (Dialogue Manager scripts in dialogue/): they compile, the
## balloon walks them line by line, and every choice goes through the seat's
## commands - a Family offer taken, pressed or refused, the tribute stalled or
## paid, the General's passage bought, the island's news, the purge.


func after_each() -> void:
	World.use_map(0)


func _sess(opts := {}) -> Session:
	var o := {"seed": 6, "map_seed": MapCity.SEED, "location": "HAR", "features": Session.SANDBOX_FEATURES,
		"family": true, "island": true}
	o.merge(opts, true)
	var s := Session.new(o)
	s.police.frozen = true
	s.family.ai = false
	s.update(1.0 / 30)
	return s


func _offer(s: Session, kind: String, honest := true) -> Dictionary:
	for i in 200:
		var o = s.family.offer(kind)
		if o != null and o.honest == honest:
			return o
		if o != null:
			s.family.offers.erase(o)
	return {}


func _balloon(s: Session, name: String, title := "start") -> TalkBalloon:
	var b := TalkBalloon.new()
	Engine.get_main_loop().root.add_child(b)
	await b.start(Talk.resource(name), title, Talk.State.new(func(): return LocalLink.new(s, Roles.PILOT, false).snapshot(),
		func(n: String, a: Dictionary) -> Array: return s.command(Roles.PILOT, n, a)))
	return b


## Move on until an answer is asked for (or the talk ends); returns every line seen.
func _until_choice(b: TalkBalloon) -> Array:
	var seen := []
	for i in 12:
		if b.line == null:
			break
		if b.line.text != "":
			seen.append("%s: %s" % [b.line.character, b.line.text])
		if not b._answers.is_empty():
			break
		await b.advance()
	return seen


func _pick(b: TalkBalloon, starts: String) -> bool:
	for i in b._answers.size():
		if str(b._answers[i].text).begins_with(starts):
			await b.choose(i)
			return true
	return false


func _answers(b: TalkBalloon) -> Array:
	return b._answers.map(func(r): return str(r.text))


func test_the_scripts_compile() -> void:
	var f := Talk.resource("family")
	var g := Talk.resource("general")
	check(f != null and g != null, "both compile")
	for t in ["start", "offer", "choose", "tribute", "social", "gone"]:
		check(f.titles.has(t), "family: " + t)
	for t in ["start", "landing", "talk", "word", "purge"]:
		check(g.titles.has(t), "general: " + t)
	check(Engine.has_singleton("DialogueManager") or Talk.manager() != null, "the runtime, with no autoload")


func test_take_the_familys_offer() -> void:
	var s := _sess()
	s.money = 10000
	var base: float = s.maritime.seize_mult
	var o := _offer(s, "docks", true)
	var b := await _balloon(s, "family")
	var seen := await _until_choice(b)
	check(seen[0].begins_with(Talk.CAPO + ":"), "Sal does the talking: %s" % seen[0])
	check(seen.any(func(l): return "union" in l), "about the docks")
	check(seen.back().begins_with("Your man:") and o.read in seen.back(), "and our man's read on it: %s" % [seen])
	check(_answers(b).has("Take it."), "you can take it: %s" % [_answers(b)])
	await _pick(b, "Take it")
	check(s.family.offers.is_empty(), "taken")
	check_near(s.maritime.seize_mult, base * 2.0, 0.001, "the union has the docks")
	await _until_choice(b)
	check(b.line == null, "and the talk ends")
	s.dispose()


func test_press_him_for_a_second_read() -> void:
	var s := _sess()
	s.money = 10000
	var o := _offer(s, "loan", true)
	var r0 := s.family.respect
	var b := await _balloon(s, "family")
	await _until_choice(b)
	check(await _pick(b, "Press him"), "press him")
	var seen := await _until_choice(b)
	check(seen.any(func(l): return "when you pushed him" in l), "a second read: %s" % [seen])
	check(str(s.family.get_offer(o.id).get("probe", "")) != "", "recorded")
	check(not _answers(b).any(func(a): return a.begins_with("Press")), "only once")
	check(s.family.respect < r0, "it cost a little respect")
	await _pick(b, "Not today")
	check(s.family.offers.is_empty(), "turned down")
	b.queue_free()
	s.dispose()


func test_cant_cover_it() -> void:
	var s := _sess()
	s.money = 100
	_offer(s, "docks", true)
	var b := await _balloon(s, "family")
	await _until_choice(b)
	check(not _answers(b).has("Take it.") and _answers(b).any(func(a): return "can't cover" in a), "no money, no deal: %s" % [_answers(b)])
	b.queue_free()
	s.dispose()


func test_the_tribute_stalled_then_paid() -> void:
	var s := _sess()
	s.money = 100000
	s.family.update(10.0)
	check(s.family.tribute_due > 0, "they want their piece")
	var by := s.family.tribute_by
	var b := await _balloon(s, "family")
	await _until_choice(b)
	check(await _pick(b, "Ask for more time"), "stall")
	check_near(s.family.tribute_by, by + 300.0, 0.01, "five more minutes")
	b.queue_free()
	var c := await _balloon(s, "family")
	await _until_choice(c)
	check(not _answers(c).any(func(a): return a.begins_with("Ask for more")), "not twice")
	var due := s.family.tribute_due
	await _pick(c, "Pay him")
	check_eq(s.money, 100000 - due, "paid")
	c.queue_free()
	s.dispose()


func test_the_generals_aide() -> void:
	var s := _sess()
	s.money = 100000
	var b := await _balloon(s, "general")
	await _until_choice(b)
	check(_answers(b).any(func(a): return a.begins_with("Buy safe passage")), "passage on offer: %s" % [_answers(b)])
	check(_answers(b).any(func(a): return "% likely caught" in a), "the mules' odds, in the answer")
	await _pick(b, "Buy safe passage")
	check(s.island.has_passage(), "bought")
	await _until_choice(b)
	check(not _answers(b).any(func(a): return a.begins_with("Buy safe passage")), "not again while it lasts")
	await _pick(b, "Send four mules")
	check_eq(s.island.shipments.size(), 1, "mules on the airliner")
	await _until_choice(b)
	s.island.status = "shortage"
	await _pick(b, "\"What's the word")
	var seen := await _until_choice(b)
	check(seen.any(func(l): return "Shortages" in l), "the island's news: %s" % [seen])
	await _pick(b, "That's all")
	await _until_choice(b)
	check(b.line == null, "goodbye")
	s.dispose()


func test_the_purge_on_the_radio() -> void:
	var s := _sess()
	s.island.purge()
	var b := await _balloon(s, "general", "landing")
	var seen := await _until_choice(b)
	check(seen.any(func(l): return "Ibarra" in l or "arrested" in l), "a stranger's voice: %s" % [seen])
	check(b.line == null, "and nothing to buy")
	s.dispose()


func test_the_desks_and_the_cockpit_open_them() -> void:
	var s := _sess()
	s.money = 10000
	_offer(s, "docks", true)
	var st := StationApp.new()
	Engine.get_main_loop().root.add_child(st)
	st.setup(LocalLink.new(s, Roles.LIEUTENANT, false), Roles.LIEUTENANT, s.world)
	st._key("c")
	check(st.talk != null, "C at the lieutenant's desk: a sit-down with Sal")
	st.free()
	var app := PilotApp.new()
	Engine.get_main_loop().root.add_child(app)
	app.setup(s, "low")
	app._talk_cues()
	check(s.messages.any(func(m): return "wants a word" in m[1]), "the cockpit hears Sal wants a word")
	s.location = Island.CODE
	app._talk_cues()
	check(app.talk != null, "landing on the island: the aide on the ramp")
	app.free()
	s.dispose()
