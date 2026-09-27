class_name BigNat
extends RefCounted
## A small arbitrary-precision natural number (limbs of 24 bits, least
## significant first) for the exact decimal work PyMath needs: correctly rounded
## float formatting and parsing, which GDScript and Godot's String don't do.
## Only what PyMath uses; slow but exact.

const BITS := 24
const BASE := 1 << 24
const LMASK := (1 << 24) - 1

var limbs := PackedInt64Array()


static func of(v: int) -> BigNat:
	var b := BigNat.new()
	while v > 0:
		b.limbs.append(v & LMASK)
		v >>= BITS
	return b


func copy() -> BigNat:
	var b := BigNat.new()
	b.limbs = limbs.duplicate()
	return b


func _trim() -> void:
	while not limbs.is_empty() and limbs[limbs.size() - 1] == 0:
		limbs.resize(limbs.size() - 1)


func is_zero() -> bool:
	return limbs.is_empty()


func bit_length() -> int:
	if limbs.is_empty():
		return 0
	var top: int = limbs[limbs.size() - 1]
	var n := 0
	while top > 0:
		n += 1
		top >>= 1
	return (limbs.size() - 1) * BITS + n


## Only when bit_length() <= 62.
func to_int() -> int:
	var v := 0
	for i in range(limbs.size() - 1, -1, -1):
		v = (v << BITS) | limbs[i]
	return v


func mul_small(k: int) -> BigNat:  # k < 2^30
	var carry := 0
	for i in limbs.size():
		var v: int = limbs[i] * k + carry
		limbs[i] = v & LMASK
		carry = v >> BITS
	while carry > 0:
		limbs.append(carry & LMASK)
		carry >>= BITS
	return self


func add_small(k: int) -> BigNat:  # k < 2^24
	var carry := k
	var i := 0
	while carry > 0:
		if i == limbs.size():
			limbs.append(0)
		var v: int = limbs[i] + carry
		limbs[i] = v & LMASK
		carry = v >> BITS
		i += 1
	return self


func mul_pow10(k: int) -> BigNat:
	while k >= 6:
		mul_small(1000000)
		k -= 6
	if k > 0:
		mul_small(int(pow(10, k)))
	return self


func shl(s: int) -> BigNat:
	if limbs.is_empty() or s <= 0:
		return self
	var whole := s / BITS
	var part := s % BITS
	if part > 0:
		var carry := 0
		for i in limbs.size():
			var v: int = (limbs[i] << part) | carry
			limbs[i] = v & LMASK
			carry = v >> BITS
		if carry > 0:
			limbs.append(carry)
	if whole > 0:
		var z := PackedInt64Array()
		z.resize(whole)
		z.fill(0)
		z.append_array(limbs)
		limbs = z
	return self


static func cmp(a: BigNat, b: BigNat) -> int:
	if a.limbs.size() != b.limbs.size():
		return 1 if a.limbs.size() > b.limbs.size() else -1
	for i in range(a.limbs.size() - 1, -1, -1):
		if a.limbs[i] != b.limbs[i]:
			return 1 if a.limbs[i] > b.limbs[i] else -1
	return 0


## self -= b (requires self >= b)
func sub(b: BigNat) -> BigNat:
	var borrow := 0
	for i in limbs.size():
		var v: int = limbs[i] - (b.limbs[i] if i < b.limbs.size() else 0) - borrow
		borrow = 1 if v < 0 else 0
		limbs[i] = v + (BASE if v < 0 else 0)
	_trim()
	return self


## [quotient, remainder] of a / b (b > 0): shift-and-subtract long division.
static func divmod(a: BigNat, b: BigNat) -> Array:
	var q := BigNat.new()
	var r := a.copy()
	if cmp(a, b) < 0:
		return [q, r]
	var shift := a.bit_length() - b.bit_length()
	var d := b.copy().shl(shift)
	var qbits := PackedInt64Array()
	qbits.resize(shift / BITS + 1)
	qbits.fill(0)
	for s in range(shift, -1, -1):
		if cmp(r, d) >= 0:
			r.sub(d)
			qbits[s / BITS] |= 1 << (s % BITS)
		d._shr1()
	q.limbs = qbits
	q._trim()
	return [q, r]


func _shr1() -> void:
	for i in limbs.size():
		var v: int = limbs[i] >> 1
		if i + 1 < limbs.size():
			v |= (limbs[i + 1] & 1) << (BITS - 1)
		limbs[i] = v
	_trim()


## self >>= s; true when any 1 bit was shifted out.
func shr_sticky(s: int) -> bool:
	if s <= 0 or limbs.is_empty():
		return false
	var whole := s / BITS
	var part := s % BITS
	var sticky := false
	for i in mini(whole, limbs.size()):
		sticky = sticky or limbs[i] != 0
	if whole >= limbs.size():
		limbs = PackedInt64Array()
		return sticky
	limbs = limbs.slice(whole)
	if part > 0:
		sticky = sticky or (limbs[0] & ((1 << part) - 1)) != 0
		for i in limbs.size():
			var v: int = limbs[i] >> part
			if i + 1 < limbs.size():
				v |= (limbs[i + 1] << (BITS - part)) & LMASK
			limbs[i] = v
		_trim()
	return sticky


## self = floor(self / 10^k); true when the division wasn't exact.
func div_pow10_sticky(k: int) -> bool:
	var sticky := false
	while k >= 6:
		sticky = div_small(1000000) != 0 or sticky
		k -= 6
	if k > 0:
		sticky = div_small(int(pow(10, k))) != 0 or sticky
	return sticky


## Remainder after dividing by a small k in place (self becomes the quotient).
func div_small(k: int) -> int:
	var rem := 0
	for i in range(limbs.size() - 1, -1, -1):
		var v: int = (rem << BITS) | limbs[i]
		limbs[i] = v / k
		rem = v % k
	_trim()
	return rem


func to_decimal() -> String:
	if limbs.is_empty():
		return "0"
	var t := copy()
	var parts := PackedStringArray()
	while not t.is_zero():
		parts.append("%06d" % t.div_small(1000000))
	parts.reverse()
	var s := "".join(parts).lstrip("0")
	return s if s != "" else "0"
