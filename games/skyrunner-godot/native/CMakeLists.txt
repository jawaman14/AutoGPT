cmake_minimum_required(VERSION 3.22)
project(skyrunner_native LANGUAGES C CXX)

# JSBSim is pinned to the version the Python game used (jsbsim==1.3.1), so the
# flight physics, and every balance number calibrated from flown runs, carry over.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# JSBSim reports bad aircraft XML by throwing, so keep exceptions on everywhere
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_PYTHON_MODULE OFF CACHE BOOL "" FORCE)
set(BUILD_JULIA_PACKAGE OFF CACHE BOOL "" FORCE)
set(BUILD_MATLAB_SFUNCTION OFF CACHE BOOL "" FORCE)

set(SKYRUNNER_JSBSIM_SRC "" CACHE PATH "Local JSBSim v1.3.1 checkout (skips the download)")
set(SKYRUNNER_GODOTCPP_SRC "" CACHE PATH "Local godot-cpp godot-4.4.1-stable checkout (skips the download)")

if(SKYRUNNER_JSBSIM_SRC)
  set(FETCHCONTENT_SOURCE_DIR_JSBSIM ${SKYRUNNER_JSBSIM_SRC})
endif()
if(SKYRUNNER_GODOTCPP_SRC)
  set(FETCHCONTENT_SOURCE_DIR_GODOT-CPP ${SKYRUNNER_GODOTCPP_SRC})
endif()

FetchContent_Declare(jsbsim
  GIT_REPOSITORY https://github.com/JSBSim-Team/jsbsim.git
  GIT_TAG v1.3.1
  GIT_SHALLOW TRUE)
FetchContent_Declare(godot-cpp
  GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
  GIT_TAG godot-4.4.1-stable
  GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(godot-cpp jsbsim)

add_library(skyrunner_native SHARED
  src/register_types.cpp
  src/jsbsim_fdm.cpp)
target_link_libraries(skyrunner_native PRIVATE godot::cpp libJSBSim)
set_target_properties(skyrunner_native PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "skyrunner_native"
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../bin
  CXX_VISIBILITY_PRESET hidden)
