class_name Quality
extends RefCounted
## Graphics quality presets (port of render/quality.py, extended for Godot).
##
##   low     vertex colours, half-resolution terrain mesh, a third of the trees,
##           no shadows, no post effects. For bots you want to watch, old
##           laptops, and software rendering (llvmpipe under Xvfb).
##   medium  shaded terrain (height/slope splat + noise detail), animated water,
##           procedural sky with day/night, glow and fog.
##   high    medium + sun shadows, SSAO, volumetric fog, 4x MSAA, two-tier trees,
##           runway/nav lights as real lights at night.
##
## Headless simulation (balance CLI, tests, dedicated servers) never builds any
## of this.

var name: String
var shaded: bool  ## terrain/water shaders instead of plain vertex colours
var terrain_step: int  ## 1 = full 513^2 mesh, 2 = 257^2
var tree_keep: int  ## keep 1 in N trees
var tree_segments: int
var shadows: bool
var ssao: bool
var volumetric_fog: bool
var glow: bool
var msaa: int
var sky: bool
var water_anim: bool
var fog_far: float
var real_lights: bool  ## OmniLights for runway edges / landing lights at night


static func make(n: String, d: Dictionary) -> Quality:
	var q := Quality.new()
	q.name = n
	for k in d:
		q.set(k, d[k])
	return q


static var PRESETS := {
	"low": make("low", {"shaded": false, "terrain_step": 2, "tree_keep": 3, "tree_segments": 4, "shadows": false,
		"ssao": false, "volumetric_fog": false, "glow": false, "msaa": 0, "sky": false, "water_anim": false,
		"fog_far": 22000.0, "real_lights": false}),
	"medium": make("medium", {"shaded": true, "terrain_step": 1, "tree_keep": 1, "tree_segments": 5, "shadows": false,
		"ssao": false, "volumetric_fog": false, "glow": true, "msaa": 0, "sky": true, "water_anim": true,
		"fog_far": 30000.0, "real_lights": false}),
	"high": make("high", {"shaded": true, "terrain_step": 1, "tree_keep": 1, "tree_segments": 7, "shadows": true,
		"ssao": true, "volumetric_fog": true, "glow": true, "msaa": 4, "sky": true, "water_anim": true,
		"fog_far": 34000.0, "real_lights": true}),
}


static func get_preset(n) -> Quality:
	return PRESETS.get(n if n else "high", PRESETS["high"])
