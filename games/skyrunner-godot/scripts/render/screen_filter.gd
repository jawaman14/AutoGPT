class_name ScreenFilter
extends CanvasLayer
## A full-screen filter over the 3D view and the HUD (F9 cycles it):
##   vhs         an 80s tape look: gentle barrel, colour bleed, rolling scanlines
##               (Henrique Lacreta Alves' SimpleGodotCRTShader, MIT, addons/crt_shader)
##   protanopia, deuteranopia, tritanopia, achromatopsia
##               *simulations* of colour vision deficiencies (GATO's colour
##               blindness shader, MPL-2.0, addons/gato_screen_filters), to check
##               that nothing depends on a colour alone. They don't help a
##               colour-blind player - the colour-safe palette does (F8).

const MODES := ["off", "vhs", "protanopia", "deuteranopia", "tritanopia", "achromatopsia"]
const LABELS := {"off": "no filter", "vhs": "VHS tape", "protanopia": "protanopia (simulated)",
	"deuteranopia": "deuteranopia (simulated)", "tritanopia": "tritanopia (simulated)", "achromatopsia": "achromatopsia (simulated)"}
## GATO's shader: its `type` uniform
const CVD_TYPE := {"protanopia": 1, "deuteranopia": 3, "tritanopia": 5, "achromatopsia": 7}
const CRT := "res://addons/crt_shader/CRTShader.gdshader"
const CVD := "res://addons/gato_screen_filters/color_blindness.gdshader"

var mode := "off"
var rect: ColorRect
var _mats := {}


func _init() -> void:
	layer = 90  # over the HUD and menus
	rect = ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	add_child(rect)


func material_for(m: String) -> ShaderMaterial:
	if m == "off":
		return null
	var key := "vhs" if m == "vhs" else "cvd"
	if not _mats.has(key):
		var mat := ShaderMaterial.new()
		mat.shader = load(CRT if key == "vhs" else CVD)
		if key == "vhs":
			# the demo's CRT is a strong look; a worn tape is subtler
			mat.set_shader_parameter("BarrelPower", 1.03)
			mat.set_shader_parameter("color_bleeding", 1.08)
			mat.set_shader_parameter("bleeding_range_x", 1.5)
			mat.set_shader_parameter("bleeding_range_y", 0.5)
			mat.set_shader_parameter("lines_distance", 3.0)
			mat.set_shader_parameter("scan_size", 1.0)
			mat.set_shader_parameter("scanline_alpha", 0.88)
			mat.set_shader_parameter("lines_velocity", 8.0)
		_mats[key] = mat
	var mat: ShaderMaterial = _mats[key]
	if key == "cvd":
		mat.set_shader_parameter("type", CVD_TYPE[m])
	return mat


func set_mode(m: String) -> void:
	mode = m if m in MODES else "off"
	rect.material = material_for(mode)
	rect.visible = mode != "off"
	_resize()


func cycle() -> String:
	set_mode(MODES[(MODES.find(mode) + 1) % MODES.size()])
	return mode


func _process(_dt: float) -> void:
	if mode == "vhs":
		_resize()


func _resize() -> void:
	if mode == "vhs" and is_inside_tree():
		var sz := get_viewport().get_visible_rect().size
		rect.material.set_shader_parameter("screen_width", sz.x)
		rect.material.set_shader_parameter("screen_height", sz.y)
