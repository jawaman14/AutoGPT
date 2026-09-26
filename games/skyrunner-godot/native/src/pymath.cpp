#include "pymath.h"

#include <godot_cpp/core/class_db.hpp>

#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

using namespace godot;

namespace {
struct DL {
    double hi, lo;
};
inline DL dl_fast_sum(double a, double b) {
    double x = a + b;
    double y = (a - x) + b;
    return {x, y};
}
inline DL dl_mul(double x, double y) {
    double z = x * y;
    double zz = std::fma(x, y, -z);
    return {z, zz};
}

// Modules/mathmodule.c vector_norm (CPython 3.11)
double vector_norm(int n, double *vec, double max, bool found_nan) {
    double x, h, scale, csum = 1.0, frac1 = 0.0, frac2 = 0.0;
    DL pr, sm;
    int max_e;
    if (std::isinf(max)) return max;
    if (found_nan) return NAN;
    if (max == 0.0 || n <= 1) return max;
    std::frexp(max, &max_e);
    if (max_e < -1023) {
        for (int i = 0; i < n; i++) vec[i] /= DBL_MIN;
        return DBL_MIN * vector_norm(n, vec, max / DBL_MIN, found_nan);
    }
    scale = std::ldexp(1.0, -max_e);
    for (int i = 0; i < n; i++) {
        x = vec[i];
        x *= scale;
        pr = dl_mul(x, x);
        sm = dl_fast_sum(csum, pr.hi);
        csum = sm.hi;
        frac1 += pr.lo;
        frac2 += sm.lo;
    }
    h = std::sqrt(csum - 1.0 + (frac1 + frac2));
    pr = dl_mul(-h, h);
    sm = dl_fast_sum(csum, pr.hi);
    csum = sm.hi;
    frac1 += pr.lo;
    frac2 += sm.lo;
    x = csum - 1.0 + (frac1 + frac2);
    h += x / (2.0 * h);
    return h / scale;
}

double norm_of(double *v, int n) {
    double max = 0.0;
    bool nan = false;
    for (int i = 0; i < n; i++) {
        v[i] = std::fabs(v[i]);
        nan |= std::isnan(v[i]);
        if (v[i] > max) max = v[i];
    }
    return vector_norm(n, v, max, nan);
}

std::string with_commas(const std::string &s) {
    size_t start = (s[0] == '-') ? 1 : 0;
    size_t dot = s.find('.');
    size_t int_end = dot == std::string::npos ? s.size() : dot;
    std::string out = s.substr(0, start);
    std::string digits = s.substr(start, int_end - start);
    int cnt = 0;
    std::string grouped;
    for (int i = static_cast<int>(digits.size()) - 1; i >= 0; --i) {
        grouped.insert(grouped.begin(), digits[i]);
        if (++cnt % 3 == 0 && i > 0) grouped.insert(grouped.begin(), ',');
    }
    return out + grouped + s.substr(int_end);
}
} // namespace

double PyMath::hypot(double x, double y) {
    double v[2] = {x, y};
    return norm_of(v, 2);
}

double PyMath::hypot3(double x, double y, double z) {
    double v[3] = {x, y, z};
    return norm_of(v, 3);
}

double PyMath::round_n(double x, int ndigits) {
    // CPython double_round: correctly rounded decimal (half-even on the exact
    // binary value), then back to the nearest double. glibc printf does the same.
    if (!std::isfinite(x)) return x;
    if (ndigits > 22 || x == 0.0) return x;
    char buf[512];
    std::snprintf(buf, sizeof(buf), "%.*f", ndigits < 0 ? 0 : ndigits, x);
    if (ndigits < 0) {
        double p = std::pow(10.0, -ndigits);
        return std::nearbyint(x / p) * p;
    }
    return std::strtod(buf, nullptr);
}

int64_t PyMath::round_int(double x) { return static_cast<int64_t>(std::nearbyint(x)); }

double PyMath::log1p(double x) { return std::log1p(x); }

// Godot's String::num / to_float are not correctly rounded (about 40% of
// doubles don't survive a 17-digit round trip), so lossless text goes via libc.
String PyMath::repr(double x) {
    if (std::isnan(x)) return "nan";
    if (std::isinf(x)) return x > 0 ? "inf" : "-inf";
    char buf[40];
    for (int prec = 1; prec <= 17; prec++) {
        std::snprintf(buf, sizeof buf, "%.*g", prec, x);
        if (std::strtod(buf, nullptr) == x) break;
    }
    std::string s(buf);
    if (s.find_first_of(".eE") == std::string::npos) s += ".0";  // 1 -> 1.0, like Python
    return String(s.c_str());
}

double PyMath::parse(const String &s) {
    CharString c = s.utf8();
    return std::strtod(c.get_data(), nullptr);
}

String PyMath::fmt(double x, int decimals) {
    char buf[512];
    std::snprintf(buf, sizeof(buf), "%.*f", decimals, x);
    return String(buf);
}

String PyMath::fmt_thousands(double x, int decimals) {
    char buf[512];
    std::snprintf(buf, sizeof(buf), "%.*f", decimals, x);
    return String(with_commas(buf).c_str());
}

void PyMath::_bind_methods() {
    ClassDB::bind_static_method("PyMath", D_METHOD("hypot", "x", "y"), &PyMath::hypot);
    ClassDB::bind_static_method("PyMath", D_METHOD("hypot3", "x", "y", "z"), &PyMath::hypot3);
    ClassDB::bind_static_method("PyMath", D_METHOD("round_n", "x", "ndigits"), &PyMath::round_n);
    ClassDB::bind_static_method("PyMath", D_METHOD("round_int", "x"), &PyMath::round_int);
    ClassDB::bind_static_method("PyMath", D_METHOD("log1p", "x"), &PyMath::log1p);
    ClassDB::bind_static_method("PyMath", D_METHOD("fmt", "x", "decimals"), &PyMath::fmt);
    ClassDB::bind_static_method("PyMath", D_METHOD("fmt_thousands", "x", "decimals"), &PyMath::fmt_thousands);
    ClassDB::bind_static_method("PyMath", D_METHOD("repr", "x"), &PyMath::repr);
    ClassDB::bind_static_method("PyMath", D_METHOD("parse", "s"), &PyMath::parse);
}
