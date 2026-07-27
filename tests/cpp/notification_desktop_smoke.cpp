#include <QCoreApplication>
#include <QDateTime>
#include <QTimer>

#include <QJsonDocument>
#include <QJsonObject>

#include <cstdio>

#include "notification_bridge.h"

#ifndef XENEON_EVIDENCE_SOURCE_COMMIT
#error "notification_desktop_smoke must be built with XENEON_EVIDENCE_SOURCE_COMMIT"
#endif

namespace {

constexpr auto kSummary = "Break reminder";
constexpr auto kBody = "Time to stand up, stretch, and reset.";

void logEvent(const QJsonObject& event) {
    QJsonObject record = event;
    record.insert(
        QStringLiteral("timestamp"),
        QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    record.insert(
        QStringLiteral("source_commit"),
        QStringLiteral(XENEON_EVIDENCE_SOURCE_COMMIT));
    const QByteArray payload = QJsonDocument(record).toJson(QJsonDocument::Compact);
    fprintf(stdout, "EDGEHUB_NOTIFICATION_EVIDENCE %s\n", payload.constData());
    fflush(stdout);
}

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    NotificationBridge bridge;

    QObject::connect(
        &bridge, &NotificationBridge::deliveryConfirmed, &app,
        [&](uint notificationId) {
            logEvent({
                {QStringLiteral("event"), QStringLiteral("confirmed")},
                {QStringLiteral("notification_id"),
                 static_cast<qint64>(notificationId)},
                {QStringLiteral("service"),
                 QStringLiteral("org.freedesktop.Notifications")},
                {QStringLiteral("method"), QStringLiteral("Notify")},
            });
            app.exit(0);
        });
    QObject::connect(
        &bridge, &NotificationBridge::deliveryFailed, &app,
        [&](const QString& message) {
            logEvent({
                {QStringLiteral("event"), QStringLiteral("failed")},
                {QStringLiteral("message"), message},
                {QStringLiteral("service"),
                 QStringLiteral("org.freedesktop.Notifications")},
                {QStringLiteral("method"), QStringLiteral("Notify")},
            });
            app.exit(1);
        });

    logEvent({
        {QStringLiteral("event"), QStringLiteral("request")},
        {QStringLiteral("service"),
         QStringLiteral("org.freedesktop.Notifications")},
        {QStringLiteral("method"), QStringLiteral("Notify")},
        {QStringLiteral("summary"), QString::fromLatin1(kSummary)},
        {QStringLiteral("body"), QString::fromLatin1(kBody)},
        {QStringLiteral("profile"), QStringLiteral("priority")},
        {QStringLiteral("urgency"), 2},
        {QStringLiteral("resident"), true},
        {QStringLiteral("transient"), false},
        {QStringLiteral("timeout_ms"), 0},
    });
    if (!bridge.sendPriority(
            QString::fromLatin1(kSummary), QString::fromLatin1(kBody))) {
        return 1;
    }

    QTimer::singleShot(5000, &app, [&] {
        logEvent({
            {QStringLiteral("event"), QStringLiteral("timeout")},
            {QStringLiteral("service"),
             QStringLiteral("org.freedesktop.Notifications")},
            {QStringLiteral("method"), QStringLiteral("Notify")},
        });
        app.exit(2);
    });
    return app.exec();
}
