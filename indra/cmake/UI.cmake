# -*- cmake -*-
include(Prebuilt)
include(FreeType)
include(ConfigurePkgConfig)

add_library( ll::uilibraries INTERFACE IMPORTED )

if (LINUX)
  # Switch Linux UI dependencies away from GTK stack to libportal + GLib.
  # Define LL_PORTAL so the viewer uses portal-backed file/dir pickers.
  target_compile_definitions(ll::uilibraries INTERFACE LL_PORTAL=1 LL_X11=1 )

  find_package(PkgConfig REQUIRED)
  pkg_check_modules(GLIB2 REQUIRED glib-2.0 gobject-2.0 gio-2.0)
  pkg_check_modules(LIBPORTAL REQUIRED libportal)

  target_include_directories( ll::uilibraries SYSTEM INTERFACE
          ${GLIB2_INCLUDE_DIRS}
          ${LIBPORTAL_INCLUDE_DIRS}
          )

  target_link_libraries( ll::uilibraries INTERFACE
          ${GLIB2_LIBRARIES}
          ${LIBPORTAL_LIBRARIES}
          Xinerama
          ll::freetype
          ll::fontconfig
          )
endif (LINUX)
if( WINDOWS )
  target_link_libraries( ll::uilibraries INTERFACE
          opengl32
          comdlg32
          dxguid
          kernel32
          odbc32
          odbccp32
          oleaut32
          shell32
          Vfw32
          wer
          winspool
          imm32
          )
endif()

target_include_directories( ll::uilibraries SYSTEM INTERFACE
        ${LIBS_PREBUILT_DIR}/include
        )
