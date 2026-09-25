class_name MapLayout
extends RefCounted
## Everything geographic that the rules read: the airfields, the three HQ
## zones (where the runs and the cartel's turf are), the aerostat mooring and
## the headquarters sites. `classic()` is the hand-built island the Python game
## and the balance numbers use; `MapGen.generate(seed)` grows new ones.
## World.use_layout() makes one current (one island per process).

var id := "classic"
var map_seed := 0  ## 0 = classic
var terrain_seed := 7
var params = null  ## Terrain.generate_custom params, null for the classic generator
var airfields: Array = []
var zone_centre := {}
var zone_fields := {}
var aerostat_pos := [1500.0, -14800.0]
## name -> {kind, name, x, y, heading, zone}: org (the organisation's villa),
## law (task-force HQ), rival (the cartel's compound). Sited on first use.
var hqs := {}
var extra_trees := []  ## unused hook for decorative planting


static func classic() -> MapLayout:
	var l := MapLayout.new()
	l.airfields = [
		Airfield.new("HAR", "Port Harbor Intl", -9000, -9500, 70, 1800, 45, 8.0, "asphalt", "hub",
			{"shop": true, "police": true, "radar_km": 22.0}),
		Airfield.new("VAL", "Valley Regional", 2500, -3000, 20, 1000, 30, null, "asphalt", "regional",
			{"shop": true, "police": true, "radar_km": 12.0}),
		Airfield.new("FRM", "Miller's Farm", -6500, -1500, 110, 480, 20, null, "grass", "bush"),
		Airfield.new("PNR", "Pine Ridge", 10000, 8500, 225, 380, 15, null, "gravel", "bush", {"tree_lines": true}),
		Airfield.new("EGL", "Eagle's Nest", 1000, 9000, 250, 280, 14, 1150.0, "dirt", "bush", {"setting": "plateau"}),
		Airfield.new("COV", "Smuggler's Cove", 11500, -8000, 10, 320, 18, 3.0, "sand", "shady", {"setting": "beach"}),
		Airfield.new("QRY", "Old Quarry", -10000, 5500, 160, 240, 12, null, "dirt", "shady",
			{"setting": "pit", "haul_road": 0}),
		Airfield.new("ISL", "Isla Verde", 12800, 11500, 300, 550, 20, 12.0, "grass", "regional"),
	]
	l.zone_centre = {"west": [-9000.0, 3000.0], "north": [2000.0, 8000.0], "sea": [13000.0, -11000.0]}
	l.zone_fields = {"west": ["QRY", "FRM"], "north": ["EGL", "PNR", "ISL"], "sea": ["COV"]}
	return l


func airfield(code: String) -> Airfield:
	for a in airfields:
		if a.code == code:
			return a
	return null


func describe() -> String:
	var lines := ["Map %s (%d strips)" % [id, airfields.size()]]
	for a in airfields:
		lines.append("  %s %-18s %5.0f m %-7s %-7s at (%6.0f, %6.0f) hdg %3.0f" % [a.code, a.name, a.length, a.surface,
			a.setting, a.x, a.y, a.heading])
	for k in hqs:
		lines.append("  HQ %-6s %s at (%6.0f, %6.0f)" % [k, hqs[k].name, hqs[k].x, hqs[k].y])
	return "\n".join(lines)
