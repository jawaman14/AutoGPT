extends TestCase
## The 1980s-coast look: the OFL fonts load, titles use the brush script with
## a neon glow, the HUD throws a banner on a delivery and a bust, the city has
## its palm-lined streets, and the grade is on.


func after_each() -> void:
	World.use_map(0)


func test_the_fonts_and_the_theme() -> void:
	check(UIStyle.script() is FontFile, "Kaushan Script loads")
	check(UIStyle.neon() is FontFile, "Monoton loads")
	var t := UIStyle.title("Skyrunner", 40)
	check(t.get_theme_font("font") == UIStyle.script(), "titles in the brush script")
	check(t.get_theme_constant("outline_size") > 0, "with a neon glow")
	check_eq(UIStyle.ACCENT, UIStyle.PINK, "hot pink accents")
	t.free()


func test_the_hud_banners() -> void:
	var s := Session.new({"seed": 1, "location": "FRM"})
	var hud := Hud.new()
	Engine.get_main_loop().root.add_child(hud)
	hud.setup(s)
	hud.refresh()
	check(not hud.banner.visible, "no banner at rest")
	s.bus.emit("job_delivered", s.time, "", ["runner"], {"job_id": 1, "pay": 4200, "dest": "FRM", "hot": true})
	hud.refresh()
	check(hud.banner.visible and hud.banner.text == "Run complete", "Run complete")
	check("4,200" in hud.banner_sub.text, "with the money: " + hud.banner_sub.text)
	s.bus.emit("busted", s.time, "", ["runner", "law"], {"how": "test"})
	hud.refresh()
	check_eq(hud.banner.text, "Busted", "Busted")
	hud.free()
	s.dispose()


func test_palm_lined_streets_and_the_grade() -> void:
	World.use_map(MapCity.SEED)
	var w := World.new()
	var ws := WorldScene.new().setup(w, Quality.get_preset("low"))
	var palms = ws.find_child("street-palms", true, false)
	check(palms != null and palms.multimesh.instance_count > 200, "palms along the town's streets")
	check_eq(palms.visibility_range_end, 0.0, "never culled by a range measured to the island-wide batch")
	check(ws.env.adjustment_enabled and ws.env.adjustment_saturation > 1.0, "the colour grade")
	ws.free()
