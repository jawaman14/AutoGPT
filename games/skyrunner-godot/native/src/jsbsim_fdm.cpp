#include "jsbsim_fdm.h"

#include <FGFDMExec.h>
#include <input_output/FGPropertyManager.h>
#include <simgear/misc/sg_path.hxx>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {
std::string utf8(const String &s) { return std::string(s.utf8().get_data()); }
} // namespace

JSBSimFDM::JSBSimFDM() = default;
JSBSimFDM::~JSBSimFDM() = default;

bool JSBSimFDM::setup(const String &root_dir) {
    bound_.clear();
    fdm_ = std::make_unique<JSBSim::FGFDMExec>();
    fdm_->SetDebugLevel(0);
    // same layout the Python bindings set up for FGFDMExec(root)
    fdm_->SetRootDir(SGPath::fromUtf8(utf8(root_dir)));
    fdm_->SetOutputPath(SGPath("."));
    fdm_->SetEnginePath(SGPath("engine"));
    fdm_->SetAircraftPath(SGPath("aircraft"));
    fdm_->SetSystemsPath(SGPath("systems"));
    return true;
}

void JSBSimFDM::set_debug_level(int level) {
    if (fdm_) fdm_->SetDebugLevel(level);
}

bool JSBSimFDM::load_model(const String &model) {
    if (!fdm_) return false;
    try {
        return fdm_->LoadModel(utf8(model));
    } catch (const std::exception &e) {
        UtilityFunctions::push_error("JSBSim LoadModel failed: ", e.what());
        return false;
    }
}

double JSBSimFDM::get_delta_t() const { return fdm_ ? fdm_->GetDeltaT() : 0.0; }
void JSBSimFDM::set_delta_t(double dt) {
    if (fdm_) fdm_->Setdt(dt);
}
double JSBSimFDM::get_sim_time() const { return fdm_ ? fdm_->GetSimTime() : 0.0; }

bool JSBSimFDM::has_property(const String &path) const {
    return fdm_ && fdm_->GetPropertyManager()->HasNode(utf8(path));
}

double JSBSimFDM::get_property(const String &path) const {
    return fdm_ ? fdm_->GetPropertyValue(utf8(path)) : 0.0;
}

void JSBSimFDM::set_property(const String &path, double value) {
    if (fdm_) fdm_->SetPropertyValue(utf8(path), value);
}

int JSBSimFDM::bind(const String &path) {
    if (!fdm_) return -1;
    SGPropertyNode *node = fdm_->GetPropertyManager()->GetNode(utf8(path), true);
    if (!node) return -1;
    bound_.push_back(node);
    return static_cast<int>(bound_.size()) - 1;
}

double JSBSimFDM::get_bound(int handle) const {
    if (handle < 0 || handle >= static_cast<int>(bound_.size())) return 0.0;
    return bound_[handle]->getDoubleValue();
}

void JSBSimFDM::set_bound(int handle, double value) {
    if (handle < 0 || handle >= static_cast<int>(bound_.size())) return;
    bound_[handle]->setDoubleValue(value);
}

PackedFloat64Array JSBSimFDM::get_bound_many(const PackedInt32Array &handles) const {
    PackedFloat64Array out;
    out.resize(handles.size());
    for (int i = 0; i < handles.size(); ++i) out.set(i, get_bound(handles[i]));
    return out;
}

bool JSBSimFDM::run_ic() {
    if (!fdm_) return false;
    try {
        return fdm_->RunIC();
    } catch (const std::exception &e) {
        UtilityFunctions::push_error("JSBSim RunIC failed: ", e.what());
        return false;
    }
}

bool JSBSimFDM::run() { return fdm_ && fdm_->Run(); }

int JSBSimFDM::run_steps(int n) {
    int done = 0;
    while (done < n && run()) ++done;
    return done;
}

void JSBSimFDM::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "root_dir"), &JSBSimFDM::setup);
    ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &JSBSimFDM::set_debug_level);
    ClassDB::bind_method(D_METHOD("load_model", "model"), &JSBSimFDM::load_model);
    ClassDB::bind_method(D_METHOD("get_delta_t"), &JSBSimFDM::get_delta_t);
    ClassDB::bind_method(D_METHOD("set_delta_t", "dt"), &JSBSimFDM::set_delta_t);
    ClassDB::bind_method(D_METHOD("get_sim_time"), &JSBSimFDM::get_sim_time);
    ClassDB::bind_method(D_METHOD("has_property", "path"), &JSBSimFDM::has_property);
    ClassDB::bind_method(D_METHOD("get_property", "path"), &JSBSimFDM::get_property);
    ClassDB::bind_method(D_METHOD("set_property", "path", "value"), &JSBSimFDM::set_property);
    ClassDB::bind_method(D_METHOD("bind", "path"), &JSBSimFDM::bind);
    ClassDB::bind_method(D_METHOD("get_bound", "handle"), &JSBSimFDM::get_bound);
    ClassDB::bind_method(D_METHOD("set_bound", "handle", "value"), &JSBSimFDM::set_bound);
    ClassDB::bind_method(D_METHOD("get_bound_many", "handles"), &JSBSimFDM::get_bound_many);
    ClassDB::bind_method(D_METHOD("run_ic"), &JSBSimFDM::run_ic);
    ClassDB::bind_method(D_METHOD("run"), &JSBSimFDM::run);
    ClassDB::bind_method(D_METHOD("run_steps", "n"), &JSBSimFDM::run_steps);
}
