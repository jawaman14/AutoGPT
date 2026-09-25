class_name TestCase
extends RefCounted
## Base for headless tests: methods named test_* run in file order.
## check()/check_eq()/check_near() record failures instead of aborting, so one
## bad assertion doesn't hide the rest of the file.

var failures: Array[String] = []
var current := ""


func before_each() -> void:
	pass


func check(cond: bool, msg := "") -> bool:
	if not cond:
		failures.append("%s: %s" % [current, msg if msg else "check failed"])
	return cond


func check_eq(a, b, msg := "") -> bool:
	return check(a == b, "%s (got %s, expected %s)" % [msg, str(a), str(b)])


func check_near(a: float, b: float, tol: float, msg := "") -> bool:
	return check(absf(a - b) <= tol, "%s (got %s, expected %s +- %s)" % [msg, a, b, tol])


func check_between(v: float, lo: float, hi: float, msg := "") -> bool:
	return check(v >= lo and v <= hi, "%s (got %s, expected %s..%s)" % [msg, v, lo, hi])
