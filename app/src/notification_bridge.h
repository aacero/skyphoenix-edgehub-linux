#pragma once

#include <QDBusConnection>
#include <QDBusInterface>
#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantMap>

#include <functional>
#include <utility>

struct NotificationRequest {
    QString service = QStringLiteral("org.freedesktop.Notifications");
    QString path = QStringLiteral("/org/freedesktop/Notifications");
    QString interfaceName = QStringLiteral("org.freedesktop.Notifications");
    QString method = QStringLiteral("Notify");
    QString applicationName = QStringLiteral("EdgeHub");
    uint replacesId = 0;
    QString icon = QStringLiteral("xeneon-edge-hub");
    QString summary;
    QString body;
    QStringList actions;
    QVariantMap hints;
    int timeoutMs = 10000;

    QList<QVariant> arguments() const {
        return {
            applicationName,
            QVariant::fromValue<uint>(replacesId),
            icon,
            summary,
            body,
            actions,
            hints,
            timeoutMs,
        };
    }
};

class NotificationBridge final : public QObject {
    Q_OBJECT

public:
    using Transport = std::function<bool(const NotificationRequest&)>;

    explicit NotificationBridge(QObject* parent = nullptr, Transport transport = {})
        : QObject(parent), transport_(std::move(transport)) {}

    Q_INVOKABLE bool send(const QString& summary, const QString& body) {
        const QString safeSummary = summary.trimmed().left(120);
        const QString safeBody = body.trimmed().left(500);
        if (safeSummary.isEmpty() || safeBody.isEmpty()) return false;

        NotificationRequest request;
        request.summary = safeSummary;
        request.body = safeBody;
        request.hints.insert(QStringLiteral("desktop-entry"),
                             QStringLiteral("xeneon-edge-hub"));
        request.hints.insert(QStringLiteral("urgency"), QVariant::fromValue<uchar>(1));
        if (transport_) return transport_(request);

        return dispatch(request);
    }

private:
    static bool dispatch(const NotificationRequest& request) {
        QDBusInterface notifications(
            request.service,
            request.path,
            request.interfaceName,
            QDBusConnection::sessionBus());
        if (!notifications.isValid()) return false;

        const QDBusPendingCall pending =
            notifications.asyncCallWithArgumentList(request.method, request.arguments());
        return !pending.isError();
    }

    Transport transport_;
};
