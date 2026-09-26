#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>
#include <vector>

namespace JSBSim {
class FGFDMExec;
}
class SGPropertyNode;

namespace godot {

// One JSBSim flight dynamics model, the same object Python's jsbsim.FGFDMExec
// wraps. Properties can be read/written by name (like fdm["position/h-sl-ft"])
// or through bound handles, which skip the string lookup on hot paths.
class JSBSimFDM : public RefCounted {
    GDCLASS(JSBSimFDM, RefCounted)

public:
    JSBSimFDM();
    ~JSBSimFDM() override;

    bool setup(const String &root_dir);
    void set_debug_level(int level);
    bool load_model(const String &model);

    double get_delta_t() const;
    void set_delta_t(double dt);
    double get_sim_time() const;

    bool has_property(const String &path) const;
    double get_property(const String &path) const;
    void set_property(const String &path, double value);

    // bound handles: bind once, then get/set by index
    int bind(const String &path);
    double get_bound(int handle) const;
    void set_bound(int handle, double value);
    PackedFloat64Array get_bound_many(const PackedInt32Array &handles) const;

    bool run_ic();
    bool run();
    int run_steps(int n);

protected:
    static void _bind_methods();

private:
    std::unique_ptr<JSBSim::FGFDMExec> fdm_;
    std::vector<SGPropertyNode *> bound_;
};

} // namespace godot
