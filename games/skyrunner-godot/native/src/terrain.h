#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

// The procedural island: height grid, trees and the terrain queries the
// physics, radar and bots hammer every frame. A line-for-line port of the
// Python world.py generator (numpy PCG64 streams, same operation order), so
// seed 7 builds the island the balance numbers were measured on.
class Terrain : public RefCounted {
    GDCLASS(Terrain, RefCounted)

public:
    static constexpr int GRID = 513;
    static constexpr double SIZE_M = 32000.0;
    static constexpr double HALF = SIZE_M / 2;
    static constexpr double CELL = SIZE_M / (GRID - 1);

    struct Field {
        String code;
        double x, y, heading, length, width;
        bool has_elev;
        double elev;
        String setting;
        bool tree_lines;
        int haul_road;  // -1 none
        double ux, uy;
        bool contains(double px, double py, double margin) const;
    };

    // airfields: Array of Dictionary {code,x,y,heading,length,width,elev(null|float),setting,tree_lines,haul_road(null|int)}
    void generate(int64_t seed, const Array &airfields);
    void generate_custom(int64_t seed, const Dictionary &params, const Array &airfields);
    void set_data(const PackedFloat32Array &heights, const PackedFloat32Array &trees, const Array &airfields);

    PackedFloat32Array get_heights() const;
    PackedFloat32Array get_trees() const;
    Dictionary get_field_elev() const { return field_elev_; }
    int tree_count() const { return static_cast<int>(trees_.size() / 4); }

    double height(double x, double y) const;     // Python world.height(): float32 arithmetic
    double height64(double x, double y) const;   // same with float64 arithmetic (numpy float64 callers)
    PackedFloat64Array heights_many(const PackedFloat64Array &xs, const PackedFloat64Array &ys) const;
    bool line_of_sight(double ax, double ay, double az, double bx, double by, double bz, double step) const;
    bool tree_hit(double x, double y, double z, double radius) const;
    double tree_top(double x, double y, double radius, double floor) const;  // max(floor, tree tops within radius)

protected:
    static void _bind_methods();

private:
    std::vector<float> h_;       // GRID*GRID, row = y index
    std::vector<float> trees_;   // N*4: x, y, base z, height
    std::vector<Field> fields_;
    Dictionary field_elev_;
    std::unordered_map<int64_t, std::vector<int>> buckets_;

    struct h_lobe { double cx, cy, rx, ry; };
    struct h_ridge { double x0, y0, x1, y1, width, height; };
    struct h_islet { double x, y, r, h; };
    void parse_fields(const Array &airfields);
    void shape_fields(std::vector<double> &h);
    void plant_trees(int64_t seed);
    void bucket_trees();
    double sample64(const std::vector<double> &h, double x, double y) const;
    double heights_many_one(double x, double y) const;
};

} // namespace godot
