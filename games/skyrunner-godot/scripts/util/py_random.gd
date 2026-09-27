class_name PyRandomG
extends RefCounted
## CPython's random.Random, bit for bit, in GDScript: MT19937 with CPython's
## seeding (init_by_array of abs(n) in 32-bit words), float generation,
## _randbelow rejection sampling, gauss pairing, shuffle and choices. The Python
## game drew every job board, police decision and simulated night from these
## streams; matching them lets the port be checked seed for seed.
##
## GDScript has only signed 64-bit ints: every 32-bit quantity is masked, and
## products that could pass 2^63 are split (_mul32).

const N := 624
const M := 397
const MASK32 := 0xFFFFFFFF
const MATRIX_A := 0x9908b0df
const UPPER := 0x80000000
const LOWER := 0x7fffffff

var _mt := PackedInt64Array()
var _mti := N + 1
var _has_gauss_next := false
var _gauss_next := 0.0


func _init() -> void:
	_mt.resize(N)
	seed(0)


static func _mul32(a: int, b: int) -> int:
	# (a * b) mod 2^32 for a, b < 2^32, without a 64-bit overflow
	return ((a & 0xFFFF) * b + ((((a >> 16) * b) & 0xFFFF) << 16)) & MASK32


func _init_genrand(s: int) -> void:
	_mt[0] = s & MASK32
	for i in range(1, N):
		var p: int = _mt[i - 1]
		_mt[i] = (_mul32(1812433253, p ^ (p >> 30)) + i) & MASK32
	_mti = N


func _init_by_array(key: Array) -> void:
	_init_genrand(19650218)
	var i := 1
	var j := 0
	var k: int = maxi(N, key.size())
	while k > 0:
		var p: int = _mt[i - 1]
		_mt[i] = ((_mt[i] ^ _mul32(p ^ (p >> 30), 1664525)) + int(key[j]) + j) & MASK32
		i += 1
		j += 1
		if i >= N:
			_mt[0] = _mt[N - 1]
			i = 1
		if j >= key.size():
			j = 0
		k -= 1
	k = N - 1
	while k > 0:
		var p: int = _mt[i - 1]
		_mt[i] = ((_mt[i] ^ _mul32(p ^ (p >> 30), 1566083941)) - i) & MASK32
		i += 1
		if i >= N:
			_mt[0] = _mt[N - 1]
			i = 1
		k -= 1
	_mt[0] = 0x80000000
	_mti = N


## Seed from a non-negative value held as an unsigned 64-bit pattern.
func _seed_u64(n: int) -> void:
	var key := []
	if n == 0:
		key.append(0)
	while n != 0:
		key.append(n & MASK32)
		n = (n >> 32) & MASK32  # logical shift: n may carry the sign bit
	_init_by_array(key)
	_has_gauss_next = false


## random.Random(int): CPython seeds with abs(n).
func seed(n: int) -> void:
	_seed_u64(-n if n < 0 else n)  # (abs(INT64_MIN) keeps its bit pattern, as the C++ did)


## random.Random(float): CPython seeds with hash(x).
func seed_float(x: float) -> void:
	_seed_u64(_py_hash_double(x))


func genrand() -> int:
	var y: int
	if _mti >= N:
		for kk in N - M:
			y = (_mt[kk] & UPPER) | (_mt[kk + 1] & LOWER)
			_mt[kk] = _mt[kk + M] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
		for kk in range(N - M, N - 1):
			y = (_mt[kk] & UPPER) | (_mt[kk + 1] & LOWER)
			_mt[kk] = _mt[kk + (M - N)] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
		y = (_mt[N - 1] & UPPER) | (_mt[0] & LOWER)
		_mt[N - 1] = _mt[M - 1] ^ (y >> 1) ^ (MATRIX_A if y & 1 else 0)
		_mti = 0
	y = _mt[_mti]
	_mti += 1
	y ^= y >> 11
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= y >> 18
	return y & MASK32


func random() -> float:
	var a := genrand() >> 5
	var b := genrand() >> 6
	return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0)


func uniform(a: float, b: float) -> float:
	return a + (b - a) * random()


func getrandbits(k: int) -> int:
	if k <= 0:
		return 0
	if k <= 32:
		return genrand() >> (32 - k)
	# little-endian 32-bit words, the last one truncated (k <= 63 here)
	var out := 0
	var shift := 0
	while k > 0:
		var r := genrand()
		if k < 32:
			r >>= 32 - k
		out |= r << shift
		shift += 32
		k -= 32
	return out


static func _bit_length(v: int) -> int:
	var n := 0
	while v != 0:
		n += 1
		v >>= 1
	return n


func randbelow(n: int) -> int:
	if n <= 0:
		return 0
	var k := _bit_length(n)
	var r := getrandbits(k)
	while r >= n:
		r = getrandbits(k)
	return r


func randint(a: int, b: int) -> int:
	return a + randbelow(b - a + 1)


func gauss(mu: float, sigma: float) -> float:
	var z: float
	if _has_gauss_next:
		z = _gauss_next
		_has_gauss_next = false
	else:
		var x2pi := random() * 2.0 * PI
		var g2rad := sqrt(-2.0 * log(1.0 - random()))
		z = cos(x2pi) * g2rad
		_gauss_next = sin(x2pi) * g2rad
		_has_gauss_next = true
	return mu + z * sigma


## Shuffles in place and returns the same array.
func shuffle(items: Array) -> Array:
	var i := items.size() - 1
	while i > 0:
		var j := randbelow(i + 1)
		var t = items[i]
		items[i] = items[j]
		items[j] = t
		i -= 1
	return items


func choice(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[randbelow(items.size())]


## random.choices(range(n), weights, k)
func choices_index(weights: PackedFloat64Array, k: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := weights.size()
	if n == 0:
		return out
	var cum := PackedFloat64Array()
	cum.resize(n)
	var acc := 0.0
	for i in n:
		acc += weights[i]
		cum[i] = acc
	var total := cum[n - 1]
	for t in k:
		var x := random() * total
		var lo := 0
		var hi := n - 1
		while lo < hi:  # bisect.bisect(cum_weights, x, 0, n - 1)
			var mid := (lo + hi) / 2
			if x < cum[mid]:
				hi = mid
			else:
				lo = mid + 1
		out.append(lo)
	return out


## random.choices(seq, k) without weights
func choices_uniform_index(n: int, k: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for t in k:
		out.append(int(floor(random() * n)))
	return out


func get_state() -> Array:
	var s := []
	for v in _mt:
		s.append(v)
	s.append(_mti)
	s.append(_has_gauss_next)
	s.append(_gauss_next)
	return s


func set_state(s: Array) -> void:
	if s.size() != N + 3:
		return
	for i in N:
		_mt[i] = int(s[i]) & MASK32
	_mti = int(s[N])
	_has_gauss_next = bool(s[N + 1])
	_gauss_next = float(s[N + 2])


## CPython's _Py_HashDouble (Python/pyhash.c), 64-bit build.
static func _py_hash_double(v: float) -> int:
	const BITS := 61
	const MOD := (1 << 61) - 1
	if not is_finite(v):
		return (314159 if v > 0 else -314159) if is_inf(v) else 0
	if v == 0.0:
		return 0
	# frexp: v = m * 2^e with 0.5 <= |m| < 1 (dividing by a power of two is exact)
	var e := int(floor(log(absf(v)) / log(2.0))) + 1
	var m := v / pow(2.0, e)
	while absf(m) >= 1.0:
		m /= 2.0
		e += 1
	while absf(m) < 0.5:
		m *= 2.0
		e -= 1
	var sign := 1
	if m < 0:
		sign = -1
		m = -m
	var x := 0
	while m != 0.0:
		x = ((x << 28) & MOD) | (x >> (BITS - 28))
		m *= 268435456.0
		e -= 28
		var y := int(m)
		m -= float(y)
		x += y
		if x >= MOD:
			x -= MOD
	e = e % BITS if e >= 0 else BITS - 1 - ((-1 - e) % BITS)
	x = ((x << e) & MOD) | (x >> (BITS - e))
	var h := x * sign
	return -2 if h == -1 else h
