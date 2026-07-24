#ifndef CONTROL_SOCKET_PATH_H
#define CONTROL_SOCKET_PATH_H

// The one place that decides where the hub's control socket lives.
//
// Both ends of the IPC contract include this header - the hub's ControlServer
// (app/src/control_server.cpp) and the Manager's client
// (manager/src/manager_backend.h). It is a header, not a pair of constants,
// because the two sides MUST agree: when they drifted, they didn't fail loudly,
// they just stopped seeing each other.
//
// WHY AN ABSOLUTE PATH. A bare QLocalServer name (no '/') is resolved by Qt via
// QDir::tempPath(), i.e. /tmp - NOT $XDG_RUNTIME_DIR, whatever a comment may
// once have claimed here. That gave one shared, world-writable node per machine:
// any test run bound and removeServer()'d the same path as a live hub, unlinking
// its socket while it kept its listening fd (so it logged nothing and looked
// healthy while no client could reach it again), and any local user could
// pre-create or replace the node. Returning an absolute path under
// $XDG_RUNTIME_DIR - 0700 and per-user-session by definition - fixes both.

#include <QByteArray>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QString>

#include <cerrno>
#include <cstring>
#include <functional>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace xeneon {

inline QString controlSocketBasename() {
    return QStringLiteral("xeneon-edge-hub-ctl");
}

struct ControlSocketFs {
    QString tempPath = QDir::tempPath();
    uid_t uid = ::getuid();
    std::function<int(const char*, mode_t)> makeDir =
        [](const char* path, mode_t mode) { return ::mkdir(path, mode); };
    std::function<int(const char*, struct stat*)> statPath =
        [](const char* path, struct stat* out) { return ::lstat(path, out); };
};

// Log `msg` the first time this call site sees it. controlSocketPath() is called
// on every reconnect attempt, so an unconditional warning would bury the log of a
// Manager that is merely retrying. (A function-local static in an inline function
// is one object program-wide, so "once" really is once.)
#define XENEON_SOCKET_WARN_ONCE(msg)                     \
    do {                                                 \
        static bool warned_ = false;                     \
        if (!warned_) {                                  \
            warned_ = true;                              \
            qWarning() << (msg);                         \
        }                                                \
    } while (false)

// Fallback directory for the (rare) sessions with no XDG_RUNTIME_DIR - headless
// logins, `su`, some cron/systemd contexts. It must be per-user and not
// world-writable, so we do NOT drop the socket straight into /tmp as the old
// bare name did: we use a uid-suffixed subdirectory of the temp dir, created
// 0700, which is the same shape a runtime dir has and is deterministic from the
// uid alone (so both sides compute it identically without coordinating).
//
// Returns "" if the directory can't be created or is not a private directory we
// own - a squatted /tmp/xeneon-edge-hub-<uid> is exactly the hijack this change
// exists to prevent, so we refuse rather than bind into it.
inline QString controlSocketFallbackDir(const ControlSocketFs& fs) {
    const QString dir = fs.tempPath + QStringLiteral("/xeneon-edge-hub-") +
                        QString::number(static_cast<uint>(fs.uid));
    const QByteArray raw = QFile::encodeName(dir);

    if (fs.makeDir(raw.constData(), 0700) != 0 && errno != EEXIST) {
        XENEON_SOCKET_WARN_ONCE(QStringLiteral("ControlSocket: cannot create fallback dir ") +
                                dir + QStringLiteral(": ") + QString::fromLocal8Bit(::strerror(errno)));
        return QString();
    }
    // lstat, not stat: a symlink planted here would otherwise let someone aim
    // the socket at a directory we never vetted.
    struct stat st{};
    if (fs.statPath(raw.constData(), &st) != 0) {
        XENEON_SOCKET_WARN_ONCE(QStringLiteral("ControlSocket: cannot stat fallback dir ") + dir);
        return QString();
    }
    if (!S_ISDIR(st.st_mode)) {
        XENEON_SOCKET_WARN_ONCE(QStringLiteral("ControlSocket: refusing fallback dir ") + dir +
                                QStringLiteral(" - not a directory"));
        return QString();
    }
    if (st.st_uid != fs.uid) {
        XENEON_SOCKET_WARN_ONCE(QStringLiteral("ControlSocket: refusing fallback dir ") + dir +
                                QStringLiteral(" - owned by another user"));
        return QString();
    }
    if ((st.st_mode & 0077) != 0) {
        XENEON_SOCKET_WARN_ONCE(QStringLiteral("ControlSocket: refusing fallback dir ") + dir +
                                QStringLiteral(" - group or other access is enabled"));
        return QString();
    }
    return dir;
}

inline QString controlSocketFallbackDir() {
    return controlSocketFallbackDir(ControlSocketFs{});
}

// A Unix socket path must fit sockaddr_un::sun_path - 108 bytes including the
// NUL. Qt reports an overflow only as "QLocalServer::listen: Name error", which
// tells you nothing; diagnose it here instead. Real runtime dirs (/run/user/UID)
// leave ~70 bytes of headroom, so this fires for deep/unusual roots - e.g. a
// sandbox nested inside a build tree.
inline bool controlSocketPathFits(const QString& path) {
    return QFile::encodeName(path).size() < 108;
}

// Absolute filesystem path of the control socket, or "" if no safe location
// exists (callers must treat that as "IPC unavailable", not as a reason to fall
// back to a shared path).
inline QString controlSocketPathFor(const QString& runtimeDir,
                                    const ControlSocketFs& fs) {
    if (!runtimeDir.isEmpty()) {
        const QString path = QDir(runtimeDir).filePath(controlSocketBasename());
        if (!controlSocketPathFits(path)) {
            XENEON_SOCKET_WARN_ONCE(
                QStringLiteral("ControlSocket: XDG_RUNTIME_DIR yields a path too long for a "
                               "Unix socket (>107 bytes), live control disabled: ") + path);
            return QString();
        }
        return path;
    }

    // Never silently degrade to a shared location: say so, at the point of
    // decision, so a stranded Manager has a breadcrumb in the log.
    XENEON_SOCKET_WARN_ONCE(
        QStringLiteral("ControlSocket: XDG_RUNTIME_DIR is unset; falling back to a private "
                       "per-uid directory under ") + fs.tempPath);
    const QString dir = controlSocketFallbackDir(fs);
    if (dir.isEmpty())
        return QString();
    const QString path = QDir(dir).filePath(controlSocketBasename());
    if (!controlSocketPathFits(path)) {
        XENEON_SOCKET_WARN_ONCE(
            QStringLiteral("ControlSocket: fallback path is too long for a Unix socket: ") + path);
        return QString();
    }
    return path;
}

inline QString controlSocketPath() {
    return controlSocketPathFor(
        qEnvironmentVariable("XDG_RUNTIME_DIR"), ControlSocketFs{});
}

}  // namespace xeneon

#endif // CONTROL_SOCKET_PATH_H
