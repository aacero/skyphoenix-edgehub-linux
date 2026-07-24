#include <QCoreApplication>
#include <QTimer>

#include "notification_bridge.h"

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    NotificationBridge bridge;
    if (!bridge.send(
            QStringLiteral("EdgeHub notification check"),
            QStringLiteral("The real desktop notification transport is working."))) {
        return 1;
    }

    // Keep the connection alive long enough for the asynchronous D-Bus message
    // to be delivered before the short-lived smoke process exits.
    QTimer::singleShot(750, &app, &QCoreApplication::quit);
    return app.exec();
}
