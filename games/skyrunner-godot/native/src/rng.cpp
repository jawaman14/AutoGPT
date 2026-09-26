#include "rng.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

// ======================================================================= MT19937
namespace {
constexpr int N = 624;
constexpr int M = 397;
constexpr uint32_t MATRIX_A = 0x9908b0dfU;
constexpr uint32_t UPPER_MASK = 0x80000000U;
constexpr uint32_t LOWER_MASK = 0x7fffffffU;

int bit_length(uint64_t v) {
    int n = 0;
    while (v) {
        ++n;
        v >>= 1;
    }
    return n;
}

// CPython's _Py_HashDouble (Python/pyhash.c), 64-bit build
int64_t py_hash_double(double v) {
    constexpr int BITS = 61;
    constexpr uint64_t MOD = (uint64_t(1) << BITS) - 1;
    if (!std::isfinite(v)) return std::isinf(v) ? (v > 0 ? 314159 : -314159) : 0;
    int e;
    double m = std::frexp(v, &e);
    int sign = 1;
    if (m < 0) {
        sign = -1;
        m = -m;
    }
    uint64_t x = 0;
    while (m) {
        x = ((x << 28) & MOD) | x >> (BITS - 28);
        m *= 268435456.0;
        e -= 28;
        uint64_t y = static_cast<uint64_t>(m);
        m -= static_cast<double>(y);
        x += y;
        if (x >= MOD) x -= MOD;
    }
    e = e >= 0 ? e % BITS : BITS - 1 - ((-1 - e) % BITS);
    x = ((x << e) & MOD) | x >> (BITS - e);
    int64_t h = static_cast<int64_t>(x) * sign;
    if (h == -1) h = -2;
    return h;
}
} // namespace

PyRandom::PyRandom() { seed(0); }

void PyRandom::init_genrand(uint32_t s) {
    mt_[0] = s;
    for (mti_ = 1; mti_ < N; mti_++) {
        mt_[mti_] = 1812433253U * (mt_[mti_ - 1] ^ (mt_[mti_ - 1] >> 30)) + static_cast<uint32_t>(mti_);
    }
}

void PyRandom::init_by_array(const std::vector<uint32_t> &key) {
    init_genrand(19650218U);
    size_t i = 1, j = 0;
    size_t k = N > key.size() ? N : key.size();
    for (; k; k--) {
        mt_[i] = (mt_[i] ^ ((mt_[i - 1] ^ (mt_[i - 1] >> 30)) * 1664525U)) + key[j] + static_cast<uint32_t>(j);
        i++;
        j++;
        if (i >= N) {
            mt_[0] = mt_[N - 1];
            i = 1;
        }
        if (j >= key.size()) j = 0;
    }
    for (k = N - 1; k; k--) {
        mt_[i] = (mt_[i] ^ ((mt_[i - 1] ^ (mt_[i - 1] >> 30)) * 1566083941U)) - static_cast<uint32_t>(i);
        i++;
        if (i >= N) {
            mt_[0] = mt_[N - 1];
            i = 1;
        }
    }
    mt_[0] = 0x80000000U;
    mti_ = N;
}

void PyRandom::seed_u64(uint64_t n) {
    std::vector<uint32_t> key;
    if (n == 0) key.push_back(0);
    while (n) {
        key.push_back(static_cast<uint32_t>(n & 0xffffffffU));
        n >>= 32;
    }
    init_by_array(key);
    has_gauss_next_ = false;
}

void PyRandom::seed(int64_t n) {
    // CPython seeds with abs(n)
    uint64_t u = n < 0 ? static_cast<uint64_t>(-(n + 1)) + 1 : static_cast<uint64_t>(n);
    seed_u64(u);
}

void PyRandom::seed_float(double x) {
    // random_seed(): non-int -> PyLong_FromSize_t((size_t)hash(arg))
    seed_u64(static_cast<uint64_t>(py_hash_double(x)));
}

uint32_t PyRandom::genrand() {
    static const uint32_t mag01[2] = {0x0U, MATRIX_A};
    uint32_t y;
    if (mti_ >= N) {
        int kk;
        for (kk = 0; kk < N - M; kk++) {
            y = (mt_[kk] & UPPER_MASK) | (mt_[kk + 1] & LOWER_MASK);
            mt_[kk] = mt_[kk + M] ^ (y >> 1) ^ mag01[y & 0x1U];
        }
        for (; kk < N - 1; kk++) {
            y = (mt_[kk] & UPPER_MASK) | (mt_[kk + 1] & LOWER_MASK);
            mt_[kk] = mt_[kk + (M - N)] ^ (y >> 1) ^ mag01[y & 0x1U];
        }
        y = (mt_[N - 1] & UPPER_MASK) | (mt_[0] & LOWER_MASK);
        mt_[N - 1] = mt_[M - 1] ^ (y >> 1) ^ mag01[y & 0x1U];
        mti_ = 0;
    }
    y = mt_[mti_++];
    y ^= (y >> 11);
    y ^= (y << 7) & 0x9d2c5680U;
    y ^= (y << 15) & 0xefc60000U;
    y ^= (y >> 18);
    return y;
}

double PyRandom::random() {
    uint32_t a = genrand() >> 5, b = genrand() >> 6;
    return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0);
}

double PyRandom::uniform(double a, double b) { return a + (b - a) * random(); }

int64_t PyRandom::getrandbits(int k) {
    if (k <= 0) return 0;
    if (k <= 32) return genrand() >> (32 - k);
    // little-endian 32-bit words, the last one truncated (k <= 63 here)
    uint64_t out = 0;
    int shift = 0;
    while (k > 0) {
        uint32_t r = genrand();
        if (k < 32) r >>= (32 - k);
        out |= static_cast<uint64_t>(r) << shift;
        shift += 32;
        k -= 32;
    }
    return static_cast<int64_t>(out);
}

int64_t PyRandom::randbelow(int64_t n) {
    if (n <= 0) return 0;
    int k = bit_length(static_cast<uint64_t>(n));
    int64_t r = getrandbits(k);
    while (r >= n) r = getrandbits(k);
    return r;
}

int64_t PyRandom::randint(int64_t a, int64_t b) { return a + randbelow(b - a + 1); }

double PyRandom::gauss(double mu, double sigma) {
    double z;
    if (has_gauss_next_) {
        z = gauss_next_;
        has_gauss_next_ = false;
    } else {
        double x2pi = random() * 2.0 * M_PI;
        double g2rad = std::sqrt(-2.0 * std::log(1.0 - random()));
        z = std::cos(x2pi) * g2rad;
        gauss_next_ = std::sin(x2pi) * g2rad;
        has_gauss_next_ = true;
    }
    return mu + z * sigma;
}

Array PyRandom::shuffle(const Array &items) {
    Array x = items;
    for (int64_t i = x.size() - 1; i > 0; --i) {
        int64_t j = randbelow(i + 1);
        Variant t = x[i];
        x[i] = x[j];
        x[j] = t;
    }
    return x;
}

Variant PyRandom::choice(const Array &items) {
    if (items.is_empty()) return Variant();
    return items[randbelow(items.size())];
}

PackedInt32Array PyRandom::choices_index(const PackedFloat64Array &weights, int k) {
    PackedInt32Array out;
    int n = weights.size();
    if (n == 0) return out;
    std::vector<double> cum(n);
    double acc = 0.0;
    for (int i = 0; i < n; ++i) {
        acc += weights[i];
        cum[i] = acc;
    }
    double total = cum[n - 1];
    for (int t = 0; t < k; ++t) {
        double x = random() * total;
        // bisect.bisect(cum_weights, x, 0, n - 1)
        int lo = 0, hi = n - 1;
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            if (x < cum[mid]) hi = mid;
            else lo = mid + 1;
        }
        out.push_back(lo);
    }
    return out;
}

PackedInt32Array PyRandom::choices_uniform_index(int n, int k) {
    PackedInt32Array out;
    for (int t = 0; t < k; ++t) out.push_back(static_cast<int>(std::floor(random() * n)));
    return out;
}

Array PyRandom::get_state() const {
    Array s;
    for (int i = 0; i < N; ++i) s.push_back(static_cast<int64_t>(mt_[i]));
    s.push_back(mti_);
    s.push_back(has_gauss_next_);
    s.push_back(gauss_next_);
    return s;
}

void PyRandom::set_state(const Array &s) {
    if (s.size() != N + 3) return;
    for (int i = 0; i < N; ++i) mt_[i] = static_cast<uint32_t>(static_cast<int64_t>(s[i]));
    mti_ = s[N];
    has_gauss_next_ = s[N + 1];
    gauss_next_ = s[N + 2];
}

void PyRandom::_bind_methods() {
    ClassDB::bind_method(D_METHOD("seed", "n"), &PyRandom::seed);
    ClassDB::bind_method(D_METHOD("seed_float", "x"), &PyRandom::seed_float);
    ClassDB::bind_method(D_METHOD("random"), &PyRandom::random);
    ClassDB::bind_method(D_METHOD("uniform", "a", "b"), &PyRandom::uniform);
    ClassDB::bind_method(D_METHOD("randint", "a", "b"), &PyRandom::randint);
    ClassDB::bind_method(D_METHOD("randbelow", "n"), &PyRandom::randbelow);
    ClassDB::bind_method(D_METHOD("getrandbits", "k"), &PyRandom::getrandbits);
    ClassDB::bind_method(D_METHOD("gauss", "mu", "sigma"), &PyRandom::gauss);
    ClassDB::bind_method(D_METHOD("shuffle", "items"), &PyRandom::shuffle);
    ClassDB::bind_method(D_METHOD("choice", "items"), &PyRandom::choice);
    ClassDB::bind_method(D_METHOD("choices_index", "weights", "k"), &PyRandom::choices_index);
    ClassDB::bind_method(D_METHOD("choices_uniform_index", "n", "k"), &PyRandom::choices_uniform_index);
    ClassDB::bind_method(D_METHOD("get_state"), &PyRandom::get_state);
    ClassDB::bind_method(D_METHOD("set_state", "state"), &PyRandom::set_state);
}

// ======================================================================= PCG64
namespace {
constexpr uint32_t INIT_A = 0x43b0d7e5U, MULT_A = 0x931e8875U;
constexpr uint32_t INIT_B = 0x8b51f9ddU, MULT_B = 0x58f38dedU;
constexpr uint32_t MIX_MULT_L = 0xca01f9ddU, MIX_MULT_R = 0x4973f715U;
constexpr int XSHIFT = 16;
constexpr int POOL = 4;

uint32_t hashmix(uint32_t value, uint32_t &hash_const) {
    value ^= hash_const;
    hash_const *= MULT_A;
    value *= hash_const;
    value ^= value >> XSHIFT;
    return value;
}

uint32_t mix(uint32_t x, uint32_t y) {
    uint32_t r = MIX_MULT_L * x - MIX_MULT_R * y;
    r ^= r >> XSHIFT;
    return r;
}

const unsigned __int128 PCG_MULT =
    (static_cast<unsigned __int128>(0x2360ED051FC65DA4ULL) << 64) | 0x4385DF649FCCF645ULL;
} // namespace

void NpRandom::step() { state_ = state_ * PCG_MULT + inc_; }

void NpRandom::seed(int64_t n) {
    // SeedSequence(n).generate_state(4, uint64)
    std::vector<uint32_t> entropy;
    uint64_t u = static_cast<uint64_t>(n < 0 ? -n : n);
    if (u == 0) entropy.push_back(0);
    while (u) {
        entropy.push_back(static_cast<uint32_t>(u & 0xffffffffU));
        u >>= 32;
    }
    uint32_t pool[POOL];
    uint32_t hc = INIT_A;
    for (int i = 0; i < POOL; ++i) pool[i] = hashmix(i < static_cast<int>(entropy.size()) ? entropy[i] : 0U, hc);
    for (int s = 0; s < POOL; ++s)
        for (int d = 0; d < POOL; ++d)
            if (s != d) pool[d] = mix(pool[d], hashmix(pool[s], hc));
    for (size_t s = POOL; s < entropy.size(); ++s)
        for (int d = 0; d < POOL; ++d) pool[d] = mix(pool[d], hashmix(entropy[s], hc));
    uint32_t words[8];
    uint32_t hb = INIT_B;
    for (int i = 0; i < 8; ++i) {
        uint32_t v = pool[i % POOL];
        v ^= hb;
        hb *= MULT_B;
        v *= hb;
        v ^= v >> XSHIFT;
        words[i] = v;
    }
    uint64_t val[4];
    for (int i = 0; i < 4; ++i) val[i] = static_cast<uint64_t>(words[2 * i]) | (static_cast<uint64_t>(words[2 * i + 1]) << 32);
    unsigned __int128 initstate = (static_cast<unsigned __int128>(val[0]) << 64) | val[1];
    unsigned __int128 initseq = (static_cast<unsigned __int128>(val[2]) << 64) | val[3];
    state_ = 0;
    inc_ = (initseq << 1) | 1;
    step();
    state_ += initstate;
    step();
}

uint64_t NpRandom::next_u64() {
    step();
    uint64_t hi = static_cast<uint64_t>(state_ >> 64);
    uint64_t lo = static_cast<uint64_t>(state_);
    unsigned rot = static_cast<unsigned>(state_ >> 122);
    uint64_t x = hi ^ lo;
    return (x >> rot) | (x << ((64 - rot) & 63));
}

double NpRandom::random() { return static_cast<double>(next_u64() >> 11) * (1.0 / 9007199254740992.0); }
double NpRandom::uniform(double lo, double hi) { return lo + (hi - lo) * random(); }

PackedFloat64Array NpRandom::random_array(int n) {
    PackedFloat64Array out;
    out.resize(n);
    for (int i = 0; i < n; ++i) out.set(i, random());
    return out;
}

PackedFloat64Array NpRandom::uniform_array(int n, double lo, double hi) {
    PackedFloat64Array out;
    out.resize(n);
    for (int i = 0; i < n; ++i) out.set(i, uniform(lo, hi));
    return out;
}

void NpRandom::_bind_methods() {
    ClassDB::bind_method(D_METHOD("seed", "n"), &NpRandom::seed);
    ClassDB::bind_method(D_METHOD("random"), &NpRandom::random);
    ClassDB::bind_method(D_METHOD("uniform", "lo", "hi"), &NpRandom::uniform);
    ClassDB::bind_method(D_METHOD("random_array", "n"), &NpRandom::random_array);
    ClassDB::bind_method(D_METHOD("uniform_array", "n", "lo", "hi"), &NpRandom::uniform_array);
}
