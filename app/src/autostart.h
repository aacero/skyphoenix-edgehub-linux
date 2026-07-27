#pragma once

#include <QByteArray>
#include <QSaveFile>
#include <QString>
#include <QStringList>

#include <functional>

struct HubLaunchCommand {
    QString program;
    QStringList arguments;
};

// Injectable atomic-write operations. Production uses QSaveFile::write() and
// QSaveFile::commit(); focused tests replace either operation to prove that a
// failed update never destroys the previously published desktop entry.
struct AutostartAtomicWriteHooks {
    std::function<qint64(QSaveFile&, const QByteArray&)> write;
    std::function<bool(QSaveFile&)> commit;
};

// Quote an Exec program path per the freedesktop .desktop spec: paths containing a
// space must be wrapped in double quotes, otherwise the Exec line parses as multiple
// arguments. Returned unchanged when there is no space. Extracted as a testable seam.
QString quoteExecForDesktop(const QString& execPath);

// AppImages execute binaries from an ephemeral /tmp/.mount directory. When the
// runtime provides APPIMAGE, always relaunch the persistent original image with
// the Hub dispatcher. Native installs keep using their supplied Hub program.
HubLaunchCommand hubLaunchCommand(const QString& nativeHubProgram);

// Render the same launch command as one freedesktop Exec value.
QString hubAutostartExecLine(const QString& nativeHubProgram);

// Render the exact UTF-8 bytes written by both the Hub and Manager.
QByteArray hubAutostartDesktopEntry(const QString& nativeHubProgram);

// Install/remove the shared XDG entry for a specific native Hub program. This
// is the Manager-facing form; it still uses APPIMAGE when the current process
// was launched from a persistent AppImage.
bool applyAutostartForProgram(bool enabled, const QString& nativeHubProgram);
bool applyAutostartForProgram(bool enabled, const QString& nativeHubProgram,
                              const AutostartAtomicWriteHooks& hooks);

// Install/remove the hub's XDG autostart .desktop entry
// (~/.config/autostart/xeneon-edge-hub.desktop) pointing at the current binary,
// so "start on login" actually takes effect.
//
// Returns true on success. When disabling, returns the real QFile::remove result
// (or true if the entry didn't exist) rather than optimistically claiming success.
bool applyAutostart(bool enabled);

// Effective state, derived from the XDG entry rather than the config flag.
bool isAutostartEnabled();
