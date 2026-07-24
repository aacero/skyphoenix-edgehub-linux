#include <QtTest>

#include "notification_bridge.h"

class NotificationBridgeTest : public QObject {
    Q_OBJECT

private slots:
    void rejectsEmptyContent() {
        int calls = 0;
        NotificationBridge bridge(nullptr, [&calls](const QString&, const QString&) {
            ++calls;
            return true;
        });
        QVERIFY(!bridge.send(QString(), QStringLiteral("Body")));
        QVERIFY(!bridge.send(QStringLiteral("Title"), QStringLiteral("  ")));
        QCOMPARE(calls, 0);
    }

    void trimsAndBoundsContent() {
        QString seenSummary;
        QString seenBody;
        NotificationBridge bridge(
            nullptr, [&seenSummary, &seenBody](const QString& summary, const QString& body) {
                seenSummary = summary;
                seenBody = body;
                return true;
            });
        QVERIFY(bridge.send(QString(140, QLatin1Char('S')) + QStringLiteral("  "),
                            QStringLiteral("  ") + QString(530, QLatin1Char('B'))));
        QCOMPARE(seenSummary.size(), 120);
        QCOMPARE(seenBody.size(), 500);
        QVERIFY(!seenSummary.endsWith(QLatin1Char(' ')));
        QVERIFY(!seenBody.startsWith(QLatin1Char(' ')));
    }

    void returnsTransportResult() {
        NotificationBridge bridge(nullptr, [](const QString&, const QString&) {
            return false;
        });
        QVERIFY(!bridge.send(QStringLiteral("Focus complete"),
                             QStringLiteral("Your break is ready.")));
    }
};

QTEST_MAIN(NotificationBridgeTest)
#include "tst_notification_bridge.moc"
