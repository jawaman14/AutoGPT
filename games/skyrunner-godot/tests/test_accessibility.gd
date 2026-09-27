extends TestCase
## Colour accessibility: under simulated protanopia, deuteranopia and
## tritanopia (GATO's matrices, the ones the F9 filter uses) the colour-safe
## palette keeps every pair of status colours apart (CIE76 delta-E >= 20), the
## factions stay apart in both palettes, and the screen filters load.

const CVD := {
	"normal": [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
	"protanopia": [Vector3(.56667, .43333, 0), Vector3(.55833, .44167, 0), Vector3(0, .24167, .75833)],
	"deuteranopia": [Vector3(.625, .375, 0), Vector3(.70, .30, 0), Vector3(0, .30, .70)],
	"tritanopia": [Vector3(.95, .05, 0), Vector3(0, .43333, .56667), Vector3(0, .475, .525)],
}
const MIN_DE := 20.0
const STATUS := ["PINK", "AMBER", "RED", "GREEN", "CYAN"]


func after_each() -> void:
	UIStyle.set_palette("neon")


static func _lab(c: Color) -> Vector3:
	var lin := func(u: float) -> float: return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)
	var r: float = lin.call(clampf(c.r, 0, 1))
	var g: float = lin.call(clampf(c.g, 0, 1))
	var b: float = lin.call(clampf(c.b, 0, 1))
	var x := (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
	var y := 0.2126 * r + 0.7152 * g + 0.0722 * b
	var z := (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
	var f := func(t: float) -> float: return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0
	return Vector3(116.0 * f.call(y) - 16.0, 500.0 * (f.call(x) - f.call(y)), 200.0 * (f.call(y) - f.call(z)))


static func _sim(m: Array, c: Color) -> Color:
	var v := Vector3(c.r, c.g, c.b)
	return Color(m[0].dot(v), m[1].dot(v), m[2].dot(v))


## The worst pair: [delta-E, "a/b under vision"].
static func _worst(cols: Dictionary) -> Array:
	var worst := [INF, ""]
	var keys := cols.keys()
	for vision in CVD:
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				var d := _lab(_sim(CVD[vision], cols[keys[i]])).distance_to(_lab(_sim(CVD[vision], cols[keys[j]])))
				if d < worst[0]:
					worst = [d, "%s/%s under %s" % [keys[i], keys[j], vision]]
	return worst


func test_the_safe_palette_survives_colour_blindness() -> void:
	var neon: Array = _worst(UIStyle.PALETTES.neon)
	check(neon[0] < MIN_DE, "the neon look fails somewhere (%.0f, %s) - why the safe palette exists" % neon)
	var safe: Array = _worst(UIStyle.PALETTES.safe)
	check(safe[0] >= MIN_DE, "colour-safe: every pair apart (worst %.0f, %s)" % safe)


func test_the_factions_are_apart_either_way() -> void:
	check(_worst(StationMap.SQUAD_COL)[0] >= MIN_DE, "map squads: %.0f %s" % _worst(StationMap.SQUAD_COL))
	var suits := {}
	for f in ["org", "rival", "police"]:
		suits[f] = SquadRender.SUIT[f]
	check(_worst(suits)[0] >= MIN_DE, "suits: %.0f %s" % _worst(suits))


func test_set_palette() -> void:
	UIStyle.set_palette("safe")
	check_eq(UIStyle.GREEN, UIStyle.PALETTES.safe.GREEN, "good is sky blue")
	check_eq(UIStyle.ACCENT, UIStyle.PALETTES.safe.PINK, "the accent follows")
	UIStyle.set_palette("nonsense")
	check_eq(UIStyle.palette, "neon", "unknown: neon")
	check_eq(UIStyle.RED, UIStyle.PALETTES.neon.RED, "restored")


func test_screen_filters() -> void:
	var f := ScreenFilter.new()
	Engine.get_main_loop().root.add_child(f)
	var seen := []
	for i in ScreenFilter.MODES.size():
		seen.append(f.cycle())
		if f.mode != "off":
			check(f.rect.material is ShaderMaterial and f.rect.material.shader != null, "%s has its shader" % f.mode)
	check_eq(seen.back(), "off", "cycles back to off")
	f.set_mode("deuteranopia")
	check_eq(f.rect.material.get_shader_parameter("type"), 3, "GATO's deuteranopia")
	f.set_mode("bogus")
	check(not f.rect.visible, "unknown: off")
	f.queue_free()
