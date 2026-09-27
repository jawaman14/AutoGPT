class_name NpRandomG
extends RefCounted
## numpy.random.default_rng(seed), bit for bit, in GDScript: SeedSequence ->
## PCG64 (XSL-RR), with numpy's random()/uniform() double conversion. Used for
## the terrain and tree scatter, so seed 7 grows the island the balance numbers
## were measured on.
##
## The 128-bit state is eight 16-bit limbs (little-endian), so every partial
## product fits in GDScript's signed 64-bit int.

const MASK32 := 0xFFFFFFFF
const INIT_A := 0x43b0d7e5
const MULT_A := 0x931e8875
const INIT_B := 0x8b51f9dd
const MULT_B := 0x58f38ded
const MIX_MULT_L := 0xca01f9dd
const MIX_MULT_R := 0x4973f715
const XSHIFT := 16
const POOL := 4
## PCG64's multiplier 0x2360ED051FC65DA4_4385DF649FCCF645, low limb first
const MULT := [0xF645, 0x9FCC, 0xDF64, 0x4385, 0x5DA4, 0x1FC6, 0xED05, 0x2360]

var _state := [0, 0, 0, 0, 0, 0, 0, 0]
var _inc := [0, 0, 0, 0, 0, 0, 0, 0]


static func _mul32(a: int, b: int) -> int:
	return ((a & 0xFFFF) * b + ((((a >> 16) * b) & 0xFFFF) << 16)) & MASK32


static func _hashmix(value: int, hc: Array) -> int:
	value ^= hc[0]
	hc[0] = _mul32(hc[0], MULT_A)
	value = _mul32(value, hc[0])
	value ^= value >> XSHIFT
	return value


static func _mix(x: int, y: int) -> int:
	var r := (_mul32(MIX_MULT_L, x) - _mul32(MIX_MULT_R, y)) & MASK32
	r ^= r >> XSHIFT
	return r


## state = state * MULT + inc  (mod 2^128)
func _step() -> void:
	var out := [0, 0, 0, 0, 0, 0, 0, 0]
	for i in 8:
		var si: int = _state[i]
		if si == 0:
			continue
		for j in 8 - i:
			out[i + j] += si * int(MULT[j])  # < 2^32 each; at most 8 terms a limb
	var carry := 0
	for k in 8:
		var v: int = out[k] + int(_inc[k]) + carry
		_state[k] = v & 0xFFFF
		carry = v >> 16
	# (bits past limb 7 are the mod 2^128)


static func _limbs_from_u64(hi: int, lo: int) -> Array:
	var l := []
	for w in [lo, hi]:
		for s in [0, 16, 32, 48]:
			l.append((w >> s) & 0xFFFF)
	return l


func seed(n: int) -> void:
	# SeedSequence(n).generate_state(4, uint64)
	var entropy := []
	var u := -n if n < 0 else n
	if u == 0:
		entropy.append(0)
	while u != 0:
		entropy.append(u & MASK32)
		u = (u >> 32) & MASK32
	var pool := [0, 0, 0, 0]
	var hc := [INIT_A]
	for i in POOL:
		pool[i] = _hashmix(entropy[i] if i < entropy.size() else 0, hc)
	for s in POOL:
		for d in POOL:
			if s != d:
				pool[d] = _mix(pool[d], _hashmix(pool[s], hc))
	for s in range(POOL, entropy.size()):
		for d in POOL:
			pool[d] = _mix(pool[d], _hashmix(entropy[s], hc))
	var words := []
	var hb := INIT_B
	for i in 8:
		var v: int = pool[i % POOL]
		v ^= hb
		hb = _mul32(hb, MULT_B)
		v = _mul32(v, hb)
		v ^= v >> XSHIFT
		words.append(v)
	var val := []
	for i in 4:
		val.append(int(words[2 * i]) | (int(words[2 * i + 1]) << 32))
	var initstate := _limbs_from_u64(val[0], val[1])
	var initseq := _limbs_from_u64(val[2], val[3])
	# inc = (initseq << 1) | 1
	var carry := 1
	for k in 8:
		var v: int = (int(initseq[k]) << 1) + carry
		_inc[k] = v & 0xFFFF
		carry = v >> 16
	_inc[0] |= 1
	_state = [0, 0, 0, 0, 0, 0, 0, 0]
	_step()
	carry = 0
	for k in 8:
		var v: int = int(_state[k]) + int(initstate[k]) + carry
		_state[k] = v & 0xFFFF
		carry = v >> 16
	_step()


## The next raw 64 bits (as a signed int holding the unsigned bit pattern).
func next_u64() -> int:
	_step()
	var lo: int = _state[0] | (_state[1] << 16) | (_state[2] << 32) | (_state[3] << 48)
	var hi: int = _state[4] | (_state[5] << 16) | (_state[6] << 32) | (_state[7] << 48)
	var rot: int = int(_state[7]) >> 10  # state >> 122
	var x := hi ^ lo
	if rot == 0:
		return x
	return ((x >> rot) & ((1 << (64 - rot)) - 1)) | (x << (64 - rot))


func random() -> float:
	return float((next_u64() >> 11) & ((1 << 53) - 1)) * (1.0 / 9007199254740992.0)


func uniform(lo: float, hi: float) -> float:
	return lo + (hi - lo) * random()


func random_array(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		out[i] = random()
	return out


func uniform_array(n: int, lo: float, hi: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		out[i] = uniform(lo, hi)
	return out
