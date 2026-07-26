#pragma once

#include <QSize>
#include <QString>
#include <QVector>

struct ManagerScreenIdentity {
    QString model;
    QString manufacturer;
    QSize size;
};

inline bool managerScreenIsEdge(const ManagerScreenIdentity& screen) {
    if (screen.model.contains(QStringLiteral("XENEON"), Qt::CaseInsensitive)
        || screen.manufacturer.contains(QStringLiteral("Corsair"), Qt::CaseInsensitive))
        return true;
    return screen.size == QSize(2560, 720) || screen.size == QSize(720, 2560);
}

// Return a safe screen index, preferring the primary screen. A negative result
// is a hard stop: the Manager must remain hidden when every output is the Edge.
inline int managerSafeScreenIndex(const QVector<ManagerScreenIdentity>& screens,
                                  int primaryIndex) {
    if (primaryIndex >= 0 && primaryIndex < screens.size()
        && !managerScreenIsEdge(screens.at(primaryIndex)))
        return primaryIndex;

    for (int i = 0; i < screens.size(); ++i)
        if (!managerScreenIsEdge(screens.at(i))) return i;
    return -1;
}

// Wayland intentionally gives ordinary top-level clients no portable way to
// choose their first output. QWindow::setScreen()/setPosition() are only hints
// there, and KWin can map the Manager on the active output instead. That is a
// safety defect when the active output is the Edge: the Manager configures the
// Hub and must never appear on the panel.
//
// KDE's XWayland path does honour the pre-map screen and position request. Use
// it narrowly for the desktop Manager on a KDE Wayland session when DISPLAY is
// available. Never override an explicit Qt platform choice: offscreen tests,
// diagnostics, and users who deliberately selected a backend keep control.
inline bool managerShouldPreferXcbPlatform(const QString& sessionType,
                                           const QString& currentDesktop,
                                           const QString& display,
                                           const QString& explicitPlatform) {
    return explicitPlatform.trimmed().isEmpty()
        && sessionType.compare(QStringLiteral("wayland"), Qt::CaseInsensitive) == 0
        && currentDesktop.contains(QStringLiteral("KDE"), Qt::CaseInsensitive)
        && !display.trimmed().isEmpty();
}
