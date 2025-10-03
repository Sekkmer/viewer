# -*- cmake -*-
use_prebuilt_binary(cubemaptoequirectangular)

set(_cubemap_src "${AUTOBUILD_INSTALL_DIR}/js/CubemapToEquirectangular.js")
set(_cubemap_dst "${CMAKE_SOURCE_DIR}/newview/skins/default/html/common/equirectangular/js/CubemapToEquirectangular.js")

if(EXISTS "${_cubemap_src}")
  # Main JS file provided by the prebuilt package
  configure_file("${_cubemap_src}" "${_cubemap_dst}" COPYONLY)
else()
  message(WARNING "CubemapToEquirectangular.js not found in ${_cubemap_src}; generating a stub so the build can continue.")
  file(WRITE "${_cubemap_dst}" "// Stub generated at configure time because CubemapToEquirectangular.js was unavailable.\n")
endif()
