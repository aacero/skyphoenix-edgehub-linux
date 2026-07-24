# C++ (QtTest) test suite for the hub + manager.
#
# Each test is a standalone executable that links the REAL libxeneon_core.a (the
# same static lib the products link - no fake) and the specific extracted logic
# TUs it exercises. Tests run offscreen with a per-test temp XDG_CONFIG_HOME /
# XDG_RUNTIME_DIR so the Rust config round-trips are hermetic, and tests/cpp/
# hermetic.h makes every test REFUSE to start unless it is actually in one of
# those sandboxes (a raw `./tests/cpp/<test>` run once ate a developer's real
# config - see that header).
#
# The IPC socket IS hermetic, and the per-test XDG_RUNTIME_DIR below is what makes
# it so: both ends resolve the socket through app/src/control_socket_path.h, which
# returns $XDG_RUNTIME_DIR/xeneon-edge-hub-ctl. Until that landed, the socket was a
# bare QLocalServer name, which Qt resolves via QDir::tempPath() - so control_server,
# manager_backend_sync and rx_cap bound, and removeServer()'d, the REAL shared
# /tmp/xeneon-edge-hub-ctl, unlinking a live hub's socket (it keeps its listening fd
# and logs nothing, so it looks healthy while no client can reach it again). If you
# add a test that touches the socket, resolve the path through that header - never
# name it literally. tst_control_server.cpp's socketIsConfinedToRuntimeDir and
# startDoesNotTouchSharedTmpSocket guard this.

set(APP_SRC "${CMAKE_SOURCE_DIR}/app/src")
set(MGR_SRC "${CMAKE_SOURCE_DIR}/manager/src")

# Where each test's XDG_RUNTIME_DIR goes. NOT the build tree, unlike its HOME /
# XDG_CONFIG_HOME: a Unix socket path must fit sockaddr_un::sun_path (108 bytes
# incl. NUL), and "<build>/tests/cpp/tmp/<test>/run/xeneon-edge-hub-ctl" busts
# that on any normally-nested checkout - listen() then fails with the famously
# unhelpful "QLocalServer::listen: Name error". So runtime dirs live in a short
# temp path instead. This is NOT a return to the old shared /tmp socket: each
# test gets its OWN directory, keyed by a hash of this build dir (so parallel
# checkouts and other users never collide), and nothing binds the shared name.
# hermetic.h accepts a temp-rooted sandbox - mirror its $TMPDIR-else-/tmp rule
# here, or the gate would reject what we hand out.
if(DEFINED ENV{TMPDIR})
    set(_tmp_root "$ENV{TMPDIR}")
else()
    set(_tmp_root "/tmp")
endif()
string(MD5 _build_hash "${CMAKE_CURRENT_BINARY_DIR}")
string(SUBSTRING "${_build_hash}" 0 8 _build_hash)
set(SOCK_ROOT "${_tmp_root}/xe-ctest-${_build_hash}")

# add_qt_test(<name> [DBUS_SESSION]
#     SOURCES  <extra .cpp/.h compiled into the test, beyond tst_<name>.cpp>
#     LINK     <extra Qt6::* / libraries to link>)
# Always links Qt6::Test + the real Rust core, enables AUTOMOC, registers a ctest
# with the offscreen/temp-dir ENVIRONMENT, and (under XENEON_COVERAGE) instruments
# the test exe + the logic it pulls in.
function(add_qt_test name)
    cmake_parse_arguments(T "DBUS_SESSION" "" "SOURCES;LINK" ${ARGN})

    add_executable(${name} tst_${name}.cpp ${T_SOURCES})
    set_target_properties(${name} PROPERTIES AUTOMOC ON)
    target_include_directories(${name} PRIVATE
        "${CMAKE_SOURCE_DIR}/core" "${APP_SRC}" "${MGR_SRC}")
    target_link_libraries(${name} PRIVATE
        Qt6::Test Qt6::Core ${T_LINK} ${RUST_LIB} pthread dl)
    add_dependencies(${name} rust_core)

    # Tell hermetic.h where the build system puts its sandboxes, so a test run
    # outside one can refuse to start. See tests/cpp/hermetic.h.
    target_compile_definitions(${name} PRIVATE
        XENEON_TEST_SANDBOX_ROOT="${CMAKE_CURRENT_BINARY_DIR}/tmp")

    if(XENEON_COVERAGE)
        target_compile_options(${name} PRIVATE --coverage -O0 -g)
        target_link_options(${name} PRIVATE --coverage)
    endif()

    # Per-test hermetic dirs. Config round-trips stay in the build tree; the
    # runtime dir (and so the IPC socket) goes in the short temp root - see the
    # sun_path note at the top of this file.
    set(_tmp "${CMAKE_CURRENT_BINARY_DIR}/tmp/${name}")
    set(_run "${SOCK_ROOT}/${name}")
    file(MAKE_DIRECTORY "${_tmp}/config" "${_run}")

    # TIMEOUT: without it these inherit CTest's 1500 s default, so a test that
    # wedges an event loop (config_bridge, control_server) hangs a run for 25
    # minutes. 120 s is ~40x the slowest of these in practice.
    if(T_DBUS_SESSION)
        # A private bus makes transport-level QtDBus coverage deterministic while
        # keeping the test isolated from the developer's real desktop session.
        # There is deliberately no portal service on this bus: start() must issue
        # both async reads and handle their errors without blocking or changing the
        # default. Ubuntu's QtDBus runtime depends on dbus-daemon, which supplies
        # dbus-run-session on the CI image and supported package-build hosts.
        find_program(DBUS_RUN_SESSION_EXECUTABLE dbus-run-session REQUIRED)
        add_test(NAME ${name}
                 COMMAND "${DBUS_RUN_SESSION_EXECUTABLE}" -- "$<TARGET_FILE:${name}>")
    else()
        add_test(NAME ${name} COMMAND ${name})
    endif()
    set(_test_environment
        "QT_QPA_PLATFORM=offscreen;XDG_CONFIG_HOME=${_tmp}/config;XDG_RUNTIME_DIR=${_run};HOME=${_tmp}")
    if(T_DBUS_SESSION)
        list(APPEND _test_environment "XENEON_TEST_PRIVATE_DBUS=1")
    endif()
    set_tests_properties(${name} PROPERTIES
        TIMEOUT 120
        ENVIRONMENT "${_test_environment}")
endfunction()

# ── Unit (pure logic) ──
add_qt_test(display_match   SOURCES "${APP_SRC}/display_match.cpp")
add_qt_test(metrics_json    SOURCES "${APP_SRC}/display_match.cpp")
add_qt_test(path_sanitize)
add_qt_test(orientation_byte SOURCES "${APP_SRC}/orientation_sensor.cpp")
add_qt_test(reconcile       SOURCES "${MGR_SRC}/reconcile.cpp")
add_qt_test(manager_display_policy)
add_qt_test(autostart       SOURCES "${APP_SRC}/autostart.cpp")
# Offline licence FFI. No extra sources: it calls the Rust core directly, which
# is the whole surface the app uses. Qt6::Test already brings QJson*.
add_qt_test(license)
add_qt_test(notification_bridge DBUS_SESSION
            SOURCES "${APP_SRC}/notification_bridge.h" LINK Qt6::DBus)

# Opt-in manual smoke target. It is intentionally excluded from the default
# build and from CTest because executing it creates a real desktop notification.
add_executable(notification_desktop_smoke EXCLUDE_FROM_ALL
    notification_desktop_smoke.cpp
    "${APP_SRC}/notification_bridge.h")
set_target_properties(notification_desktop_smoke PROPERTIES AUTOMOC ON)
target_include_directories(notification_desktop_smoke PRIVATE "${APP_SRC}")
target_link_libraries(notification_desktop_smoke PRIVATE Qt6::Core Qt6::DBus)

add_qt_test(shutdown_flush)

# ── Unit (event loop) ──
# The Q_OBJECT header is listed as a source so AUTOMOC generates its moc.
add_qt_test(config_bridge   SOURCES "${APP_SRC}/config_bridge.h" "${APP_SRC}/autostart.cpp")
# E9 managed/org policy: ConfigBridge::policy() + the policy FFI, via the
# XENEON_POLICY_PATH test seam (never the real /etc). Same TU set as
# config_bridge: the header declares WizardBridge too, whose moc references
# applyAutostart → autostart.cpp must be linked.
add_qt_test(policy          SOURCES "${APP_SRC}/config_bridge.h" "${APP_SRC}/autostart.cpp")
add_qt_test(metrics_worker  SOURCES "${APP_SRC}/metrics_worker.h" "${APP_SRC}/display_match.cpp" LINK Qt6::Gui)

# ── Integration (real QLocalSocket) ──
add_qt_test(control_server  SOURCES "${APP_SRC}/control_server.cpp" LINK Qt6::Network)
add_qt_test(control_socket_path)
# manager_backend_sync links the hub's REAL ControlServer (+ autostart) as well, so
# the B5 two-writer-race regressions can drive an actual hub-side apply/save rather
# than a fake that never holds a config.
add_qt_test(manager_backend_sync SOURCES "${MGR_SRC}/manager_backend.h" "${MGR_SRC}/reconcile.cpp"
                                         "${APP_SRC}/control_server.cpp" "${APP_SRC}/autostart.cpp"
                                 LINK Qt6::Gui Qt6::Network)
add_qt_test(rx_cap          SOURCES "${MGR_SRC}/manager_backend.h" "${MGR_SRC}/reconcile.cpp" LINK Qt6::Gui Qt6::Network)
add_qt_test(single_instance)
add_qt_test(network_access_policy LINK Qt6::Network Qt6::Qml)

# ── Headless negative (crafted FIFO / closed fd, no hardware) ──
add_qt_test(orientation_reopen SOURCES "${APP_SRC}/orientation_sensor.cpp")

# Real IANA zones for QML. The Q_OBJECT header is listed as a source so AUTOMOC
# generates its moc (otherwise: undefined reference to vtable).
add_qt_test(timezone_bridge SOURCES "${APP_SRC}/timezone_bridge.h" LINK Qt6::Gui)

# Distro identity / package count / system age, probed off-thread. Same rule as
# above: the Q_OBJECT header must be a SOURCE (it declares TWO QObjects - the
# bridge and its worker) or AUTOMOC never runs and both vtables go undefined.
add_qt_test(distro_bridge SOURCES "${APP_SRC}/distro_bridge.h" LINK Qt6::Gui)

# OS reduce-motion probe (XDG settings portal). Q_OBJECT header as a SOURCE for
# AUTOMOC (vtable rule above). Tests drive the parsing seam with crafted
# variants; the one real-bus case QSKIPs when the sandbox has no session bus.
add_qt_test(system_settings_probe DBUS_SESSION
            SOURCES "${APP_SRC}/system_settings_probe.h" LINK Qt6::DBus)

# MPRIS player-choice policy + metadata/availability rules (mpris_state.cpp), and
# the member-state fold that stayed in the bridge (MprisBridge::applyProps).
# mpris_bridge.cpp is a SOURCE so applyProps can be driven; its Q_OBJECT header
# gets moc'd from it (vtable rule above).
#
# NO BUS, BY CONSTRUCTION: DBUS_SESSION_BUS_ADDRESS is pointed at a socket that
# cannot exist, so QDBusConnection::sessionBus() comes back disconnected and
# MprisBridge's ctor takes its no-bus path - it never scans, and can never reach
# the developer's real media players. This is NOT a "skip if no bus" test: the
# suite ASSERTS the disconnection (mprisBridgeIsOfflineInThisTest) and FAILS if a
# bus ever appears, so the guard cannot rot into a silent no-op. Verified by
# sabotage (2026-07-17): deleting the override below turns that test red on a
# box with a real bus, rather than skipping. Everything else here is pure and
# needs no bus at all.
add_qt_test(mpris_state SOURCES "${APP_SRC}/mpris_state.cpp" "${APP_SRC}/mpris_bridge.cpp"
                        LINK Qt6::DBus)
set_property(TEST mpris_state APPEND PROPERTY
    ENVIRONMENT "DBUS_SESSION_BUS_ADDRESS=unix:path=${SOCK_ROOT}/mpris_state/nonexistent-bus")

# Real asynchronous MPRIS conversation against isolated mock players on a
# private D-Bus. It cannot discover or control the developer's actual players.
add_qt_test(mpris_bridge DBUS_SESSION
            SOURCES "${APP_SRC}/mpris_state.cpp" "${APP_SRC}/mpris_bridge.cpp"
            LINK Qt6::DBus)

# Opt-in manual smoke target. It is excluded from the default build and CTest
# because it briefly toggles one real desktop player's playback, then restores
# the original state with a second toggle.
add_executable(mpris_desktop_smoke EXCLUDE_FROM_ALL
    mpris_desktop_smoke.cpp
    "${APP_SRC}/mpris_bridge.h"
    "${APP_SRC}/mpris_bridge.cpp"
    "${APP_SRC}/mpris_state.cpp")
set_target_properties(mpris_desktop_smoke PROPERTIES AUTOMOC ON)
target_include_directories(mpris_desktop_smoke PRIVATE "${APP_SRC}")
target_link_libraries(mpris_desktop_smoke PRIVATE Qt6::Core Qt6::DBus)

# ── Smoke: launch the REAL binaries offscreen (main()/screen match/thread lifecycle;
#    doubles as the XENEON_GRAB UAF regression) ──
add_executable(smoke_hub tst_smoke_hub.cpp)
set_target_properties(smoke_hub PROPERTIES AUTOMOC ON)
target_link_libraries(smoke_hub PRIVATE Qt6::Test Qt6::Core Qt6::Gui)
# QA_HOOKS_BUILD tells the test whether the binary it launches can honor
# XENEON_GRAB at all; without the hook the hub never exits and the test would
# fail on a 30s timeout instead of reporting the real reason. See the QSKIP.
target_compile_definitions(smoke_hub PRIVATE
    HUB_BIN="$<TARGET_FILE:xeneon-edge-hub>"
    QA_HOOKS_BUILD=$<BOOL:${XENEON_QA_HOOKS}>
    XENEON_TEST_SANDBOX_ROOT="${CMAKE_CURRENT_BINARY_DIR}/tmp")
add_dependencies(smoke_hub xeneon-edge-hub)
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_hub/config" "${SOCK_ROOT}/smoke_hub")
add_test(NAME smoke_hub COMMAND smoke_hub)
set_tests_properties(smoke_hub PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;XDG_CONFIG_HOME=${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_hub/config;XDG_RUNTIME_DIR=${SOCK_ROOT}/smoke_hub;HOME=${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_hub"
    TIMEOUT 60)

add_executable(smoke_manager tst_smoke_manager.cpp)
set_target_properties(smoke_manager PROPERTIES AUTOMOC ON)
target_link_libraries(smoke_manager PRIVATE Qt6::Test Qt6::Core Qt6::Gui)
target_compile_definitions(smoke_manager PRIVATE
    MGR_BIN="$<TARGET_FILE:xeneon-edge-manager>"
    QA_HOOKS_BUILD=$<BOOL:${XENEON_QA_HOOKS}>
    XENEON_TEST_SANDBOX_ROOT="${CMAKE_CURRENT_BINARY_DIR}/tmp")
add_dependencies(smoke_manager xeneon-edge-manager)
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_manager/config" "${SOCK_ROOT}/smoke_manager")
add_test(NAME smoke_manager COMMAND smoke_manager)
set_tests_properties(smoke_manager PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;XDG_CONFIG_HOME=${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_manager/config;XDG_RUNTIME_DIR=${SOCK_ROOT}/smoke_manager;HOME=${CMAKE_CURRENT_BINARY_DIR}/tmp/smoke_manager"
    TIMEOUT 60)
