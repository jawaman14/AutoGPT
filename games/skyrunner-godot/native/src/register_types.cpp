#include "jsbsim_fdm.h"
#include "rng.h"
#include "terrain.h"
#include "pymath.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_skyrunner(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    GDREGISTER_CLASS(JSBSimFDM);
    GDREGISTER_CLASS(PyRandom);
    GDREGISTER_CLASS(NpRandom);
    GDREGISTER_CLASS(Terrain);
    GDREGISTER_CLASS(PyMath);
}

static void uninitialize_skyrunner(ModuleInitializationLevel level) {}

extern "C" {
GDExtensionBool GDE_EXPORT skyrunner_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                  const GDExtensionClassLibraryPtr library,
                                                  GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
    init_obj.register_initializer(initialize_skyrunner);
    init_obj.register_terminator(uninitialize_skyrunner);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
