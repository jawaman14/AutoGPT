#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// CPython 3.11 float semantics the Python game's numbers depend on:
// math.hypot / math.dist (compensated vector_norm, not libm hypot), round()
// (half-to-even, and round(x, n) correctly rounded on the exact binary value),
// and %-style formatting. Static methods: PyMath.hypot(x, y) from GDScript.
class PyMath : public Object {
    GDCLASS(PyMath, Object)

public:
    static double hypot(double x, double y);
    static double hypot3(double x, double y, double z);
    static double round_n(double x, int ndigits);
    static int64_t round_int(double x);
    static double log1p(double x);
    static String fmt(double x, int decimals);          // f"{x:.Nf}"
    static String fmt_thousands(double x, int decimals); // f"{x:,.Nf}"

protected:
    static void _bind_methods();
};

} // namespace godot
