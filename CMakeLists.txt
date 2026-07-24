cmake_minimum_required(VERSION 3.22)
project(XeneonEdgeLinuxHub VERSION 0.1.0 LANGUAGES CXX)

# --- Build version string (git-derived, overridable) ---
# project VERSION stays 0.1.0 across commits, so derive a distinguishing string
# from git (e.g. "5c3baec" / "v0.1.0-37-g5c3baec-dirty"). Packaged builds have no
# .git, so the PKGBUILD passes -DXENEON_VERSION_OVERRIDE=<pkgver>.
if(DEFINED XENEON_VERSION_OVERRIDE AND XENEON_VERSION_OVERRIDE)
    set(XENEON_GIT_VERSION "${XENEON_VERSION_OVERRIDE}")
else()
    execute_process(
        COMMAND git describe --tags --always --dirty
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        OUTPUT_VARIABLE XENEON_GIT_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
endif()
if(NOT XENEON_GIT_VERSION)
    set(XENEON_GIT_VERSION "${PROJECT_VERSION}")
endif()
message(STATUS "Xeneon build version: ${XENEON_GIT_VERSION}")

# Re-run `git describe` on every BUILD, not only on configure.
#
# execute_process() above runs at CONFIGURE time, so `cmake --build` alone bakes
# in whatever the version was when the build dir was last configured. Every
# incremental dev build therefore reported a stale version - the exact confusion
# that had a test run reporting r190 while r200 was installed. This target makes
# a reconfigure happen whenever HEAD moves, so the version tracks the tree.
if(NOT (DEFINED XENEON_VERSION_OVERRIDE AND XENEON_VERSION_OVERRIDE))
    find_package(Git QUIET)
    if(GIT_FOUND AND EXISTS "${CMAKE_SOURCE_DIR}/.git")
        # Touching CMakeLists when HEAD changes forces CMake to re-run its own
        # configure step, which re-evaluates git describe. Cheap, and it uses
        # CMake's normal dependency machinery instead of a second version path
        # that could disagree with the first.
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
                     "${CMAKE_SOURCE_DIR}/.git/HEAD")
        if(EXISTS "${CMAKE_SOURCE_DIR}/.git/refs/heads")
            file(GLOB _xe_heads "${CMAKE_SOURCE_DIR}/.git/refs/heads/*")
            foreach(_h ${_xe_heads})
                set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_h}")
            endforeach()
        endif()
    endif()
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Default to an optimized Release build unless the user overrides it.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
    message(STATUS "No build type specified - defaulting to Release")
endif()

# Enable Link-Time Optimization for Release builds when supported.
include(CheckIPOSupported)
check_ipo_supported(RESULT IPO_SUPPORTED OUTPUT IPO_ERROR)

# --- Test / coverage options ---
# OFF by default so a normal `cmake --build` stays a pure product build. Turn on
# with -DXENEON_BUILD_TESTS=ON (adds the QtTest C++ suite under tests/cpp) and
# optionally -DXENEON_COVERAGE=ON (compiles the tested logic + test exes with
# --coverage for gcov/gcovr line coverage).
option(XENEON_BUILD_TESTS "Build the C++ (QtTest) test suite" OFF)
option(XENEON_COVERAGE "Instrument tested C++ for gcov/gcovr coverage" OFF)
# QA automation hooks (XENEON_GRAB screenshot capture, XENEON_EXPAND/XENEON_CFG/
# XENEON_TAB auto-open, single-instance bypass). OFF by default so production
# packages ship without the screenshot/automation surface; turn ON for CI, the
# test/E2E suites, and marketing-capture builds (scripts/build.sh enables it).
option(XENEON_QA_HOOKS "Compile in the XENEON_GRAB/EXPAND QA automation hooks" OFF)

# Find Qt6
find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick Qml DBus VirtualKeyboard Network Svg QuickControls2)

# --- Build Rust Core Library ---

# Detect cargo
find_program(CARGO_EXECUTABLE cargo REQUIRED)
message(STATUS "Found cargo: ${CARGO_EXECUTABLE}")

# Determine rust target dir
set(RUST_CORE_DIR "${CMAKE_SOURCE_DIR}/core")
set(RUST_TARGET_DIR "${RUST_CORE_DIR}/target")
set(RUST_BUILD_TYPE "$<IF:$<CONFIG:Debug>,debug,release>")

if(CMAKE_BUILD_TYPE MATCHES "Debug")
    set(CARGO_BUILD_FLAG "")
    set(RUST_LIB_DIR "${RUST_TARGET_DIR}/debug")
else()
    set(CARGO_BUILD_FLAG "--release")
    set(RUST_LIB_DIR "${RUST_TARGET_DIR}/release")
endif()

set(RUST_LIB "${RUST_LIB_DIR}/libxeneon_core.a")

# Track Rust sources so the static library is rebuilt whenever they change.
# Without this, add_custom_command has no source dependencies and would link a
# stale libxeneon_core.a after edits to the Rust core.
file(GLOB_RECURSE RUST_SOURCES CONFIGURE_DEPENDS "${RUST_CORE_DIR}/src/*.rs")

# Custom command to build the rust library
add_custom_command(
    OUTPUT ${RUST_LIB}
    COMMAND ${CARGO_EXECUTABLE} build ${CARGO_BUILD_FLAG} --manifest-path "${RUST_CORE_DIR}/Cargo.toml"
    WORKING_DIRECTORY "${RUST_CORE_DIR}"
    DEPENDS ${RUST_SOURCES} "${RUST_CORE_DIR}/Cargo.toml"
    COMMENT "Building Rust core library..."
    USES_TERMINAL
)

add_custom_target(rust_core ALL DEPENDS ${RUST_LIB})

# --- Build C++ Application ---
add_executable(xeneon-edge-hub
    app/src/main.cpp
    app/src/mpris_bridge.cpp
    app/src/mpris_state.cpp
    app/src/control_server.cpp
    app/src/orientation_sensor.cpp
    app/src/autostart.cpp
    app/src/display_match.cpp
    app/src/config_bridge.h
    app/src/license_bridge.h
    app/src/metrics_worker.h
    app/src/timezone_bridge.h
    app/src/distro_bridge.h
    app/src/system_settings_probe.h
    app/src/network_access_policy.h
    app/src/notification_bridge.h
    ${CMAKE_SOURCE_DIR}/ui/qml.qrc
    ${CMAKE_SOURCE_DIR}/assets/icons.qrc
    ${CMAKE_SOURCE_DIR}/assets/wallpapers.qrc
    ${CMAKE_SOURCE_DIR}/assets/fonts.qrc
)

# Link against the Rust static library
target_link_libraries(xeneon-edge-hub PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    Qt6::DBus
    Qt6::Network
    Qt6::Svg
    Qt6::QuickControls2
    Qt6::VirtualKeyboard
    ${RUST_LIB}
    pthread
    dl
)

# Include directories
target_include_directories(xeneon-edge-hub PRIVATE
    "${CMAKE_SOURCE_DIR}/core"
)

# Add dependency on Rust build
add_dependencies(xeneon-edge-hub rust_core)

# QML import path
target_compile_definitions(xeneon-edge-hub PRIVATE
    QT_DISABLE_DEPRECATED_BEFORE=0x060500
)

# Release optimizations: LTO + aggressive optimization + stripped symbols.
if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    if(IPO_SUPPORTED)
        set_target_properties(xeneon-edge-hub PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
        message(STATUS "LTO enabled for xeneon-edge-hub")
    else()
        message(STATUS "LTO not supported: ${IPO_ERROR}")
    endif()
    target_compile_options(xeneon-edge-hub PRIVATE -O3)
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Release")
    # Strip symbols from the final Release binary to reduce size.
    target_link_options(xeneon-edge-hub PRIVATE -s)
endif()

# --- Companion: Xeneon Edge Manager ---
# Standalone desktop app to manage the hub (layout, appearance, images, display).
# Reuses the Rust core + shared QML store/registry; talks to a running hub over a
# local socket for live updates.
add_executable(xeneon-edge-manager
    manager/src/main.cpp
    manager/src/reconcile.cpp
    manager/src/manager_backend.h
    app/src/timezone_bridge.h
    app/src/distro_bridge.h
    app/src/system_settings_probe.h
    app/src/network_access_policy.h
    ${CMAKE_SOURCE_DIR}/manager/manager.qrc
    ${CMAKE_SOURCE_DIR}/assets/icons.qrc
    ${CMAKE_SOURCE_DIR}/assets/wallpapers.qrc
    ${CMAKE_SOURCE_DIR}/assets/fonts.qrc
)

target_link_libraries(xeneon-edge-manager PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    # DBus: the Manager registers the same SystemSettingsProbe (XDG settings
    # portal reduce-motion read) as the hub, so its previews match the device.
    Qt6::DBus
    Qt6::Network
    Qt6::Svg
    Qt6::QuickControls2
    ${RUST_LIB}
    pthread
    dl
)

target_include_directories(xeneon-edge-manager PRIVATE
    "${CMAKE_SOURCE_DIR}/core"
)

add_dependencies(xeneon-edge-manager rust_core)

target_compile_definitions(xeneon-edge-manager PRIVATE
    QT_DISABLE_DEPRECATED_BEFORE=0x060500
)

if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    if(IPO_SUPPORTED)
        set_target_properties(xeneon-edge-manager PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
    endif()
    target_compile_options(xeneon-edge-manager PRIVATE -O3)
endif()

# --- C++ tests (QtTest) ---
# Opt-in: -DXENEON_BUILD_TESTS=ON. Adds per-test executables + ctest registration
# under tests/cpp. They link the REAL libxeneon_core.a (no fake) against a per-test
# temp XDG_CONFIG_HOME so config round-trips are hermetic.
if(XENEON_BUILD_TESTS)
    enable_testing()
    find_package(Qt6 6.5 REQUIRED COMPONENTS Test QuickTest)
    add_subdirectory(tests/cpp)

    # Resource-aware qmltestrunner replacement for tests/gui.  Linking the
    # shipped QRC bundles is essential: the stock Qt runner cannot resolve
    # qrc:/icons or qrc:/wallpapers, making rendered-pixel assertions vacuous.
    add_executable(xeneon-qmltestrunner
        tests/gui/runner.cpp
        ${CMAKE_SOURCE_DIR}/assets/icons.qrc
        ${CMAKE_SOURCE_DIR}/assets/wallpapers.qrc
        ${CMAKE_SOURCE_DIR}/assets/fonts.qrc)
    target_link_libraries(xeneon-qmltestrunner PRIVATE Qt6::QuickTest Qt6::Quick Qt6::Qml)
    target_compile_definitions(xeneon-qmltestrunner PRIVATE
        QUICK_TEST_SOURCE_DIR="${CMAKE_SOURCE_DIR}/tests/gui")
endif()

# Install
# Surface the build version to both apps (see ManagerBackend::appVersion /
# ConfigBridge::appVersion).
target_compile_definitions(xeneon-edge-hub PRIVATE XENEON_VERSION="${XENEON_GIT_VERSION}")
target_compile_definitions(xeneon-edge-manager PRIVATE XENEON_VERSION="${XENEON_GIT_VERSION}")

if(XENEON_QA_HOOKS)
    target_compile_definitions(xeneon-edge-hub PRIVATE XENEON_QA_HOOKS)
    target_compile_definitions(xeneon-edge-manager PRIVATE XENEON_QA_HOOKS)
    message(STATUS "EdgeHub: QA automation hooks ENABLED (not for production packages)")
endif()

install(TARGETS xeneon-edge-hub xeneon-edge-manager DESTINATION bin)

# Desktop entries + AppStream metadata (both apps).
install(FILES
    assets/xeneon-edge-hub.desktop
    assets/xeneon-edge-manager.desktop
    DESTINATION share/applications)
install(FILES
    assets/metainfo/com.skyphoenix_it.XeneonEdgeHub.metainfo.xml
    assets/metainfo/com.skyphoenix_it.XeneonEdgeManager.metainfo.xml
    DESTINATION share/metainfo)

# App icons (hicolor theme): scalable SVG source + rasterized PNG sizes.
install(FILES
    assets/icon/xeneon-edge-hub.svg
    assets/icon/xeneon-edge-manager.svg
    DESTINATION share/icons/hicolor/scalable/apps)
foreach(_sz 16 32 48 64 128 256 512)
    install(FILES
        "assets/icon/hicolor/${_sz}x${_sz}/apps/xeneon-edge-hub.png"
        "assets/icon/hicolor/${_sz}x${_sz}/apps/xeneon-edge-manager.png"
        DESTINATION "share/icons/hicolor/${_sz}x${_sz}/apps")
endforeach()

# License - including the bundled fonts' OFL texts: the OFL permits bundling in
# a sold product but REQUIRES its licence text to accompany the fonts, so a
# package that ships the TTFs without these is non-compliant.
install(FILES LICENSE LICENSE-MIT LICENSE-APACHE
        assets/fonts/LICENSE-OFL-AtkinsonHyperlegible.txt
        assets/fonts/LICENSE-OFL-Lexend.txt
        DESTINATION share/licenses/xeneon-edge-hub)

# udev rule for Edge orientation-sensor access. DESTINATION is RELATIVE to the
# install prefix (→ <prefix>/lib/udev/rules.d) so it stages correctly under CPack
# and DESTDIR. For a manual system install to a fixed location, override with an
# absolute path, e.g. -DUDEV_RULES_DIR=/etc/udev/rules.d.
set(UDEV_RULES_DIR "lib/udev/rules.d" CACHE PATH "udev rules dir (relative to prefix, or absolute)")
install(FILES packaging/udev/99-xeneon-edge.rules DESTINATION "${UDEV_RULES_DIR}" OPTIONAL)

# ─────────────────────────────────────────────────────────────────────────────
# CPack: generate distro packages from the install rules above.
#   cpack -G TGZ   (generator works anywhere; runtime dependencies still apply)
#   cpack -G DEB   (build on Debian/Ubuntu - needs dpkg for shlibdeps)
#   cpack -G RPM   (build on Fedora/openSUSE - needs rpmbuild)
# ─────────────────────────────────────────────────────────────────────────────
if(PROJECT_IS_TOP_LEVEL)
    # An explicit package override must bind the embedded appVersion and CPack
    # metadata to the same identity. Keep PROJECT_VERSION as the fallback for
    # ordinary unversioned developer builds, but never label an explicitly
    # versioned DEB/RPM/TGZ as the historical 0.1.0.
    set(XENEON_CPACK_VERSION "${PROJECT_VERSION}")
    if(DEFINED XENEON_VERSION_OVERRIDE AND XENEON_VERSION_OVERRIDE)
        string(REGEX REPLACE "^v" "" XENEON_CPACK_VERSION
               "${XENEON_VERSION_OVERRIDE}")
    endif()

    # Debian and RPM use '~' for a prerelease that sorts before the corresponding
    # final version. A literal SemVer hyphen has the wrong package-manager order
    # (and is not valid in an RPM Version), while archive filenames should retain
    # the familiar SemVer spelling.
    set(XENEON_NATIVE_PACKAGE_VERSION "${XENEON_CPACK_VERSION}")
    if(XENEON_CPACK_VERSION MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)-(.+)$")
        set(XENEON_NATIVE_PACKAGE_VERSION
            "${CMAKE_MATCH_1}~${CMAKE_MATCH_2}")
    endif()

    set(CPACK_PACKAGE_NAME "xeneon-edge-hub")
    set(CPACK_PACKAGE_VENDOR "SkyPhoenix IT")
    set(CPACK_PACKAGE_CONTACT "Simon Kreitmayer <simon.kreitmayer@skyphoenix-it.com>")
    set(CPACK_PACKAGE_VERSION "${XENEON_CPACK_VERSION}")
    if(XENEON_CPACK_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
        set(CPACK_PACKAGE_VERSION_MAJOR "${CMAKE_MATCH_1}")
        set(CPACK_PACKAGE_VERSION_MINOR "${CMAKE_MATCH_2}")
        set(CPACK_PACKAGE_VERSION_PATCH "${CMAKE_MATCH_3}")
    endif()
    set(CPACK_XENEON_NATIVE_PACKAGE_VERSION "${XENEON_NATIVE_PACKAGE_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
        "Native Linux widget dashboard for the Corsair Xeneon Edge and other secondary touchscreens")
    set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux")
    set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
    set(CPACK_PACKAGING_INSTALL_PREFIX "/usr")
    set(CPACK_STRIP_FILES ON)
    set(CPACK_PACKAGE_FILE_NAME
        "xeneon-edge-hub_${XENEON_CPACK_VERSION}_${CMAKE_SYSTEM_PROCESSOR}")

    # Debian/Ubuntu
    set(CPACK_DEBIAN_PACKAGE_SECTION "utils")
    set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)   # auto-resolve lib deps (needs dpkg-shlibdeps)
    # QML modules are dlopen'd plugins, not linked libraries, so dpkg-shlibdeps
    # cannot see them and Debian/Ubuntu ship each one as a separate qml6-module-*
    # package. Without these listed explicitly the .deb installs cleanly and then
    # dies at startup with `module "QtQuick.Controls" plugin
    # "qtquickcontrols2plugin" not found` (verified on a clean ubuntu:26.04).
    # Keep this list in sync with the `import` lines under ui/qml/ and manager/.
    # Fedora needs no equivalent: qt6-qtdeclarative bundles all of these.
    set(CPACK_DEBIAN_PACKAGE_DEPENDS
        "libqt6svg6, qt6-wayland, \
qml6-module-qtcore, \
qml6-module-qtquick, \
qml6-module-qtquick-controls, \
qml6-module-qtquick-dialogs, \
qml6-module-qtquick-effects, \
qml6-module-qtquick-layouts, \
qml6-module-qtquick-shapes, \
qml6-module-qtquick-window, \
qml6-module-qtqml-workerscript, \
qml6-module-qtquick-virtualkeyboard | qt6-virtualkeyboard")
    set(CPACK_DEBIAN_FILE_NAME "DEB-DEFAULT")

    # Fedora/openSUSE
    set(CPACK_RPM_PACKAGE_LICENSE "MIT OR Apache-2.0")
    set(CPACK_RPM_PACKAGE_GROUP "Applications/System")
    set(CPACK_RPM_PACKAGE_REQUIRES
        "qt6-qtbase >= 6.5, qt6-qtdeclarative, qt6-qtsvg, qt6-qtvirtualkeyboard, qt6-qtwayland")
    set(CPACK_RPM_FILE_NAME "RPM-DEFAULT")

    # Per-generator tooling checks run at *cpack* time, after -G has selected
    # DEB/RPM/TGZ. In particular, CPack's DEB generator otherwise exits 0 on a
    # non-Debian host with no dpkg tools while emitting an empty Architecture
    # field and silently omitting all dpkg-shlibdeps dependencies.
    configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/packaging/cpack/generator-preflight.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/xeneon-cpack-generator-preflight.cmake"
        COPYONLY)
    set(CPACK_PROJECT_CONFIG_FILE
        "${CMAKE_CURRENT_BINARY_DIR}/xeneon-cpack-generator-preflight.cmake")

    # Default to a portable tarball; DEB/RPM are opt-in via `cpack -G`.
    set(CPACK_GENERATOR "TGZ")
    include(CPack)
endif()
