#include <QtDBus>
#include <QtTest>

#include "notification_bridge.h"

class NotificationService final : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.Notifications")

public:
    int calls = 0;
    NotificationRequest seen;

public slots:
    uint Notify(const QString& applicationName, uint replacesId,
                const QString& icon, const QString& summary,
                const QString& body, const QStringList& actions,
                const QVariantMap& hints, int timeoutMs) {
        ++calls;
        seen.applicationName = applicationName;
        seen.replacesId = replacesId;
        seen.icon = icon;
        seen.summary = summary;
        seen.body = body;
        seen.actions = actions;
        seen.hints = hints;
        seen.timeoutMs = timeoutMs;
        return 42;
    }
};

class NotificationBridgeTest : public QObject {
    Q_OBJECT

private slots:
    void rejectsEmptyContent() {
        int calls = 0;
        NotificationBridge bridge(nullptr, [&calls](const NotificationRequest&) {
            ++calls;
            return true;
        });
        QVERIFY(!bridge.send(QString(), QStringLiteral("Body")));
        QVERIFY(!bridge.send(QStringLiteral("Title"), QStringLiteral("  ")));
        QCOMPARE(calls, 0);
    }

    void constructsTheCompleteProtocolRequest() {
        NotificationRequest seen;
        NotificationBridge bridge(
            nullptr, [&seen](const NotificationRequest& request) {
                seen = request;
                return true;
            });
        QVERIFY(bridge.send(QString(140, QLatin1Char('S')) + QStringLiteral("  "),
                            QStringLiteral("  ") + QString(530, QLatin1Char('B'))));

        QCOMPARE(seen.service, QStringLiteral("org.freedesktop.Notifications"));
        QCOMPARE(seen.path, QStringLiteral("/org/freedesktop/Notifications"));
        QCOMPARE(seen.interfaceName, QStringLiteral("org.freedesktop.Notifications"));
        QCOMPARE(seen.method, QStringLiteral("Notify"));
        QCOMPARE(seen.applicationName, QStringLiteral("EdgeHub"));
        QCOMPARE(seen.replacesId, 0U);
        QCOMPARE(seen.icon, QStringLiteral("xeneon-edge-hub"));
        QCOMPARE(seen.summary.size(), 120);
        QCOMPARE(seen.body.size(), 500);
        QVERIFY(!seen.summary.endsWith(QLatin1Char(' ')));
        QVERIFY(!seen.body.startsWith(QLatin1Char(' ')));
        QVERIFY(seen.actions.isEmpty());
        QCOMPARE(seen.hints.value(QStringLiteral("desktop-entry")).toString(),
                 QStringLiteral("xeneon-edge-hub"));
        QCOMPARE(seen.hints.value(QStringLiteral("urgency")).value<uchar>(),
                 static_cast<uchar>(1));
        QCOMPARE(seen.timeoutMs, 10000);
        QCOMPARE(seen.arguments().size(), 8);
    }

    void priorityReminderIsUrgentAndPersistent() {
        NotificationRequest seen;
        NotificationBridge bridge(
            nullptr, [&seen](const NotificationRequest& request) {
                seen = request;
                return true;
            });

        QVERIFY(bridge.sendPriority(QStringLiteral("Break reminder"),
                                    QStringLiteral("Time to stand up and reset.")));
        QCOMPARE(seen.summary, QStringLiteral("Break reminder"));
        QCOMPARE(seen.body, QStringLiteral("Time to stand up and reset."));
        QCOMPARE(seen.timeoutMs, 0);
        QCOMPARE(seen.hints.value(QStringLiteral("urgency")).value<uchar>(),
                 static_cast<uchar>(2));
        QCOMPARE(seen.hints.value(QStringLiteral("resident")).toBool(), true);
        QCOMPARE(seen.hints.value(QStringLiteral("transient")).toBool(), false);
        QCOMPARE(seen.hints.value(QStringLiteral("category")).toString(),
                 QStringLiteral("x-edgehub.reminder"));
        QCOMPARE(seen.arguments().size(), 8);
    }

    void returnsInjectedTransportFailure() {
        NotificationBridge bridge(nullptr, [](const NotificationRequest&) {
            return false;
        });
        QVERIFY(!bridge.send(QStringLiteral("Focus complete"),
                             QStringLiteral("Your break is ready.")));
    }

    void unavailableDesktopServiceFailsClosed() {
        auto bus = QDBusConnection::sessionBus();
        QVERIFY(bus.isConnected());
        bus.unregisterService(QStringLiteral("org.freedesktop.Notifications"));
        NotificationBridge bridge;
        QVERIFY(!bridge.send(QStringLiteral("Focus complete"),
                             QStringLiteral("Your break is ready.")));
    }

    void dispatchesToARealPrivateBusService() {
        auto bus = QDBusConnection::sessionBus();
        QVERIFY(bus.isConnected());
        NotificationService service;
        QVERIFY(bus.registerService(QStringLiteral("org.freedesktop.Notifications")));
        QVERIFY(bus.registerObject(QStringLiteral("/org/freedesktop/Notifications"),
                                   &service, QDBusConnection::ExportAllSlots));

        NotificationBridge bridge;
        QSignalSpy confirmed(&bridge, &NotificationBridge::deliveryConfirmed);
        QSignalSpy failed(&bridge, &NotificationBridge::deliveryFailed);
        QVERIFY(bridge.send(QStringLiteral("Medication reminder"),
                            QStringLiteral("Time for the evening dose.")));
        QTRY_COMPARE_WITH_TIMEOUT(service.calls, 1, 2000);
        QTRY_COMPARE_WITH_TIMEOUT(confirmed.count(), 1, 2000);
        QCOMPARE(confirmed.at(0).at(0).toUInt(), 42U);
        QCOMPARE(failed.count(), 0);
        QCOMPARE(service.seen.applicationName, QStringLiteral("EdgeHub"));
        QCOMPARE(service.seen.summary, QStringLiteral("Medication reminder"));
        QCOMPARE(service.seen.body, QStringLiteral("Time for the evening dose."));
        QCOMPARE(service.seen.icon, QStringLiteral("xeneon-edge-hub"));
        QCOMPARE(service.seen.timeoutMs, 10000);
        QCOMPARE(service.seen.hints.value(QStringLiteral("desktop-entry")).toString(),
                 QStringLiteral("xeneon-edge-hub"));

        bus.unregisterObject(QStringLiteral("/org/freedesktop/Notifications"));
        bus.unregisterService(QStringLiteral("org.freedesktop.Notifications"));
    }
};

QTEST_GUILESS_MAIN(NotificationBridgeTest)
#include "tst_notification_bridge.moc"
