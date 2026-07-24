#include <QCoreApplication>
#include <QDebug>
#include <QTimer>

#include "mpris_bridge.h"

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    const QString requested =
        argc > 1 ? QString::fromLocal8Bit(argv[1]).trimmed()
                 : QStringLiteral("spotify");

    MprisBridge bridge;
    bridge.setPreferredPlayer(requested);

    bool firstToggleSent = false;
    bool restoreToggleSent = false;
    bool transportFailed = false;
    QString initialStatus;

    QObject::connect(
        &bridge, &MprisBridge::transportError, &app,
        [&](const QString& action, const QString& message) {
            transportFailed = true;
            qCritical() << "MPRIS transport failed:" << action << message;
        });

    QTimer waitForPlayer;
    waitForPlayer.setInterval(50);
    QObject::connect(&waitForPlayer, &QTimer::timeout, &app, [&] {
        if (firstToggleSent || !bridge.available() ||
            bridge.playerName().compare(requested, Qt::CaseInsensitive) != 0) {
            return;
        }

        firstToggleSent = true;
        initialStatus = bridge.status();
        qInfo() << "MPRIS smoke selected" << bridge.playerName()
                << "with initial status" << initialStatus;
        bridge.playPause();

        QTimer::singleShot(500, &app, [&] {
            restoreToggleSent = true;
            bridge.playPause();
        });
        QTimer::singleShot(1200, &app, [&] {
            qInfo() << "MPRIS smoke final status" << bridge.status();
            app.exit(transportFailed ? 1 : 0);
        });
    });
    waitForPlayer.start();

    QTimer::singleShot(6000, &app, [&] {
        if (firstToggleSent && !restoreToggleSent)
            bridge.playPause();
        qCritical() << "MPRIS smoke timed out for player" << requested;
        app.exit(2);
    });

    return app.exec();
}
