cmake_minimum_required(VERSION 3.22)
project(XeneonEdgeLinuxHub VERSION 1.0.0 LANGUAGES CXX)

# --- Build version string (git-derived, overridable) ---
# A checkout derives a distinguishing string from Git. A `git archive` source
# release has no `.git`, so `.git_archival.txt` carries Git's export-substituted
# describe value. Packagers may still provide an explicit authoritative
# XENEON_VERSION_OVERRIDE.
find_package(Git QUIET)
if(DEFINED XENEON_VERSION_OVERRIDE AND XENEON_VERSION_OVERRIDE)
    set(XENEON_GIT_VERSION "${XENEON_VERSION_OVERRIDE}")
elseif(Git_FOUND)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" -C "${CMAKE_SOURCE_DIR}"
                describe --tags --always --dirty
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        OUTPUT_VARIABLE XENEON_GIT_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
endif()
if(NOT XENEON_GIT_VERSION
   AND EXISTS "${CMAKE_SOURCE_DIR}/.git_archival.txt")
    file(STRINGS "${CMAKE_SOURCE_DIR}/.git_archival.txt"
         _xeneon_archive_describe
         REGEX "^describe-name:[ \t]*")
    list(LENGTH _xeneon_archive_describe _xeneon_archive_describe_count)
    if(_xeneon_archive_describe_count EQUAL 1)
        list(GET _xeneon_archive_describe 0 XENEON_GIT_VERSION)
        string(REGEX REPLACE "^describe-name:[ \t]*" ""
               XENEON_GIT_VERSION "${XENEON_GIT_VERSION}")
        if(XENEON_GIT_VERSION MATCHES "\\$Format:")
            set(XENEON_GIT_VERSION "")
        endif()
    endif()
endif()
if(NOT XENEON_GIT_VERSION)
    set(XENEON_GIT_VERSION "${PROJECT_VERSION}")
endif()
# Tags use the conventional leading "v", while application, AppImage, DEB,
# RPM, TGZ and Arch package versions do not. Canonicalize once before the value
# reaches either binary or any packaging generator so format-specific build
# paths cannot disagree about the visible application identity.
string(REGEX REPLACE "^v" "" XENEON_GIT_VERSION "${XENEON_GIT_VERSION}")
message(STATUS "Xeneon configure/package version: ${XENEON_GIT_VERSION}")

# Build-time identity must follow more than HEAD. A tracked-file edit changes
# `git describe --dirty` without touching a ref, and linked worktrees expose
# `.git` as a pointer file rather than a directory. Run the canonical Git query
# before every product build and generate a header through copy_if_different.
# The target is always evaluated, while the header timestamp changes only when
# its content changes, so normal compiler dependency tracking does the minimum
# required rebuild.
set(XENEON_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(XENEON_BUILD_VERSION_HEADER
    "${XENEON_GENERATED_DIR}/xeneon_build_version.generated.h")
set(_xeneon_version_command
    "${CMAKE_COMMAND}"
    "-DXENEON_SOURCE_DIR=${CMAKE_SOURCE_DIR}"
    "-DXENEON_OUTPUT_FILE=${XENEON_BUILD_VERSION_HEADER}"
    "-DXENEON_FALLBACK_VERSION=${XENEON_GIT_VERSION}")
if(DEFINED XENEON_VERSION_OVERRIDE AND XENEON_VERSION_OVERRIDE)
    list(APPEND _xeneon_version_command
         "-DXENEON_VERSION_OVERRIDE=${XENEON_VERSION_OVERRIDE}")
elseif(Git_FOUND)
    list(APPEND _xeneon_version_command
         "-DXENEON_GIT_EXECUTABLE=${GIT_EXECUTABLE}")
endif()
list(APPEND _xeneon_version_command
     -P "${CMAKE_SOURCE_DIR}/cmake/GenerateBuildVersion.cmake")
add_custom_target(xeneon_build_version ALL
    COMMAND ${_xeneon_version_command}
    BYPRODUCTS "${XENEON_BUILD_VERSION_HEADER}"
    COMMENT "Refreshing exact EdgeHub build identity"
    VERBATIM)
set_source_files_properties("${XENEON_BUILD_VERSION_HEADER}" PROPERTIES
    GENERATED TRUE
    HEADER_FILE_ONLY TRUE)

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
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui Quick Qml DBus Network Svg QuickControls2)

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
    COMMAND ${CARGO_EXECUTABLE} build --locked ${CARGO_BUILD_FLAG} --manifest-path "${RUST_CORE_DIR}/Cargo.toml"
    WORKING_DIRECTORY "${RUST_CORE_DIR}"
    DEPENDS
        ${RUST_SOURCES}
        "${RUST_CORE_DIR}/Cargo.toml"
        "${RUST_CORE_DIR}/Cargo.lock"
    COMMENT "Building Rust core library..."
    USES_TERMINAL
)

add_custom_target(rust_core ALL DEPENDS ${RUST_LIB})

# --- Build C++ Application ---
add_executable(xeneon-edge-hub
    app/src/main.cpp
    app/src/build_version.h
    app/src/mpris_bridge.cpp
    app/src/mpris_state.cpp
    app/src/control_server.cpp
    app/src/control_protocol.h
    app/src/orientation_sensor.cpp
    app/src/autostart.cpp
    app/src/display_match.cpp
    app/src/config_bridge.h
    app/src/config_transaction.h
    app/src/ui_state_recovery.h
    app/src/license_bridge.h
    app/src/metrics_worker.h
    app/src/timezone_bridge.h
    app/src/distro_bridge.h
    app/src/system_settings_probe.h
    app/src/network_access_policy.h
    app/src/notification_bridge.h
    app/src/safe_mode_policy.h
    "${XENEON_BUILD_VERSION_HEADER}"
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
    ${RUST_LIB}
    pthread
    dl
)

# Include directories
target_include_directories(xeneon-edge-hub PRIVATE
    "${CMAKE_SOURCE_DIR}/core"
    "${XENEON_GENERATED_DIR}"
)

# Add dependency on Rust build
add_dependencies(xeneon-edge-hub rust_core xeneon_build_version)

# QML import path
target_compile_definitions(xeneon-edge-hub PRIVATE
    QT_DISABLE_DEPRECATED_BEFORE=0x060500
    XENEON_USE_GENERATED_BUILD_VERSION=1
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
    app/src/build_version.h
    app/src/autostart.cpp
    app/src/config_transaction.h
    app/src/ui_state_recovery.h
    app/src/timezone_bridge.h
    app/src/distro_bridge.h
    app/src/system_settings_probe.h
    app/src/network_access_policy.h
    "${XENEON_BUILD_VERSION_HEADER}"
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
    "${XENEON_GENERATED_DIR}"
)

add_dependencies(xeneon-edge-manager rust_core xeneon_build_version)

target_compile_definitions(xeneon-edge-manager PRIVATE
    QT_DISABLE_DEPRECATED_BEFORE=0x060500
    XENEON_USE_GENERATED_BUILD_VERSION=1
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
    find_package(Qt6 6.9 REQUIRED COMPONENTS Test QuickTest)
    add_subdirectory(tests/cpp)

    # Resource-aware qmltestrunner replacement for tests/gui.  Linking the
    # shipped QRC bundles is essential: the stock Qt runner cannot resolve
    # qrc:/icons or qrc:/wallpapers, making rendered-pixel assertions vacuous.
    add_executable(xeneon-qmltestrunner
        tests/gui/runner.cpp
        app/src/network_access_policy.h
        ${CMAKE_SOURCE_DIR}/assets/icons.qrc
        ${CMAKE_SOURCE_DIR}/assets/wallpapers.qrc
        ${CMAKE_SOURCE_DIR}/assets/fonts.qrc
        ${CMAKE_SOURCE_DIR}/ui/qml.qrc
        ${CMAKE_SOURCE_DIR}/manager/manager.qrc)
    target_include_directories(xeneon-qmltestrunner PRIVATE
        ${CMAKE_SOURCE_DIR}/app/src)
    target_link_libraries(xeneon-qmltestrunner PRIVATE
        Qt6::QuickTest Qt6::Quick Qt6::Qml Qt6::Network)
    target_compile_definitions(xeneon-qmltestrunner PRIVATE
        QUICK_TEST_SOURCE_DIR="${CMAKE_SOURCE_DIR}/tests/gui")
endif()

# Install
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
        packaging/THIRD_PARTY_NOTICES-RUST.txt
        assets/icons/LICENSE-MIT-PhosphorIcons.txt
        assets/fonts/LICENSE-OFL-AtkinsonHyperlegible.txt
        assets/fonts/LICENSE-OFL-ChakraPetch.txt
        assets/fonts/LICENSE-OFL-Inter.txt
        assets/fonts/LICENSE-OFL-JetBrainsMono.txt
        assets/fonts/LICENSE-OFL-Lexend.txt
        DESTINATION share/licenses/xeneon-edge-hub)
# Debian Policy expects the installed package copyright record at this exact
# location. It is useful in every native payload, so install the same
# machine-readable record for RPM and TGZ instead of maintaining divergent
# generator-only copies.
install(FILES packaging/debian/copyright
        DESTINATION share/doc/xeneon-edge-hub)

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
    # Bind every package to the same canonical identity as both binaries.
    # XENEON_GIT_VERSION already falls back to PROJECT_VERSION when Git is not
    # available, so a normal committed checkout needs no package-only override.
    # This makes the lifecycle test exercise CMake's real derivation path.
    set(XENEON_CPACK_VERSION "${XENEON_GIT_VERSION}")

    # Debian and RPM use '~' for a prerelease that sorts before the corresponding
    # final version. A literal SemVer hyphen has the wrong package-manager order
    # and is not valid in an RPM Version. Git describe adds more hyphens for its
    # commit count and hash, so normalize those to dots as well. Archive
    # filenames and the embedded application version retain the canonical
    # Git-derived spelling, without the tag-only leading "v".
    set(XENEON_NATIVE_PACKAGE_VERSION "${XENEON_CPACK_VERSION}")
    # A commit after a final tag is newer than that final (`1.0.0+3.gabc`);
    # a prerelease tag is older than the final (`1.0.0~rc.1`). Test the
    # unambiguous git-count form first so post-final development never looks like
    # a downgrade.
    if(XENEON_CPACK_VERSION MATCHES
       "^([0-9]+\\.[0-9]+\\.[0-9]+)-([0-9]+)-g([0-9A-Fa-f]+)(-dirty)?$")
        set(XENEON_NATIVE_PACKAGE_VERSION
            "${CMAKE_MATCH_1}+${CMAKE_MATCH_2}.g${CMAKE_MATCH_3}")
        if(CMAKE_MATCH_4)
            string(APPEND XENEON_NATIVE_PACKAGE_VERSION ".dirty")
        endif()
    elseif(XENEON_CPACK_VERSION MATCHES
           "^([0-9]+\\.[0-9]+\\.[0-9]+)-(.+)$")
        set(_xeneon_native_suffix "${CMAKE_MATCH_2}")
        string(REPLACE "-" "." _xeneon_native_suffix
               "${_xeneon_native_suffix}")
        set(XENEON_NATIVE_PACKAGE_VERSION
            "${CMAKE_MATCH_1}~${_xeneon_native_suffix}")
    endif()

    set(CPACK_PACKAGE_NAME "xeneon-edge-hub")
    set(CPACK_PACKAGE_VENDOR "SKYPhoenix IT")
    set(CPACK_PACKAGE_CONTACT "Simon Kreitmayer <simon.kreitmayer@skyphoenix-it.com>")
    set(CPACK_PACKAGE_VERSION "${XENEON_CPACK_VERSION}")
    if(XENEON_CPACK_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
        set(CPACK_PACKAGE_VERSION_MAJOR "${CMAKE_MATCH_1}")
        set(CPACK_PACKAGE_VERSION_MINOR "${CMAKE_MATCH_2}")
        set(CPACK_PACKAGE_VERSION_PATCH "${CMAKE_MATCH_3}")
    endif()
    set(CPACK_XENEON_NATIVE_PACKAGE_VERSION "${XENEON_NATIVE_PACKAGE_VERSION}")
    # CI carries these two configure-time facts beside the package artifact and
    # checks both installed package metadata and both binaries against them.
    # Plain one-line files avoid sourcing tag-derived text as shell code.
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/xeneon-app-version.txt"
         "${XENEON_GIT_VERSION}\n")
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/xeneon-native-package-version.txt"
         "${XENEON_NATIVE_PACKAGE_VERSION}\n")
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
    set(CPACK_DEBIAN_PACKAGE_VERSION "${XENEON_NATIVE_PACKAGE_VERSION}")
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
qml6-module-qtqml-workerscript")
    set(CPACK_DEBIAN_FILE_NAME "DEB-DEFAULT")

    # Fedora/openSUSE
    set(CPACK_RPM_PACKAGE_LICENSE
        "(MIT OR Apache-2.0) AND MIT AND OFL-1.1 AND BSD-3-Clause AND MPL-2.0 AND Unicode-3.0")
    set(CPACK_RPM_PACKAGE_VERSION "${XENEON_NATIVE_PACKAGE_VERSION}")
    set(CPACK_RPM_PACKAGE_GROUP "Applications/System")
    set(CPACK_RPM_PACKAGE_REQUIRES
        "qt6-qtbase >= 6.9, qt6-qtdeclarative, qt6-qtsvg, qt6-qtwayland")
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
