# -*- cmake -*-

include_guard()

include(Linking)
include(Prebuilt)

if(TARGET ll::SDL3)
  return()
endif()

add_library(ll::SDL3 INTERFACE IMPORTED)

target_compile_definitions(ll::SDL3 INTERFACE LL_SDL_WINDOW=1)

find_package(SDL3 CONFIG QUIET)
set(_ll_sdl3_using_system OFF)

if(SDL3_FOUND)
  target_link_libraries(ll::SDL3 INTERFACE SDL3::SDL3)
  set(_ll_sdl3_using_system ON)
else()
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(PC_SDL3 QUIET sdl3)
    if(PC_SDL3_FOUND)
      target_include_directories(ll::SDL3 SYSTEM INTERFACE ${PC_SDL3_INCLUDE_DIRS})
      target_link_directories(ll::SDL3 INTERFACE ${PC_SDL3_LIBRARY_DIRS})
      target_link_libraries(ll::SDL3 INTERFACE ${PC_SDL3_LIBRARIES})
      target_compile_options(ll::SDL3 INTERFACE ${PC_SDL3_CFLAGS_OTHER})
      set(_ll_sdl3_using_system ON)
    endif()
  endif()
endif()

if(NOT _ll_sdl3_using_system)
  use_prebuilt_binary(SDL3)

  find_library(SDL3_LIBRARY
    NAMES SDL3 SDL3.lib libSDL3.so libSDL3.dylib
    PATHS "${LIBS_PREBUILT_DIR}/lib/release" REQUIRED)

  target_link_libraries(ll::SDL3 INTERFACE ${SDL3_LIBRARY})
  target_include_directories(ll::SDL3 SYSTEM INTERFACE "${LIBS_PREBUILT_DIR}/include/")
endif()


