#include <QtTest>

#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>

#include <memory>

#include "safe_mode_policy.h"

class TstSafeMode final : public QObject {
    Q_OBJECT

    static std::unique_ptr<QObject> createProbe(bool safeMode, QQmlEngine& engine) {
        engine.rootContext()->setContextProperty(
            QStringLiteral("_widgetsEnabled"),
            widgetsEnabledForSession(safeMode));

        QQmlComponent component(&engine);
        component.setData(R"QML(
            import QtQuick
            import "../../ui/qml/widgets" as Widgets

            Item {
                id: probe
                property int instantiationAttempts: 0

                Widgets.WidgetHost {
                    objectName: "safeModeProbeHost"
                    width: 320
                    height: 180
                    widgetId: "deliberately-failing"
                    widgetType: "deliberately-failing"
                    widgetComponent: Component {
                        Item {
                            Component.onCompleted: {
                                probe.instantiationAttempts++
                                throw new Error("INTENTIONALLY_FAILING_SAFE_MODE_WIDGET")
                            }
                        }
                    }
                }
            }
        )QML", QUrl::fromLocalFile(
                    QStringLiteral(XENEON_SOURCE_DIR "/tests/cpp/safe_mode_probe.qml")));

        if (component.isLoading()) {
            QSignalSpy ready(&component, &QQmlComponent::statusChanged);
            ready.wait(5000);
        }
        if (component.status() != QQmlComponent::Ready)
            qWarning().noquote() << component.errorString();
        return std::unique_ptr<QObject>(component.create());
    }

private slots:
    void policyIsSessionOnlyAndFailClosed() {
        QVERIFY(widgetsEnabledForSession(false));
        QVERIFY(!widgetsEnabledForSession(true));
    }

    void deliberatelyFailingWidgetIsNotInstantiatedInSafeMode() {
        QQmlEngine engine;
        auto probe = createProbe(true, engine);
        QVERIFY(probe);

        QObject* host = probe->findChild<QObject*>(QStringLiteral("safeModeProbeHost"));
        QVERIFY(host);
        QTest::qWait(100);
        QCOMPARE(probe->property("instantiationAttempts").toInt(), 0);
        QCOMPARE(host->property("sessionEnabled").toBool(), false);
        QCOMPARE(host->property("status").toInt(), 0); // Loader.Null
        QVERIFY(host->property("item").value<QObject*>() == nullptr);
    }

    void sameWidgetWouldExecuteOutsideSafeMode() {
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(".*INTENTIONALLY_FAILING_SAFE_MODE_WIDGET.*"));
        QQmlEngine engine;
        auto probe = createProbe(false, engine);
        QVERIFY(probe);

        QObject* host = probe->findChild<QObject*>(QStringLiteral("safeModeProbeHost"));
        QVERIFY(host);
        QTRY_COMPARE_WITH_TIMEOUT(probe->property("instantiationAttempts").toInt(), 1, 3000);
        QCOMPARE(host->property("sessionEnabled").toBool(), true);
        QVERIFY(host->property("item").value<QObject*>() != nullptr);
    }
};

QTEST_MAIN(TstSafeMode)
#include "tst_safe_mode.moc"
