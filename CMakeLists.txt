cmake_minimum_required(VERSION 3.20)
project(yap C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# ---- ggml / backend configuration -------------------------------------------
# These MUST be set before either add_subdirectory below, because whichever
# project is added first is the one that creates the single shared `ggml` target.
set(BUILD_SHARED_LIBS        OFF CACHE BOOL "" FORCE)  # defaults ON on macOS
set(GGML_METAL               ON  CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)  # else runtime metallib lookup is CWD-relative
set(GGML_BACKEND_DL          OFF CACHE BOOL "" FORCE)  # globbing .so next to the binary fights bundling

# ---- llama.cpp FIRST: its ggml is the newer of the two ----------------------
set(LLAMA_BUILD_COMMON   OFF CACHE BOOL "" FORCE)  # not an exported target; we hand-build prompts
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI       OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL        OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/llama.cpp EXCLUDE_FROM_ALL)

# ---- whisper.cpp SECOND: its `if (NOT TARGET ggml)` guard reuses the above --
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2           OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/whisper.cpp EXCLUDE_FROM_ALL)

# Fail loudly if the shared-ggml assumption ever breaks.
get_target_property(_ggml_src ggml SOURCE_DIR)
message(STATUS "yap: single shared ggml target provided by ${_ggml_src}")

# ---- smoke test: both engines in ONE process -------------------------------
add_executable(yap-smoke src/smoke.cpp)
target_link_libraries(yap-smoke PRIVATE llama parakeet)

# ---- the app ---------------------------------------------------------------
add_executable(yap
  src/main.mm
  src/app.mm
  src/statusitem.mm
  src/permissions.mm
  src/hotkey.mm
  src/audio.mm
  src/state.cpp
  src/wav.cpp
)
target_include_directories(yap PRIVATE src)
# ARC for the ObjC++ sources. CoreFoundation objects are outside ARC either way,
# so CFRelease still has to be deliberate.
target_compile_options(yap PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(yap PRIVATE
  llama
  parakeet
  "-framework Cocoa"                # NSApplication, NSStatusItem, NSPasteboard
  "-framework ApplicationServices"  # CGEventTap, AXUIElement
  "-framework Carbon"               # IsSecureEventInputEnabled, kVK_* keycodes
  "-framework AVFoundation"         # AVAudioEngine, AVCaptureDevice
  "-framework CoreAudio"
  "-framework AudioToolbox"       # AudioUnitSetProperty (input device pinning)
  "-framework ServiceManagement"    # SMAppService (launch at login)
)

# ---- tests ------------------------------------------------------------------
enable_testing()
add_executable(test-ringbuffer tests/test_ringbuffer.cpp)
target_include_directories(test-ringbuffer PRIVATE src)
add_test(NAME ringbuffer COMMAND test-ringbuffer)
