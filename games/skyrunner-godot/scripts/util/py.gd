class_name Py
extends RefCounted
## Python semantics the ported game logic relies on, in one place:
## stable sorts, first-wins min/max, floor modulo, CPython hypot/round and
## f-string style number formatting. Using these instead of the GDScript
## built-ins keeps seeded runs identical to the Python game.


## sorted(items, key=key, reverse=reverse): stable (merge sort).
static func sorted_by(items: Array, key: Callable, reverse := false) -> Array:
	var keyed := []
	for i in items.size():
		keyed.append([key.call(items[i]), i, items[i]])
	keyed = _merge_sort(keyed, reverse)
	var out := []
	for k in keyed:
		out.append(k[2])
	return out


static func _merge_sort(a: Array, reverse: bool) -> Array:
	if a.size() <= 1:
		return a
	var mid := a.size() / 2
	var left := _merge_sort(a.slice(0, mid), reverse)
	var right := _merge_sort(a.slice(mid), reverse)
	var out := []
	var i := 0
	var j := 0
	while i < left.size() and j < right.size():
		# stable: take from the left unless the right is strictly first
		var take_right: bool = (right[j][0] > left[i][0]) if reverse else (right[j][0] < left[i][0])
		if take_right:
			out.append(right[j])
			j += 1
		else:
			out.append(left[i])
			i += 1
	while i < left.size():
		out.append(left[i])
		i += 1
	while j < right.size():
		out.append(right[j])
		j += 1
	return out


## min(items, key=key, default=default): the first minimal item.
static func min_by(items: Array, key: Callable, default = null):
	var best = default
	var bk = null
	var first := true
	for it in items:
		var k = key.call(it)
		if first or k < bk:
			best = it
			bk = k
			first = false
	return best


## max(items, key=key, default=default): the first maximal item.
static func max_by(items: Array, key: Callable, default = null):
	var best = default
	var bk = null
	var first := true
	for it in items:
		var k = key.call(it)
		if first or k > bk:
			best = it
			bk = k
			first = false
	return best


static func any(items: Array, pred: Callable) -> bool:
	for it in items:
		if pred.call(it):
			return true
	return false


static func all(items: Array, pred: Callable) -> bool:
	for it in items:
		if not pred.call(it):
			return false
	return true


static func count(items: Array, pred: Callable) -> int:
	var n := 0
	for it in items:
		if pred.call(it):
			n += 1
	return n


static func sum_by(items: Array, f: Callable) -> float:
	var s := 0.0
	for it in items:
		s += f.call(it)
	return s


static func first(items: Array, pred: Callable, default = null):
	for it in items:
		if pred.call(it):
			return it
	return default


static func filter(items: Array, pred: Callable) -> Array:
	var out := []
	for it in items:
		if pred.call(it):
			out.append(it)
	return out


## Python float a % b (sign of the divisor).
static func fmod(a: float, b: float) -> float:
	return fposmod(a, b)


## Python int a % b.
static func imod(a: int, b: int) -> int:
	return posmod(a, b)


## Python int a // b (floor division).
static func idiv(a: int, b: int) -> int:
	var q := a / b
	if a % b != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q


static func wrap180(a: float) -> float:
	return fposmod(a + 180.0, 360.0) - 180.0


static func clamp(v: float, lo: float, hi: float) -> float:
	return lo if v < lo else (hi if v > hi else v)


static func hypot(x: float, y: float) -> float:
	return PyMath.hypot(x, y)


static func dist2(a: Array, b: Array) -> float:
	return PyMath.hypot(a[0] - b[0], a[1] - b[1])


static func dist3(a: Array, b: Array) -> float:
	return PyMath.hypot3(a[0] - b[0], a[1] - b[1], a[2] - b[2])


static func round_n(x: float, n: int) -> float:
	return PyMath.round_n(x, n)


## round(x) -> int, half to even.
static func round_int(x: float) -> int:
	return PyMath.round_int(x)


## f"{x:.{n}f}"
static func f(x: float, n := 0) -> String:
	return PyMath.fmt(x, n)


## f"{x:,}" for ints / f"{x:,.{n}f}" for floats
static func money(x, n := 0) -> String:
	return PyMath.fmt_thousands(float(x), n)


## f"{x:0{w}.0f}" style zero padding for headings: "007"
static func f0(x: float, width: int) -> String:
	var s := PyMath.fmt(x, 0)
	while s.length() < width:
		s = "0" + s
	return s


static func degrees(r: float) -> float:
	return r * (180.0 / PI)


static func radians(d: float) -> float:
	return d * (PI / 180.0)


## del lst[:-n] - keep the last n entries in place
static func keep_last(lst: Array, n: int) -> void:
	if lst.size() > n:
		var drop := lst.size() - n
		for i in drop:
			lst.remove_at(0)


static func dict_get(d: Dictionary, k, default = null):
	return d[k] if d.has(k) else default
