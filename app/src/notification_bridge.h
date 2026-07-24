#pragma once

#include <QDBusConnection>
#include <QDBusInterface>
#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantMap>

#include <functional>
#include <utility>

class NotificationBridge final : public QObject {
    Q_OBJECT

public:
    using Sender = std::function<bool(const QString&, const QString&)>;

    explicit NotificationBridge(QObject* parent = nullptr, Sender sender = {})
        : QObject(parent), sender_(std::move(sender)) {}

    Q_INVOKABLE bool send(const QString& summary, const QString& body) {
        const QString safeSummary = summary.trimmed().left(120);
        const QString safeBody = body.trimmed().left(500);
        if (safeSummary.isEmpty() || safeBody.isEmpty()) return false;
        if (sender_) return sender_(safeSummary, safeBody);

        QDBusInterface notifications(
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"),
            QDBusConnection::sessionBus());
        if (!notifications.isValid()) return false;

        QVariantMap hints;
        hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("xeneon-edge-hub"));
        hints.insert(QStringLiteral("urgency"), QVariant::fromValue<uchar>(1));
        const QList<QVariant> arguments{
            QStringLiteral("EdgeHub"),
            QVariant::fromValue<uint>(0),
            QStringLiteral("xeneon-edge-hub"),
            safeSummary,
            safeBody,
            QStringList{},
            hints,
            10000,
        };
        notifications.asyncCallWithArgumentList(QStringLiteral("Notify"), arguments);
        return true;
    }

private:
    Sender sender_;
};
