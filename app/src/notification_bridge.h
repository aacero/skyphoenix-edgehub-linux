#pragma once

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
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
        return sendWithProfile(summary, body, false);
    }

    // Reminder-class notifications must not disappear on the daemon's ordinary
    // toast timeout. The Hub also presents its own persistent visual alert, but
    // an off-page reminder should remain in the desktop notification surface
    // until the user explicitly dismisses it.
    Q_INVOKABLE bool sendPriority(const QString& summary, const QString& body) {
        return sendWithProfile(summary, body, true);
    }

signals:
    void deliveryConfirmed(uint notificationId);
    void deliveryFailed(const QString& message);

private:
    bool sendWithProfile(const QString& summary, const QString& body,
                         bool priority) {
        const QString safeSummary = summary.trimmed().left(120);
        const QString safeBody = body.trimmed().left(500);
        if (safeSummary.isEmpty() || safeBody.isEmpty()) return false;

        NotificationRequest request;
        request.summary = safeSummary;
        request.body = safeBody;
        request.hints.insert(QStringLiteral("desktop-entry"),
                             QStringLiteral("xeneon-edge-hub"));
        request.hints.insert(QStringLiteral("urgency"),
                             QVariant::fromValue<uchar>(priority ? 2 : 1));
        if (priority) {
            request.timeoutMs = 0;
            request.hints.insert(QStringLiteral("resident"), true);
            request.hints.insert(QStringLiteral("transient"), false);
            request.hints.insert(QStringLiteral("category"),
                                 QStringLiteral("x-edgehub.reminder"));
        }
        if (transport_) return transport_(request);

        return dispatch(request);
    }

    bool dispatch(const NotificationRequest& request) {
        QDBusInterface notifications(
            request.service,
            request.path,
            request.interfaceName,
            QDBusConnection::sessionBus());
        if (!notifications.isValid()) {
            emit deliveryFailed(QStringLiteral(
                "org.freedesktop.Notifications is unavailable"));
            return false;
        }

        const QDBusPendingCall pending =
            notifications.asyncCallWithArgumentList(request.method, request.arguments());
        if (pending.isError()) {
            emit deliveryFailed(pending.error().message());
            return false;
        }

        auto* watcher = new QDBusPendingCallWatcher(pending, this);
        connect(
            watcher, &QDBusPendingCallWatcher::finished, this,
            [this](QDBusPendingCallWatcher* self) {
                const QDBusPendingReply<uint> reply = *self;
                self->deleteLater();
                if (reply.isError()) {
                    emit deliveryFailed(reply.error().message());
                    return;
                }
                emit deliveryConfirmed(reply.value());
            });
        return true;
    }

    Transport transport_;
};
