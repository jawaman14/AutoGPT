extends TestCase
## Reference values printed by CPython 3.11 `random` and numpy's default_rng.
## If these hold, every seeded job board, police roll and simulated night
## in the port can be replayed against the Python game.

# GDScript parses 17-digit float literals with up to ~1 ulp error, so compare
# to a few ulps rather than exactly.
const REL := 4e-16


func _py(seed: int) -> PyRandom:
	var r := PyRandom.new()
	r.seed(seed)
	return r


func _near_all(got: Array, want: Array, what: String) -> void:
	check_eq(got.size(), want.size(), what + " length")
	for i in range(mini(got.size(), want.size())):
		check_near(got[i], want[i], absf(want[i]) * REL + 1e-300, "%s[%d]" % [what, i])


func test_python_random_floats() -> void:
	var r := _py(7)
	_near_all([r.random(), r.random(), r.random(), r.random(), r.random()],
		[0.32383276483316237, 0.15084917392450192, 0.6509344730398537, 0.07243628666754276, 0.5358820043066892], "seed 7")
	r = _py(123456789012)
	_near_all([r.random(), r.random(), r.random()], [0.37701448538609916, 0.02069602357922562, 0.14040538980009454], "64-bit seed")
	r = _py(0)
	_near_all([r.random(), r.random()], [0.8444218515250481, 0.7579544029403025], "seed 0")
	r = _py(-5)
	_near_all([r.random(), r.random()], [0.6229016948897019, 0.7417869892607294], "negative seed uses abs")


func test_python_integer_and_sequence_methods() -> void:
	var r := _py(42)
	var got := []
	for i in 10:
		got.append(r.randint(1, 6))
	for i in 3:
		got.append(r.randint(0, 1000000))
	check_eq(got, [6, 1, 1, 6, 3, 2, 2, 2, 6, 1, 709570, 776646, 935518], "randint")
	r = _py(42)
	_near_all([r.uniform(-1200, 1200), r.uniform(-1200, 1200), r.uniform(-1200, 1200)],
		[334.62431629892103, -1139.9741874655992, -539.9296359141138], "uniform")
	r = _py(9)
	_near_all([r.gauss(0, 1), r.gauss(0, 1), r.gauss(0, 1)], [-0.9407568840284877, 0.22268633975498442, 1.2934773612320982], "gauss")
	r = _py(9)
	var picks := []
	for i in 8:
		picks.append(r.choice(["a", "b", "c", "d", "e"]))
	check_eq(picks, ["d", "e", "c", "c", "b", "b", "a", "c"], "choice")
	r = _py(3)
	check_eq(r.shuffle([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), [1, 5, 6, 0, 9, 4, 7, 2, 8, 3], "shuffle")
	r = _py(3)
	check_eq(Array(r.choices_index(PackedFloat64Array([1, 2, 3, 4]), 8)), [1, 2, 2, 3, 3, 0, 0, 3], "weighted choices")
	r = _py(3)
	check_eq(Array(r.choices_uniform_index(5, 6)), [1, 2, 1, 3, 3, 0], "unweighted choices")
	r = _py(11)
	check_eq([r.getrandbits(40), r.getrandbits(40), r.getrandbits(40)], [951130727789, 943002041895, 858667946125], "getrandbits(40)")


func test_python_float_seed_goes_through_hash() -> void:
	# police.py seeds sub-generators with random.Random(self.rng.random())
	var r := PyRandom.new()
	r.seed_float(0.32383276483316237)
	_near_all([r.random(), r.random()], [0.48435692281856413, 0.7306917957403222], "float seed")


func test_numpy_pcg64() -> void:
	var g := NpRandom.new()
	g.seed(7)
	_near_all(Array(g.random_array(5)), [0.625095466604667, 0.8972138009695755, 0.7756856902451935, 0.22520718999059186, 0.30016628491122543], "default_rng(7)")
	g.seed(8)
	_near_all(Array(g.uniform_array(4, -16000, 16000)), [-5536.887148622058, 15592.858986813619, -5801.253168463465, 9233.565946240928], "uniform")
	g.seed((1 << 40) + 3)
	_near_all([g.random(), g.random()], [0.7736560850714245, 0.9958573802012665], "multi-word seed")
