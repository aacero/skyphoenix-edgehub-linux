#include "autostart.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLatin1Char>
#include <QStandardPaths>
#include <QString>
#include <QStringView>

#include <unistd.h>

static QString autostartEntryPath() {
    return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
           + "/autostart/xeneon-edge-hub.desktop";
}

static constexpr QFileDevice::Permissions kOwnerDirectoryPermissions =
    QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner;
static constexpr QFileDevice::Permissions kOwnerFilePermissions =
    QFileDevice::ReadOwner | QFileDevice::WriteOwner;

static bool ensureOwnerSafeDirectory(const QString& path) {
    QFileInfo info(path);
    bool created = false;
    if (info.exists()) {
        if (!info.isDir() || info.isSymLink()
            || info.ownerId() != static_cast<uint>(::geteuid())) {
            qWarning() << "Refusing unsafe autostart directory:" << path;
            return false;
        }
    } else {
        if (!QDir().mkpath(path)) {
            qWarning() << "Could not create autostart directory:" << path;
            return false;
        }
        created = true;
        info.setFile(path);
        info.refresh();
        if (!info.isDir() || info.isSymLink()
            || info.ownerId() != static_cast<uint>(::geteuid())) {
            qWarning() << "Refusing unsafe created autostart directory:" << path;
            return false;
        }
    }

    QFile directory(path);
    const QFileDevice::Permissions ownerPermissions =
        created
            ? kOwnerDirectoryPermissions
            : info.permissions() & kOwnerDirectoryPermissions;
    if (!directory.setPermissions(ownerPermissions)) {
        qWarning() << "Could not secure autostart directory:" << path;
        return false;
    }
    return true;
}

QString quoteExecForDesktop(const QString& execPath) {
    bool needsQuotes = execPath.isEmpty();
    QString escaped;
    escaped.reserve(execPath.size() + 8);
    const QStringView reserved = u" \t\n\"'\\><~|&;$*?#()`";
    for (const QChar character : execPath) {
        if (reserved.contains(character))
            needsQuotes = true;
        if (character == u'\\' || character == u'"'
            || character == u'`' || character == u'$') {
            escaped += u'\\';
        }
        // A percent starts a desktop field code even inside quotes.
        if (character == u'%')
            escaped += u'%';
        escaped += character;
    }
    return needsQuotes
        ? QLatin1Char('"') + escaped + QLatin1Char('"')
        : escaped;
}

HubLaunchCommand hubLaunchCommand(const QString& nativeHubProgram) {
    const QString appImage = qEnvironmentVariable("APPIMAGE");
    if (!appImage.isEmpty()) {
        const QFileInfo imageInfo(appImage);
        if (imageInfo.isAbsolute() && imageInfo.isFile()
            && imageInfo.isExecutable()) {
            return {imageInfo.absoluteFilePath(), {QStringLiteral("--hub")}};
        }
        qWarning() << "Ignoring invalid APPIMAGE path for Hub launch";
    }
    return {nativeHubProgram, {}};
}

QString hubAutostartExecLine(const QString& nativeHubProgram) {
    const HubLaunchCommand command = hubLaunchCommand(nativeHubProgram);
    QStringList fields{quoteExecForDesktop(command.program)};
    for (const QString& argument : command.arguments)
        fields.append(quoteExecForDesktop(argument));
    return fields.join(QLatin1Char(' '));
}

QByteArray hubAutostartDesktopEntry(const QString& nativeHubProgram) {
    const QByteArray exec = hubAutostartExecLine(nativeHubProgram).toUtf8();
    return QByteArrayLiteral(
               "[Desktop Entry]\n"
               "Type=Application\n"
               "Name=Xeneon Edge Linux Hub\n"
               "Comment=Native Linux widget platform for secondary touchscreen displays\n"
               "Exec=")
           + exec
           + QByteArrayLiteral(
               "\n"
               "Icon=xeneon-edge-hub\n"
               "Categories=Utility;\n"
               "Terminal=false\n"
               "X-GNOME-Autostart-enabled=true\n");
}

bool applyAutostartForProgram(
    bool enabled, const QString& nativeHubProgram,
    const AutostartAtomicWriteHooks& hooks) {
    // QStandardPaths, NOT QDir::homePath(): homePath ignores XDG_CONFIG_HOME, so
    // a sandboxed test hub (isolated XDG_CONFIG_HOME, real HOME) wrote its
    // autostart entry into the REAL ~/.config/autostart - with Exec pointing at a
    // throwaway worktree build - and a later cleanup deleted the user's genuine
    // entry alongside it. ConfigLocation honours the env, so isolation actually
    // isolates.
    const QString path = autostartEntryPath();
    const QString dir = QFileInfo(path).absolutePath();
    if (!enabled) {
        // Removing a non-existent entry is already "off" (success); otherwise
        // report whether the removal actually succeeded rather than lying true.
        const QFileInfo entryInfo(path);
        if (!entryInfo.exists() && !entryInfo.isSymLink())
            return true;
        return QFile::remove(path);
    }

    if (!ensureOwnerSafeDirectory(dir))
        return false;

    const QFileInfo existing(path);
    if (existing.isSymLink()
        || (existing.exists()
            && (!existing.isFile()
                || existing.ownerId() != static_cast<uint>(::geteuid())))) {
        qWarning() << "Refusing unsafe autostart entry:" << path;
        return false;
    }

    QSaveFile file(path);
    // Never fall back to truncating the destination in place. Failure must
    // leave the previously committed desktop entry byte-for-byte intact.
    file.setDirectWriteFallback(false);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "Could not write autostart entry:" << path;
        return false;
    }

    if (!file.setPermissions(kOwnerFilePermissions)) {
        qWarning() << "Could not secure autostart entry:" << path;
        file.cancelWriting();
        return false;
    }

    const QByteArray contents = hubAutostartDesktopEntry(nativeHubProgram);
    const qint64 written = hooks.write
                               ? hooks.write(file, contents)
                               : file.write(contents);
    if (written != contents.size() || file.error() != QFileDevice::NoError) {
        qWarning() << "Could not completely write autostart entry:" << path;
        file.cancelWriting();
        return false;
    }

    if (!file.flush()) {
        qWarning() << "Could not flush autostart entry:" << path;
        file.cancelWriting();
        return false;
    }

    const bool committed = hooks.commit ? hooks.commit(file) : file.commit();
    if (!committed) {
        qWarning() << "Could not atomically commit autostart entry:" << path;
        if (file.isOpen())
            file.cancelWriting();
        return false;
    }

    qInfo() << "Autostart entry written:" << path;
    return true;
}

bool applyAutostartForProgram(bool enabled, const QString& nativeHubProgram) {
    return applyAutostartForProgram(
        enabled, nativeHubProgram, AutostartAtomicWriteHooks{});
}

bool applyAutostart(bool enabled) {
    return applyAutostartForProgram(
        enabled, QCoreApplication::applicationFilePath());
}

bool isAutostartEnabled() {
    return QFile::exists(autostartEntryPath());
}
