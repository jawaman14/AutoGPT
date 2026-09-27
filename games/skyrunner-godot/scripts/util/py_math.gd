class_name PyMathG
extends RefCounted
## Python's float maths and formatting, bit for bit, in GDScript:
##   hypot/hypot3   CPython 3.11's vector_norm (exact products by Veltkamp
##                  splitting, where C used fma)
##   round_n        Python round(x, n): correctly rounded decimal, half-even
##   round_int      round(x) (half-even)
##   fmt            "%.nf" as C's printf writes it
##   repr           the shortest %g spelling that parses back to the same double
##   parse          correctly rounded decimal -> double (strtod)
## Godot's String::num and to_float aren't correctly rounded, so the exact paths
## go through BigNat; the fast paths skip it whenever a double decides the same.

const TWO52 := 4503599627370496.0
const SPLIT := 134217729.0  # 2^27 + 1


# ------------------------------------------------------------------ hypot
static func _two_prod(a: float, b: float) -> Array:
	var p := a * b
	var t := SPLIT * a
	var ah := t - (t - a)
	var al := a - ah
	t = SPLIT * b
	var bh := t - (t - b)
	var bl := b - bh
	return [p, ((ah * bh - p) + ah * bl + al * bh) + al * bl]


## [m, e] with x = m * 2^e and 0.5 <= |m| < 1 (frexp); x finite and non-zero.
static func frexp(x: float) -> Array:
	var e := int(floor(log(absf(x)) / log(2.0))) + 1
	var m := x / pow(2.0, e)
	while absf(m) >= 1.0:
		m *= 0.5
		e += 1
	while absf(m) < 0.5:
		m *= 2.0
		e -= 1
	return [m, e]


static func _vector_norm(vec: Array, mx: float, found_nan: bool) -> float:
	if is_inf(mx):
		return mx
	if found_nan:
		return NAN
	if mx == 0.0 or vec.size() <= 1:
		return mx
	var max_e: int = frexp(mx)[1]
	var scale := pow(2.0, -max_e)
	var csum := 1.0
	var frac1 := 0.0
	var frac2 := 0.0
	for v in vec:
		var x: float = v * scale
		var pr := _two_prod(x, x)
		var hi: float = csum + pr[0]
		frac2 += (csum - hi) + pr[0]
		csum = hi
		frac1 += pr[1]
	var h := sqrt(csum - 1.0 + (frac1 + frac2))
	var pr2 := _two_prod(-h, h)
	var hi2: float = csum + pr2[0]
	frac2 += (csum - hi2) + pr2[0]
	csum = hi2
	frac1 += pr2[1]
	var x2 := csum - 1.0 + (frac1 + frac2)
	h += x2 / (2.0 * h)
	return h / scale


static func hypot(x: float, y: float) -> float:
	x = absf(x)
	y = absf(y)
	return _vector_norm([x, y], maxf(x, y), is_nan(x) or is_nan(y))


static func hypot3(x: float, y: float, z: float) -> float:
	x = absf(x)
	y = absf(y)
	z = absf(z)
	return _vector_norm([x, y, z], maxf(x, maxf(y, z)), is_nan(x) or is_nan(y) or is_nan(z))


## fdlibm's s_log1p.c (what glibc's log1p is), line for line: GDScript has no
## log1p, and the season model's hazards must round exactly as the Python did.
static func log1p(x: float) -> float:
	const LN2_HI := 6.93147180369123816490e-01
	const LN2_LO := 1.90821492927058770002e-10
	const TWO54 := 1.80143985094819840000e+16
	const LP1 := 6.666666666666735130e-01
	const LP2 := 3.999999999940941908e-01
	const LP3 := 2.857142874366239149e-01
	const LP4 := 2.222219843214978396e-01
	const LP5 := 1.818357216161805012e-01
	const LP6 := 1.531383769920937332e-01
	const LP7 := 1.479819860511658591e-01
	var hx := _hi(x)
	var ax := hx & 0x7fffffff
	var k := 1
	var f := 0.0
	var c := 0.0
	var hu := 0
	if hx < 0x3FDA827A:  # x < 0.41422
		if ax >= 0x3ff00000:  # x <= -1
			return -INF if x == -1.0 else NAN
		if ax < 0x3e200000:  # |x| < 2^-29
			if TWO54 + x > 0.0 and ax < 0x3c900000:
				return x
			return x - x * x * 0.5
		if hx > 0 or hx <= _s32(0xbfd2bec3):  # -0.2929 < x < 0.41422
			k = 0
			f = x
			hu = 1
	if hx >= 0x7ff00000:
		return x + x
	if k != 0:
		var u: float
		if hx < 0x43400000:
			u = 1.0 + x
			hu = _hi(u)
			k = (hu >> 20) - 1023
			c = (1.0 - (u - x)) if k > 0 else (x - (u - 1.0))  # correction term
			c /= u
		else:
			u = x
			hu = _hi(u)
			k = (hu >> 20) - 1023
			c = 0.0
		hu &= 0x000fffff
		if hu < 0x6a09e:
			u = _with_hi(u, hu | 0x3ff00000)  # normalise u
		else:
			k += 1
			u = _with_hi(u, hu | 0x3fe00000)  # normalise u/2
			hu = (0x00100000 - hu) >> 2
		f = u - 1.0
	var hfsq := 0.5 * f * f
	if hu == 0:  # |f| < 2^-20
		if f == 0.0:
			if k == 0:
				return 0.0
			c += k * LN2_LO
			return k * LN2_HI + c
		var r0 := hfsq * (1.0 - 0.66666666666666666 * f)
		if k == 0:
			return f - r0
		return k * LN2_HI - ((r0 - (k * LN2_LO + c)) - f)
	var s := f / (2.0 + f)
	var z := s * s
	var r := z * (LP1 + z * (LP2 + z * (LP3 + z * (LP4 + z * (LP5 + z * (LP6 + z * LP7))))))
	if k == 0:
		return f - (hfsq - s * (hfsq + r))
	return k * LN2_HI - ((hfsq - (s * (hfsq + r) + (k * LN2_LO + c))) - f)


static var _buf := PackedByteArray()


## The signed high 32-bit word of a double (GET_HIGH_WORD).
static func _hi(x: float) -> int:
	if _buf.is_empty():
		_buf.resize(8)
	_buf.encode_double(0, x)
	return _s32(_buf.decode_u32(4))


## x with its high word replaced (SET_HIGH_WORD).
static func _with_hi(x: float, hi: int) -> float:
	if _buf.is_empty():
		_buf.resize(8)
	_buf.encode_double(0, x)
	_buf.encode_u32(4, hi & 0xFFFFFFFF)
	return _buf.decode_double(0)


static func _s32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v


# ------------------------------------------------------------------ exact decimals
## [mantissa, exponent] with |x| = mantissa * 2^exponent exactly (x finite, non-zero).
static func _decompose(x: float) -> Array:
	var fe := frexp(absf(x))
	return [int(fe[0] * 9007199254740992.0), int(fe[1]) - 53]


## round-half-even(n / (2^a * 10^b)); n is consumed. Every denominator here is
## 2^a * 10^b, so shifts and small divisions do the work: floor(2n / d) carries
## the half bit, and whether anything was left over tells a tie from above.
static func _round_2_10(n: BigNat, a: int, b: int) -> BigNat:
	n.shl(1)
	var sticky := n.div_pow10_sticky(b)
	sticky = n.shr_sticky(a) or sticky
	var half := not n.is_zero() and (n.limbs[0] & 1) == 1
	n.shr_sticky(1)
	if half and (sticky or (not n.is_zero() and (n.limbs[0] & 1) == 1)):
		n.add_small(1)
	return n


## round-half-even(|x| * 10^k), exactly.
static func _scaled_round_exact(x: float, k: int) -> BigNat:
	var md := _decompose(x)
	var n := BigNat.of(md[0])
	var a := 0
	if md[1] >= 0:
		n.shl(md[1])
	else:
		a = -md[1]
	if k >= 0:
		n.mul_pow10(k)
		return _round_2_10(n, a, 0)
	return _round_2_10(n, a, -k)


## round-half-even(|x| * 10^n) for 0 <= n <= 22: by doubles when they decide, else exact.
static func _scaled_round(x: float, n: int) -> BigNat:
	var y := absf(x) * pow(10.0, n)
	if y < TWO52:
		var fl := floorf(y)
		var f := y - fl
		if absf(f - 0.5) > y * 3e-16 + 1e-300:
			return BigNat.of(int(fl) + (1 if f > 0.5 else 0))
	return _scaled_round_exact(x, n)


## The double nearest n / 10^b (n > 0), ties to even: strtod's answer.
static func _to_double(n: BigNat, b: int) -> float:
	if n.is_zero():
		return 0.0
	# scale by 2^s so the quotient has 55-57 bits: 10^b has about b*log2(10) bits
	var s := 56 - (n.bit_length() - int(ceil(b * 3.321928094887362)))
	var nn := n.copy()
	var sticky := false
	if s > 0:
		nn.shl(s)
	sticky = nn.div_pow10_sticky(b)
	if s < 0:
		sticky = nn.shr_sticky(-s) or sticky
	var q: int = nn.to_int()
	var qb := nn.bit_length()
	var extra := qb - 53
	var mant := q >> extra
	var dropped := q & ((1 << extra) - 1)
	var half := 1 << (extra - 1)
	if dropped > half or (dropped == half and (sticky or (mant & 1) == 1)):
		mant += 1
	return float(mant) * pow(2.0, extra - s)


static func _nearbyint(v: float) -> float:
	var r := floorf(v)
	var d := v - r
	if d > 0.5 or (d == 0.5 and fmod(r, 2.0) != 0.0):
		r += 1.0
	if r == 0.0 and (v < 0.0 or (v == 0.0 and 1.0 / v < 0.0)):
		return v * 0.0  # nearbyint keeps the sign of zero (a -0.0 literal folds to +0)
	return r


static func round_n(x: float, ndigits: int) -> float:
	if not is_finite(x) or ndigits > 22 or x == 0.0:
		return x
	if ndigits < 0:
		var p := pow(10.0, -ndigits)
		return _nearbyint(x / p) * p
	var q := _scaled_round(x, ndigits)
	var v: float
	if q.bit_length() <= 53:
		v = float(q.to_int()) / pow(10.0, ndigits)  # both exact: IEEE division rounds correctly
	else:
		v = _to_double(q, ndigits)
	return -v if x < 0.0 else v


static func round_int(x: float) -> int:
	return int(_nearbyint(x))


static func _neg(x: float) -> bool:
	return x < 0.0 or (x == 0.0 and 1.0 / x < 0.0)


## "%.nf"
static func fmt(x: float, decimals: int) -> String:
	if is_nan(x):
		return "-nan" if _neg(x) else "nan"
	if is_inf(x):
		return "-inf" if x < 0 else "inf"
	var digits := "0"
	if x != 0.0:
		digits = (_scaled_round(x, decimals) if decimals <= 22 else _scaled_round_exact(x, decimals)).to_decimal()
	if decimals > 0:
		if digits.length() <= decimals:
			digits = "0".repeat(decimals - digits.length() + 1) + digits
		digits = digits.substr(0, digits.length() - decimals) + "." + digits.substr(digits.length() - decimals)
	return ("-" if _neg(x) else "") + digits


static func fmt_thousands(x: float, decimals: int) -> String:
	var s := fmt(x, decimals)
	var start := 1 if s.begins_with("-") else 0
	var dot := s.find(".")
	var int_end := s.length() if dot < 0 else dot
	var d := s.substr(start, int_end - start)
	var grouped := ""
	var cnt := 0
	for i in range(d.length() - 1, -1, -1):
		grouped = d[i] + grouped
		cnt += 1
		if cnt % 3 == 0 and i > 0:
			grouped = "," + grouped
	return s.substr(0, start) + grouped + s.substr(int_end)


## [digits BigNat (prec significant), E] with |x| ~ 0.d1d2.. * 10^(E+1): %.{prec}e rounding.
static func _sig_digits(x: float, prec: int) -> Array:
	var e10 := int(floor(log(absf(x)) / log(10.0)))
	for _i in 4:
		var q := _scaled_round_exact(x, prec - 1 - e10)
		var lo := BigNat.of(1).mul_pow10(prec - 1)
		var hi := BigNat.of(1).mul_pow10(prec)
		if BigNat.cmp(q, hi) >= 0:
			e10 += 1
		elif BigNat.cmp(q, lo) < 0:
			e10 -= 1
		else:
			return [q, e10]
	return [_scaled_round_exact(x, prec - 1 - e10), e10]


## The shortest "%.{p}g" (p = 1..17) that strtod reads back as x, with ".0"
## added to integers (Python's 1.0).
static func repr(x: float) -> String:
	if is_nan(x):
		return "nan"
	if is_inf(x):
		return "inf" if x > 0 else "-inf"
	if x == 0.0:
		return "-0.0" if _neg(x) else "0.0"
	var best := []
	for prec in range(1, 18):
		var sd := _sig_digits(x, prec)
		var q: BigNat = sd[0]
		var k: int = prec - 1 - int(sd[1])
		var back: float
		if k >= 0:
			back = _to_double(q, k)
		else:
			back = _to_double(q.copy().mul_pow10(-k), 0)
		best = [q, int(sd[1]), prec]
		if back == absf(x):
			break
	var s := _format_g(best[0].to_decimal(), best[1], best[2])
	if not ("." in s or "e" in s):
		s += ".0"
	return ("-" if x < 0 else "") + s


## C's %g layout of `prec` significant digits with decimal exponent e10.
static func _format_g(digits: String, e10: int, prec: int) -> String:
	if e10 < -4 or e10 >= prec:
		var mant := digits.substr(0, 1)
		var rest := digits.substr(1).rstrip("0")
		if rest != "":
			mant += "." + rest
		var ae := absi(e10)
		return mant + "e" + ("-" if e10 < 0 else "+") + ("%02d" % ae)
	var s: String
	if e10 >= 0:
		s = digits.substr(0, e10 + 1) + "." + digits.substr(e10 + 1)
	else:
		s = "0." + "0".repeat(-e10 - 1) + digits
	if "." in s:
		s = s.rstrip("0").rstrip(".")
	return s


## Correctly rounded decimal string -> double (strtod).
static func parse(text: String) -> float:
	var s := text.strip_edges().to_lower()
	if s in ["nan", "-nan"]:
		return NAN
	if s in ["inf", "infinity", "+inf"]:
		return INF
	if s in ["-inf", "-infinity"]:
		return -INF
	var neg := s.begins_with("-")
	if s.begins_with("-") or s.begins_with("+"):
		s = s.substr(1)
	var exp10 := 0
	var epos := s.find("e")
	if epos >= 0:
		exp10 = s.substr(epos + 1).to_int()
		s = s.substr(0, epos)
	var dot := s.find(".")
	if dot >= 0:
		exp10 -= s.length() - dot - 1
		s = s.replace(".", "")
	var n := BigNat.new()
	for ch in s:
		n.mul_small(10).add_small(ch.unicode_at(0) - 48)
	var v: float
	if exp10 >= 0:
		v = _to_double(n.mul_pow10(exp10), 0)
	else:
		v = _to_double(n, -exp10)
	return -v if neg else v
