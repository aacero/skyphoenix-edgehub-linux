#pragma once

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QSaveFile>
#include <QString>

#include <atomic>

namespace xeneon {

inline QString exportUiStateRecovery(
    const QString& configDirectory,
    const QString& json) {
    constexpr qsizetype kMaxRecoveryBytes = 16 * 1024 * 1024;
    const QByteArray bytes = json.toUtf8();
    if (bytes.isEmpty() || bytes.size() > kMaxRecoveryBytes)
        return QString();

    const QString recoveryDir = configDirectory + "/recovery";
    if (!QDir().mkpath(recoveryDir))
        return QString();
    QFile::setPermissions(
        recoveryDir,
        QFileDevice::ReadOwner | QFileDevice::WriteOwner
            | QFileDevice::ExeOwner);

    static std::atomic<quint64> sequence{0};
    const QString name = QStringLiteral("ui-state-%1-%2-%3.json")
                             .arg(QDateTime::currentDateTimeUtc().toString(
                                 QStringLiteral("yyyyMMdd-HHmmss-zzz")))
                             .arg(QCoreApplication::applicationPid())
                             .arg(sequence.fetch_add(1, std::memory_order_relaxed));
    const QString path = recoveryDir + "/" + name;
    QSaveFile file(path);
    file.setDirectWriteFallback(false);
    if (!file.open(QIODevice::WriteOnly))
        return QString();
    if (!file.setPermissions(
            QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
        file.cancelWriting();
        return QString();
    }
    if (file.write(bytes) != bytes.size() || !file.commit())
        return QString();
    return path;
}

} // namespace xeneon
