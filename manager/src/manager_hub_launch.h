#pragma once

#include <QProcess>
#include <QProcessEnvironment>

#include <utility>

#include "../../app/src/autostart.h"

// The Manager may select xcb for its own top-level placement on KDE Wayland.
// That is an internal implementation choice, not a user preference, so it must
// not leak into a Hub launched from the Manager. A platform value supplied by
// the user remains authoritative and is preserved because the caller passes
// managerInjectedQtPlatform=false in that case.
inline QProcessEnvironment hubChildProcessEnvironment(
    QProcessEnvironment inherited, bool managerInjectedQtPlatform) {
    if (managerInjectedQtPlatform)
        inherited.remove(QStringLiteral("QT_QPA_PLATFORM"));
    return inherited;
}

inline bool startHubDetached(
    const HubLaunchCommand& command, bool managerInjectedQtPlatform,
    QProcessEnvironment inherited = QProcessEnvironment::systemEnvironment()) {
    QProcess process;
    process.setProgram(command.program);
    process.setArguments(command.arguments);
    process.setProcessEnvironment(
        hubChildProcessEnvironment(
            std::move(inherited), managerInjectedQtPlatform));
    return process.startDetached();
}
