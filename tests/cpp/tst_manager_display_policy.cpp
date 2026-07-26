#include <QtTest>

#include "manager_display_policy.h"

class TstManagerDisplayPolicy : public QObject {
    Q_OBJECT
private slots:
    void identifiesEdgeByModelManufacturerAndSize() {
        QVERIFY(managerScreenIsEdge({QStringLiteral("XENEON EDGE"), {}, QSize(100, 100)}));
        QVERIFY(managerScreenIsEdge({{}, QStringLiteral("Corsair"), QSize(100, 100)}));
        QVERIFY(managerScreenIsEdge({{}, {}, QSize(2560, 720)}));
        QVERIFY(managerScreenIsEdge({{}, {}, QSize(720, 2560)}));
        QVERIFY(!managerScreenIsEdge({QStringLiteral("Desktop"),
                                      QStringLiteral("Acme"), QSize(1920, 1080)}));
    }

    void refusesEdgeOnlyConfiguration() {
        const QVector<ManagerScreenIdentity> screens = {
            {QStringLiteral("XENEON EDGE"), QStringLiteral("Corsair"), QSize(720, 2560)}
        };
        QCOMPARE(managerSafeScreenIndex(screens, 0), -1);
    }

    void prefersSafePrimaryThenFirstSafeFallback() {
        const ManagerScreenIdentity edge = {
            QStringLiteral("XENEON EDGE"), QStringLiteral("Corsair"), QSize(720, 2560)
        };
        const ManagerScreenIdentity desktopA = {
            QStringLiteral("Desktop A"), QStringLiteral("Acme"), QSize(1920, 1080)
        };
        const ManagerScreenIdentity desktopB = {
            QStringLiteral("Desktop B"), QStringLiteral("Acme"), QSize(2560, 1440)
        };
        QCOMPARE(managerSafeScreenIndex({edge, desktopA, desktopB}, 2), 2);
        QCOMPARE(managerSafeScreenIndex({edge, desktopA, desktopB}, 0), 1);
    }

    void prefersXcbOnlyForImplicitKdeWaylandWithDisplay() {
        QVERIFY(managerShouldPreferXcbPlatform(
            QStringLiteral("wayland"), QStringLiteral("KDE"),
            QStringLiteral(":0"), QString()));
        QVERIFY(managerShouldPreferXcbPlatform(
            QStringLiteral("WAYLAND"), QStringLiteral("KDE;plasma"),
            QStringLiteral(":1"), QStringLiteral("  ")));

        QVERIFY(!managerShouldPreferXcbPlatform(
            QStringLiteral("x11"), QStringLiteral("KDE"),
            QStringLiteral(":0"), QString()));
        QVERIFY(!managerShouldPreferXcbPlatform(
            QStringLiteral("wayland"), QStringLiteral("GNOME"),
            QStringLiteral(":0"), QString()));
        QVERIFY(!managerShouldPreferXcbPlatform(
            QStringLiteral("wayland"), QStringLiteral("KDE"),
            QString(), QString()));
    }

    void explicitQtPlatformAlwaysWins() {
        for (const QString& platform : {
                 QStringLiteral("wayland"),
                 QStringLiteral("xcb"),
                 QStringLiteral("offscreen"),
             }) {
            QVERIFY(!managerShouldPreferXcbPlatform(
                QStringLiteral("wayland"), QStringLiteral("KDE"),
                QStringLiteral(":0"), platform));
        }
    }
};

QTEST_GUILESS_MAIN(TstManagerDisplayPolicy)
#include "tst_manager_display_policy.moc"
