#pragma once

#include <QDir>
#include <QLockFile>
#include <QStandardPaths>
#include <QString>

#include <memory>

// Single-instance guard. Running two hubs (or two managers) concurrently races
// the shared ~/.config/xeneon-edge-hub/config.toml and corrupts it (empty
// appearance, shuffled layout - observed with 2 hubs + 3 managers up at once).
// Each app acquires a per-app QLockFile; if another LIVE instance already holds
// it, the new process should exit. QLockFile auto-reclaims a lock whose owning
// PID is gone (crash recovery). Skipped in QA/grab mode (XENEON_GRAB) so headless
// captures still work even while a real instance is running.
namespace xeneon {

inline QString instanceLockPath(const QString& appKey) {
    QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (dir.isEmpty())
        dir = QDir::tempPath();
    return dir + QStringLiteral("/xeneon-edge-") + appKey + QStringLiteral(".lock");
}

// Returns an owned, HELD lock on success (keep it alive for the process lifetime);
// returns nullptr when this process should exit because another live instance
// already holds it. In grabMode it never blocks (QA/headless captures may run
// alongside a real instance). A brief timeout (default 1500ms) prevents an
// instantaneous exit if an old instance is in the middle of shutting down.
inline std::unique_ptr<QLockFile> acquireSingleInstance(const QString& appKey, bool grabMode, int timeoutMs = 1500) {
    auto lock = std::make_unique<QLockFile>(instanceLockPath(appKey));
    if (grabMode)
        return lock;                    // never block QA/headless captures
    if (lock->tryLock(timeoutMs))
        return lock;                    // acquired - we are the only instance
    return nullptr;                     // another live instance holds it
}

}  // namespace xeneon
