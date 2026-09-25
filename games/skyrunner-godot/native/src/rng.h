#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>
#include <vector>

namespace godot {

// CPython's random.Random, bit for bit (MT19937 + CPython's seeding, float
// generation, _randbelow rejection sampling, gauss pairing, shuffle, choices).
// The Python game drew every job board, police decision and simulated night
// from these streams; matching them lets the port be checked seed-for-seed.
class PyRandom : public RefCounted {
    GDCLASS(PyRandom, RefCounted)

public:
    PyRandom();
    void seed(int64_t n);          // random.Random(int)
    void seed_float(double x);      // random.Random(float): CPython seeds with hash(x)
    double random();
    double uniform(double a, double b);
    int64_t randint(int64_t a, int64_t b);
    int64_t randbelow(int64_t n);
    int64_t getrandbits(int k);
    double gauss(double mu, double sigma);
    Array shuffle(const Array &items);       // returns the same array, shuffled in place
    Variant choice(const Array &items);
    PackedInt32Array choices_index(const PackedFloat64Array &weights, int k);  // random.choices(range(n), weights, k)
    PackedInt32Array choices_uniform_index(int n, int k);                        // random.choices(seq, k) without weights
    Array get_state() const;
    void set_state(const Array &state);

    // C++ callers (world gen etc.)
    uint32_t genrand();

protected:
    static void _bind_methods();

private:
    void init_genrand(uint32_t s);
    void init_by_array(const std::vector<uint32_t> &key);
    void seed_u64(uint64_t n);

    uint32_t mt_[624];
    int mti_ = 625;
    bool has_gauss_next_ = false;
    double gauss_next_ = 0.0;
};

// numpy.random.default_rng(seed): SeedSequence -> PCG64 (XSL-RR), with numpy's
// random()/uniform() double conversion. Used for the terrain and tree scatter.
class NpRandom : public RefCounted {
    GDCLASS(NpRandom, RefCounted)

public:
    void seed(int64_t n);
    double random();
    double uniform(double lo, double hi);
    PackedFloat64Array random_array(int n);
    PackedFloat64Array uniform_array(int n, double lo, double hi);

    uint64_t next_u64();

protected:
    static void _bind_methods();

private:
    unsigned __int128 state_ = 0;
    unsigned __int128 inc_ = 0;
    void step();
};

} // namespace godot
