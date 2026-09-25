#include "terrain.h"

#include "rng.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr int G = Terrain::GRID;
constexpr double HALF = Terrain::HALF;
constexpr double CELL = Terrain::CELL;
constexpr double BUCKET = 250.0;

inline double clip(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

// numpy: t = clip((x - e0) / (e1 - e0), 0, 1); t * t * (3 - 2 * t)
inline double smoothstep(double e0, double e1, double x) {
    double t = clip((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// world._value_noise: bilinear, smoothstep-weighted lattice of rng.random()
void value_noise(NpRandom &rng, int n, int cells, std::vector<double> &out) {
    const int L = cells + 2;
    std::vector<double> lat(static_cast<size_t>(L) * L);
    for (double &v : lat) v = rng.random();
    std::vector<int> idx(n);
    std::vector<double> f(n);
    const double step = static_cast<double>(cells) / n;  // linspace(0, cells, n, endpoint=False)
    for (int k = 0; k < n; ++k) {
        double t = static_cast<double>(k) * step + 0.0;
        idx[k] = static_cast<int>(t);
        double ff = t - idx[k];
        f[k] = ff * ff * (3.0 - 2.0 * ff);
    }
    out.assign(static_cast<size_t>(n) * n, 0.0);
    for (int r = 0; r < n; ++r) {
        const int ir = idx[r];
        const double fy = f[r];
        for (int c = 0; c < n; ++c) {
            const int ic = idx[c];
            const double fx = f[c];
            const double a = lat[static_cast<size_t>(ir) * L + ic];
            const double b = lat[static_cast<size_t>(ir) * L + ic + 1];
            const double cc = lat[static_cast<size_t>(ir + 1) * L + ic];
            const double d = lat[static_cast<size_t>(ir + 1) * L + ic + 1];
            out[static_cast<size_t>(r) * n + c] = (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (cc * (1.0 - fx) + d * fx) * fy;
        }
    }
}

void fbm(NpRandom &rng, int n, int base_cells, int octaves, std::vector<double> &out) {
    out.assign(static_cast<size_t>(n) * n, 0.0);
    std::vector<double> vn;
    double amp = 1.0, total = 0.0;
    int cells = base_cells;
    for (int o = 0; o < octaves; ++o) {
        value_noise(rng, n, cells, vn);
        for (size_t k = 0; k < out.size(); ++k) out[k] += amp * vn[k];
        total += amp;
        amp *= 0.5;
        cells *= 2;
    }
    for (double &v : out) v = v / total;
}

void normalise(std::vector<double> &v) {
    auto [mn, mx] = std::minmax_element(v.begin(), v.end());
    const double lo = *mn, hi = *mx;
    for (double &x : v) x = (x - lo) / (hi - lo);
}

inline int64_t bucket_key(int bi, int bj) { return (static_cast<int64_t>(bi) << 32) ^ static_cast<uint32_t>(bj); }

inline int floordiv_f32(float x) {
    // numpy float32 floor_divide by a Python float bucket size
    return static_cast<int>(std::floor(x / static_cast<float>(BUCKET)));
}

double linspace_endpoint(int k) { return static_cast<double>(k) * (Terrain::SIZE_M / (G - 1)) + (-HALF); }
} // namespace

bool Terrain::Field::contains(double px, double py, double margin) const {
    const double dx = px - x, dy = py - y;
    const double a = dx * ux + dy * uy;
    const double c = dx * uy - dy * ux;
    return std::abs(a) <= length / 2 + margin && std::abs(c) <= width / 2 + margin;
}

void Terrain::parse_fields(const Array &airfields) {
    fields_.clear();
    for (int i = 0; i < airfields.size(); ++i) {
        Dictionary d = airfields[i];
        Field f;
        f.code = d["code"];
        f.x = d["x"];
        f.y = d["y"];
        f.heading = d["heading"];
        f.length = d["length"];
        f.width = d["width"];
        Variant e = d.get("elev", Variant());
        f.has_elev = e.get_type() != Variant::NIL;
        f.elev = f.has_elev ? static_cast<double>(e) : 0.0;
        f.setting = d.get("setting", "flat");
        f.tree_lines = d.get("tree_lines", false);
        Variant hr = d.get("haul_road", Variant());
        f.haul_road = hr.get_type() == Variant::NIL ? -1 : static_cast<int>(hr);
        const double h = f.heading * M_PI / 180.0;  // math.radians
        f.ux = std::sin(h);
        f.uy = std::cos(h);
        fields_.push_back(f);
    }
}

double Terrain::sample64(const std::vector<double> &h, double x, double y) const {
    const double fx = (x + HALF) / CELL, fy = (y + HALF) / CELL;
    const int i = static_cast<int>(clip(fx, 0, G - 2)), j = static_cast<int>(clip(fy, 0, G - 2));
    const double tx = fx - i, ty = fy - j;
    return h[static_cast<size_t>(j) * G + i] * (1 - tx) * (1 - ty) + h[static_cast<size_t>(j) * G + i + 1] * tx * (1 - ty) +
           h[static_cast<size_t>(j + 1) * G + i] * (1 - tx) * ty + h[static_cast<size_t>(j + 1) * G + i + 1] * tx * ty;
}

void Terrain::generate(int64_t seed, const Array &airfields) {
    parse_fields(airfields);
    field_elev_.clear();
    const size_t NN = static_cast<size_t>(G) * G;
    std::vector<double> cv(G);
    for (int k = 0; k < G; ++k) cv[k] = linspace_endpoint(k);
    cv[G - 1] = HALF;

    Ref<NpRandom> rng;
    rng.instantiate();
    rng->seed(seed);
    std::vector<double> noise, detail;
    fbm(**rng, G, 4, 7, noise);
    normalise(noise);
    fbm(**rng, G, 16, 4, detail);
    normalise(detail);

    std::vector<double> h(NN);
    for (int r = 0; r < G; ++r) {
        const double Y = cv[r];
        for (int c = 0; c < G; ++c) {
            const double X = cv[c];
            const size_t k = static_cast<size_t>(r) * G + c;
            const double nz = noise[k], dt = detail[k];
            const double rr = std::hypot(X / 14500, Y / 13500) + (nz - 0.5) * 0.35;
            const double land = smoothstep(1.02, 0.72, rr);
            const double ridge_d = std::abs(Y - (5200 + 2200 * std::sin(X / 6000.0)));
            const double q = ridge_d / 3000;
            const double ridge = std::exp(-(q * q)) * (0.25 + 0.75 * nz + 0.5 * dt);
            double hv = land * (35 + 260 * nz + 120 * dt) + land * ridge * 1150;
            hv = hv - (1 - land) * 60;
            h[k] = hv;
        }
    }
    // guarantee land for offshore strips
    for (const Field &af : fields_) {
        const double amp = af.has_elev ? std::min(30.0, af.elev + 3.0) : 30.0;
        for (int r = 0; r < G; ++r) {
            const double dy = cv[r] - af.y;
            for (int c = 0; c < G; ++c) {
                const double dx = cv[c] - af.x;
                const double bump = std::exp(-((dx * dx + dy * dy) / (1400.0 * 1400.0)));
                const size_t k = static_cast<size_t>(r) * G + c;
                h[k] = std::max(h[k], bump * amp - (1 - bump) * 60);
            }
        }
    }
    for (const Field &af : fields_) {
        double elev = af.has_elev ? af.elev : sample64(h, af.x, af.y);
        elev = std::max(elev, 2.0);
        const double half_len = af.length / 2, half_w = af.width / 2;
        for (int r = 0; r < G; ++r) {
            const double dy = cv[r] - af.y;
            for (int c = 0; c < G; ++c) {
                const double dx = cv[c] - af.x;
                const size_t k = static_cast<size_t>(r) * G + c;
                const double lon = dx * af.ux + dy * af.uy;
                const double lat = dx * af.uy - dy * af.ux;
                const double along = std::abs(lon) - half_len;
                const double across = std::abs(lat) - half_w;
                const double dist = std::hypot(std::max(along, 0.0), std::max(across, 0.0));
                double hv = h[k];
                if (af.setting == "plateau") {
                    const double top = smoothstep(130, 80, dist);
                    hv = dist < 130 ? hv * (1 - top) + elev * top : std::min(hv, elev - 180 * smoothstep(130, 260, dist));
                } else if (af.setting == "pit") {
                    const double flat = smoothstep(110, 60, dist);
                    const double qa = (across - 55) / 30;
                    const double side = std::exp(-(qa * qa)) * 70 * smoothstep(90, 0, along);
                    hv = hv * (1 - flat) + elev * flat + side;
                    if (af.haul_road >= 0) {
                        const double s_end = af.haul_road == 0 ? -1.0 : 1.0;
                        const double beyond = s_end * lon - half_len;
                        const bool cut = beyond > -20 && std::abs(lat) < 70 + std::max(beyond, 0.0) * 0.3;
                        if (cut) hv = std::min(hv, elev - std::max(beyond, 0.0) * 0.06);
                    }
                } else {
                    const double reach = af.setting == "beach" ? 650.0 : 260.0;
                    const double blend = smoothstep(reach, 50, dist);
                    hv = hv * (1 - blend) + elev * blend;
                }
                h[k] = hv;
            }
        }
        field_elev_[af.code] = elev;
    }
    h_.resize(NN);
    for (size_t k = 0; k < NN; ++k) h_[k] = static_cast<float>(h[k]);

    // ---------------------------------------------------------------- trees
    Ref<NpRandom> trng;
    trng.instantiate();
    trng->seed(seed + 1);
    std::vector<double> forest;
    fbm(**trng, G, 8, 3, forest);
    std::vector<double> cand(120000);
    for (double &v : cand) v = trng->uniform(-HALF, HALF);
    std::vector<float> pts;
    for (int n = 0; n < 60000; ++n) {
        const double x = cand[2 * n], y = cand[2 * n + 1];
        const double z = height64(x, y);
        if (z < 6 || z > 1300) continue;
        const int fi = static_cast<int>((y + HALF) / CELL), fj = static_cast<int>((x + HALF) / CELL);
        if (forest[static_cast<size_t>(fi) * G + fj] < 0.52) continue;
        bool on_field = false;
        for (const Field &af : fields_) {
            if (af.contains(x, y, 45)) {
                on_field = true;
                break;
            }
        }
        if (on_field) continue;
        const double th = trng->uniform(9, 20);
        pts.insert(pts.end(), {static_cast<float>(x), static_cast<float>(y), static_cast<float>(z), static_cast<float>(th)});
    }
    // deliberate obstacles: tree lines off both ends of bush strips
    for (const Field &af : fields_) {
        if (!af.tree_lines) continue;
        for (int end : {-1, 1}) {
            const double d = af.length / 2 + 110;
            for (int s = 0; s < 13; ++s) {
                const double kk = static_cast<double>(s) * 7.5 + (-45.0);  // linspace(-45, 45, 13)
                const double x = af.x + end * af.ux * d + af.uy * kk;
                const double y = af.y + end * af.uy * d - af.ux * kk;
                pts.insert(pts.end(), {static_cast<float>(x), static_cast<float>(y), static_cast<float>(height64(x, y)), 16.0f});
            }
        }
    }
    trees_ = std::move(pts);
    bucket_trees();
}

void Terrain::set_data(const PackedFloat32Array &heights, const PackedFloat32Array &trees, const Array &airfields) {
    parse_fields(airfields);
    h_.assign(heights.ptr(), heights.ptr() + heights.size());
    trees_.assign(trees.ptr(), trees.ptr() + trees.size());
    bucket_trees();
}

void Terrain::bucket_trees() {
    buckets_.clear();
    for (int i = 0; i < tree_count(); ++i) {
        buckets_[bucket_key(floordiv_f32(trees_[4 * i]), floordiv_f32(trees_[4 * i + 1]))].push_back(i);
    }
}

PackedFloat32Array Terrain::get_heights() const {
    PackedFloat32Array a;
    a.resize(static_cast<int64_t>(h_.size()));
    std::copy(h_.begin(), h_.end(), a.ptrw());
    return a;
}

PackedFloat32Array Terrain::get_trees() const {
    PackedFloat32Array a;
    a.resize(static_cast<int64_t>(trees_.size()));
    std::copy(trees_.begin(), trees_.end(), a.ptrw());
    return a;
}

double Terrain::height(double x, double y) const {
    const double fx = (x + HALF) / CELL, fy = (y + HALF) / CELL;
    const int i = static_cast<int>(clip(fx, 0, G - 2)), j = static_cast<int>(clip(fy, 0, G - 2));
    const double tx = fx - i, ty = fy - j;
    const float a = static_cast<float>(1 - tx), b = static_cast<float>(tx);
    const float c = static_cast<float>(1 - ty), d = static_cast<float>(ty);
    const float *row = &h_[static_cast<size_t>(j) * G];
    const float *row2 = row + G;
    float v = row[i] * a * c;
    v = v + row[i + 1] * b * c;
    v = v + row2[i] * a * d;
    v = v + row2[i + 1] * b * d;
    return static_cast<double>(v);
}

double Terrain::height64(double x, double y) const {
    const double fx = (x + HALF) / CELL, fy = (y + HALF) / CELL;
    const int i = static_cast<int>(clip(fx, 0, G - 2)), j = static_cast<int>(clip(fy, 0, G - 2));
    const double tx = fx - i, ty = fy - j;
    const float *row = &h_[static_cast<size_t>(j) * G];
    const float *row2 = row + G;
    return static_cast<double>(row[i]) * (1 - tx) * (1 - ty) + static_cast<double>(row[i + 1]) * tx * (1 - ty) +
           static_cast<double>(row2[i]) * (1 - tx) * ty + static_cast<double>(row2[i + 1]) * tx * ty;
}

double Terrain::heights_many_one(double x, double y) const {
    const double fx = clip((x + HALF) / CELL, 0, G - 1.0001), fy = clip((y + HALF) / CELL, 0, G - 1.0001);
    const int i = static_cast<int>(fx), j = static_cast<int>(fy);
    const double tx = fx - i, ty = fy - j;
    const float *row = &h_[static_cast<size_t>(j) * G];
    const float *row2 = row + G;
    return static_cast<double>(row[i]) * (1 - tx) * (1 - ty) + static_cast<double>(row[i + 1]) * tx * (1 - ty) +
           static_cast<double>(row2[i]) * (1 - tx) * ty + static_cast<double>(row2[i + 1]) * tx * ty;
}

PackedFloat64Array Terrain::heights_many(const PackedFloat64Array &xs, const PackedFloat64Array &ys) const {
    PackedFloat64Array out;
    const int64_t n = std::min(xs.size(), ys.size());
    out.resize(n);
    for (int64_t k = 0; k < n; ++k) out.set(k, heights_many_one(xs[k], ys[k]));
    return out;
}

bool Terrain::line_of_sight(double ax, double ay, double az, double bx, double by, double bz, double step) const {
    const double d = std::hypot(bx - ax, by - ay);
    const int n = std::max(2, static_cast<int>(d / step));
    for (int k = 1; k < n; ++k) {
        const double t = static_cast<double>(k) / n;
        const double g = std::max(heights_many_one(ax + (bx - ax) * t, ay + (by - ay) * t), 0.0);
        if (!(g <= az + (bz - az) * t)) return false;
    }
    return true;
}

bool Terrain::tree_hit(double x, double y, double z, double radius) const {
    const int bi = static_cast<int>(std::floor(x / BUCKET)), bj = static_cast<int>(std::floor(y / BUCKET));
    const float xf = static_cast<float>(x), yf = static_cast<float>(y), rf = static_cast<float>(radius);
    for (int di = -1; di <= 1; ++di)
        for (int dj = -1; dj <= 1; ++dj) {
            auto it = buckets_.find(bucket_key(bi + di, bj + dj));
            if (it == buckets_.end()) continue;
            for (int idx : it->second) {
                const float *t = &trees_[4 * static_cast<size_t>(idx)];
                const float ddx = t[0] - xf, ddy = t[1] - yf, rr = rf + t[3] * 0.25f;
                if (z < static_cast<double>(t[2] + t[3]) && ddx * ddx + ddy * ddy < rr * rr) return true;
            }
        }
    return false;
}

double Terrain::tree_top(double x, double y, double radius, double floor) const {
    double top = floor;
    const int bi = static_cast<int>(std::floor(x / BUCKET)), bj = static_cast<int>(std::floor(y / BUCKET));
    const float xf = static_cast<float>(x), yf = static_cast<float>(y), r2 = static_cast<float>(radius * radius);
    for (int di = -1; di <= 1; ++di)
        for (int dj = -1; dj <= 1; ++dj) {
            auto it = buckets_.find(bucket_key(bi + di, bj + dj));
            if (it == buckets_.end()) continue;
            for (int idx : it->second) {
                const float *t = &trees_[4 * static_cast<size_t>(idx)];
                const float ddx = t[0] - xf, ddy = t[1] - yf;
                if (ddx * ddx + ddy * ddy < r2) top = std::max(top, static_cast<double>(t[2] + t[3]));
            }
        }
    return top;
}

void Terrain::_bind_methods() {
    ClassDB::bind_method(D_METHOD("generate", "seed", "airfields"), &Terrain::generate);
    ClassDB::bind_method(D_METHOD("set_data", "heights", "trees", "airfields"), &Terrain::set_data);
    ClassDB::bind_method(D_METHOD("get_heights"), &Terrain::get_heights);
    ClassDB::bind_method(D_METHOD("get_trees"), &Terrain::get_trees);
    ClassDB::bind_method(D_METHOD("get_field_elev"), &Terrain::get_field_elev);
    ClassDB::bind_method(D_METHOD("tree_count"), &Terrain::tree_count);
    ClassDB::bind_method(D_METHOD("height", "x", "y"), &Terrain::height);
    ClassDB::bind_method(D_METHOD("height64", "x", "y"), &Terrain::height64);
    ClassDB::bind_method(D_METHOD("heights_many", "xs", "ys"), &Terrain::heights_many);
    ClassDB::bind_method(D_METHOD("line_of_sight", "ax", "ay", "az", "bx", "by", "bz", "step"), &Terrain::line_of_sight);
    ClassDB::bind_method(D_METHOD("tree_hit", "x", "y", "z", "radius"), &Terrain::tree_hit);
    ClassDB::bind_method(D_METHOD("tree_top", "x", "y", "radius", "floor"), &Terrain::tree_top);
}
