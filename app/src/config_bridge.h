#pragma once

#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

#include <cerrno>
#include <fcntl.h>
#include <functional>
#include <sys/stat.h>
#include <unistd.h>

#include "autostart.h"
#include "build_version.h"
#include "config_transaction.h"
#include "ui_state_recovery.h"
#include "xeneon_core.h"
#include "xeneon_string.h"

// Decide whether to migrate the hub window back onto a newly-added screen.
//   reconnectEnabled - the reconnect-on-hotplug preference (config.startup).
//   isTarget         - the added screen matches the hub's target (re-run of the match).
inline bool shouldReconnectToScreen(bool reconnectEnabled, bool isTarget) {
    return reconnectEnabled && isTarget;
}

// --- WizardBridge: QObject exposed to QML for first-run persistence ---

class WizardBridge : public QObject {
    Q_OBJECT
public:
    explicit WizardBridge(ConfigHandle* config, QObject* parent = nullptr)
        : QObject(parent), m_config(config) {}

    Q_INVOKABLE bool completeWizard(const QString& edidHash, const QString& connector,
                                     const QString& model, const QString& layout,
                                     const QString& themeMode, const QString& themeAccent,
                                     bool autostart, bool reconnect, bool notifyDisconnect) {
        if (!m_config) return false;
        ConfigTransaction transaction(m_config);
        if (!transaction) return false;
        ConfigHandle* candidate = transaction.candidate();
        bool mutated = true;

        // Persist display identity
        if (!edidHash.isEmpty())
            mutated = mutated
                      && xeneon_config_set_target_edid_hash(
                             candidate, edidHash.toUtf8().constData()) == 0;
        if (!connector.isEmpty())
            mutated = mutated
                      && xeneon_config_set_target_connector(
                             candidate, connector.toUtf8().constData()) == 0;
        if (!model.isEmpty())
            mutated = mutated
                      && xeneon_config_set_target_model(
                             candidate, model.toUtf8().constData()) == 0;

        // Persist layout choice
        if (!layout.isEmpty())
            mutated = mutated
                      && xeneon_config_set_starter_layout(
                             candidate, layout.toUtf8().constData()) == 0;

        // Persist theme
        if (!themeMode.isEmpty())
            mutated = mutated
                      && xeneon_config_set_theme_mode(
                             candidate, themeMode.toUtf8().constData()) == 0;
        if (!themeAccent.isEmpty())
            mutated = mutated
                      && xeneon_config_set_theme_accent(
                             candidate, themeAccent.toUtf8().constData()) == 0;

        // Persist startup preferences
        mutated = mutated
                  && xeneon_config_set_autostart(candidate, autostart ? 1 : 0) == 0;
        mutated = mutated
                  && xeneon_config_set_reconnect(candidate, reconnect ? 1 : 0) == 0;
        mutated = mutated
                  && xeneon_config_set_notify_disconnect(
                         candidate, notifyDisconnect ? 1 : 0) == 0;

        // Mark first-run complete only inside the isolated candidate.
        mutated = mutated
                  && xeneon_config_set_first_run_complete(candidate) == 0;
        if (!mutated)
            return false;

        // The config and the effective XDG entry are a compensated transaction.
        // If either half fails, preserve the previous live config and restore the
        // previous effective entry state.
        const bool previousAutostart = isAutostartEnabled();
        if (!applyAutostart(autostart))
            return false;

        const bool saved = transaction.commit();
        if (saved) {
            if (transaction.durabilityUncertain())
                emit persistenceWarning(QStringLiteral(
                    "Settings were saved, but storage could not confirm crash durability."));
            qInfo() << "Wizard complete. Target:" << model << "Layout:" << layout
                     << "Theme:" << themeMode << "Autostart:" << autostart;
        } else {
            const bool restored = applyAutostart(previousAutostart);
            qWarning() << "Wizard config save failed; autostart restored:" << restored;
        }
        return saved;
    }

    // Detach from the Rust config handle before it is freed at shutdown, so any
    // late QML call becomes a guarded no-op instead of a use-after-free.
    void detach() { m_config = nullptr; }

signals:
    void persistenceWarning(const QString& message);

private:
    ConfigHandle* m_config;
};

// --- ConfigBridge: runtime config access for QML (layout persistence, etc.) ---

class ConfigBridge : public QObject {
    Q_OBJECT
public:
    struct MetricFileOps {
        std::function<int(const char*, int)> openFile =
            [](const char* path, int flags) { return ::open(path, flags); };
        std::function<int(int, struct stat*)> statFile =
            [](int fd, struct stat* out) { return ::fstat(fd, out); };
        std::function<ssize_t(int, void*, size_t)> readFile =
            [](int fd, void* bytes, size_t size) {
                return ::read(fd, bytes, size);
            };
        std::function<int(int)> closeFile =
            [](int fd) { return ::close(fd); };
    };

    explicit ConfigBridge(ConfigHandle* config, QObject* parent = nullptr)
        : QObject(parent), m_config(config) {}

    // Opaque UI-state JSON (dashboard layout + per-widget settings + appearance).
    // Product builds include the generated git-describe version; explicit
    // packaging overrides remain authoritative. Logic-only builds fall back to
    // "dev" without needing a configured build tree.
    Q_INVOKABLE QString appVersion() const {
#ifdef XENEON_VERSION
        return QStringLiteral(XENEON_VERSION);
#else
        return QStringLiteral("dev");
#endif
    }

    Q_INVOKABLE QString uiState() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_ui_state(m_config));
        return s.qstring();
    }

    // Opaque, process-local equality token for the persisted config generation.
    // It is random and carries no config digest or private data.
    QString configGenerationToken() const {
        if (!m_config) return QString();
        XeneonString token(xeneon_config_generation_token(m_config));
        return token.qstring();
    }

    // Persist the UI-state JSON and flush to disk atomically. Returns success.
    Q_INVOKABLE bool saveUiState(const QString& json) {
        if (!m_config) return false;
        ConfigTransaction transaction(m_config);
        if (!transaction
            || xeneon_config_set_ui_state(
                   transaction.candidate(), json.toUtf8().constData()) != 0) {
            qWarning() << "Rejected invalid or unsupported UI state";
            return false;
        }
        const bool ok = transaction.commit();
        if (ok && transaction.durabilityUncertain())
            emit persistenceWarning(QStringLiteral(
                "The layout is visible on disk, but storage could not confirm crash durability."));
        if (!ok) qWarning() << "Failed to persist UI state";
        return ok;
    }

    // Apply a UI-state document pushed from the companion Manager app over IPC:
    // persist it to the in-memory config + disk. The live reload is handled by
    // main() re-pushing the JSON to QML. Kept separate from saveUiState so intent
    // is explicit at the call site.
    bool applyExternalUiState(const QString& json) {
        if (!m_config || json.isEmpty()) return false;
        if (!externalUiStateAllowed()) {
            qWarning() << "Rejected external UI state while a managed preset is forced";
            return false;
        }
        ConfigTransaction transaction(m_config);
        if (!transaction
            || xeneon_config_set_ui_state(
                   transaction.candidate(), json.toUtf8().constData()) != 0) {
            qWarning() << "Rejected invalid or unsupported external UI state";
            return false;
        }
        const bool ok = transaction.commit();
        if (ok && transaction.durabilityUncertain())
            emit persistenceWarning(QStringLiteral(
                "The Manager layout was published, but storage could not confirm crash durability."));
        return ok;
    }

    bool externalUiStateAllowed() const {
        return policy().value(QStringLiteral("forcePreset")).toString().isEmpty();
    }

    Q_INVOKABLE QString exportUiStateRecovery(const QString& json) const {
        XeneonString directory(xeneon_config_dir());
        return xeneon::exportUiStateRecovery(directory.qstring(), json);
    }

    // Starter layout id chosen during the wizard ("productivity"/"gaming"/…).
    Q_INVOKABLE QString starterLayout() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_starter_layout(m_config));
        return s.qstring();
    }

    // Resolve a wallpaper/image path to a loadable URL. Scheme URLs (qrc:, http:,
    // file:) pass through untouched; a local path is percent-encoded via QUrl so
    // spaces / '#' / other reserved characters don't produce a malformed URL that
    // silently fails to load. Mirrors the Manager's backend.imageUrl() so the same
    // stored appearance.wallpaper resolves identically in the hub and the Manager.
    Q_INVOKABLE QString imageUrl(const QString& path) const {
        if (path.isEmpty()) return QString();
        if (path.contains("://")) return path;
        if (path.startsWith('/')) return QUrl::fromLocalFile(path).toString();
        return path;
    }

    // Display hotplug preferences (S10) - read by the hub's QScreen handlers and
    // available to QML for the Display/Diagnostics surfaces. These mirror the three
    // formerly write-only keys so QML can render + honor them.
    Q_INVOKABLE bool reconnectOnHotplug() const {
        if (!m_config) return false;
        return xeneon_config_get_reconnect(m_config) == 1;
    }
    Q_INVOKABLE bool notifyOnDisconnect() const {
        if (!m_config) return false;
        return xeneon_config_get_notify_disconnect(m_config) == 1;
    }
    // "hide" | "notify" | "ask" (empty only if detached).
    Q_INVOKABLE QString fallbackBehavior() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_fallback_behavior(m_config));
        return s.qstring();
    }

    // Non-reversible config summary for Diagnostics. The Rust boundary omits
    // bearer keys, identity, private URLs and all arbitrary widget/UI content.
    Q_INVOKABLE QString configJson() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_to_json(m_config));
        return s.qstring();
    }

    // --- Tier-0 user widgets (E3) ----------------------------------------------
    // The stable user-QML load directory. QML cannot enumerate directories or
    // read arbitrary files, so the hub scans here and hands the RAW material to
    // QML; all validation (docs/widgets/manifest-spec.md) lives in
    // ui/qml/UserWidgetCatalog.qml, where it runs in the offscreen test suite.
    //
    // SECURITY NOTE: these helpers only LIST and READ. Whether anything is
    // loaded is decided in QML by the `enableUserWidgets` flag (default OFF) -
    // callers gate on the flag BEFORE invoking listUserWidgets(), so the
    // attested default configuration performs no scan at all.
    static QString userWidgetsRoot() {
        QString dataHome = qEnvironmentVariable("XDG_DATA_HOME");
        if (dataHome.isEmpty())
            dataHome = QDir::homePath() + QStringLiteral("/.local/share");
        return dataHome + QStringLiteral("/xeneon-edge-hub/widgets");
    }
    Q_INVOKABLE QString userWidgetsDir() const { return userWidgetsRoot(); }

    // One compact JSON string per SUBDIRECTORY of the widgets dir (name order):
    //   { "dir": <abs path>, "dirName": <name>, "files": [top-level file names],
    //     "manifest": "<raw manifest.json text>" }
    // or, when the manifest is missing/unreadable/oversized:
    //   { "dir": ..., "dirName": ..., "files": [...], "error": "<why>" }
    // Deliberately dumb - no parsing, no validation, no recursion: the
    // filesystem scan is the only part QML cannot do, so it is the only part
    // done here. A missing root directory is simply an empty list.
    Q_INVOKABLE QStringList listUserWidgets() const {
        QStringList out;
        QDir root(userWidgetsRoot());
        if (!root.exists())
            return out;
        const QFileInfoList subs =
            root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        for (const QFileInfo& sub : subs) {
            QJsonObject o;
            o[QStringLiteral("dir")] = sub.absoluteFilePath();
            o[QStringLiteral("dirName")] = sub.fileName();
            QJsonArray files;
            const QStringList names =
                QDir(sub.absoluteFilePath()).entryList(QDir::Files, QDir::Name);
            for (const QString& n : names)
                files.append(n);
            o[QStringLiteral("files")] = files;
            QFile mf(sub.absoluteFilePath() + QStringLiteral("/manifest.json"));
            if (!mf.exists()) {
                o[QStringLiteral("error")] = QStringLiteral("missing manifest.json");
            } else if (mf.size() > 256 * 1024) {
                o[QStringLiteral("error")] = QStringLiteral("manifest.json larger than 256 KiB");
            } else if (!mf.open(QIODevice::ReadOnly)) {
                o[QStringLiteral("error")] = QStringLiteral("manifest.json is not readable");
            } else {
                o[QStringLiteral("manifest")] = QString::fromUtf8(mf.readAll());
            }
            out << QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
        }
        return out;
    }

    // --- Secrets (E7 Phase A) -------------------------------------------------
    // Resolve a stored credential ("${env:VAR}", "file:/path", or a legacy
    // plaintext literal) to the value to send. QML cannot read the process
    // environment, so this must come from the core; keeping it here also means the
    // resolved value exists only for the life of one request and never reaches
    // DashboardStore → ui_state → config.toml.
    //
    // Returns { ok, value, error, plaintext }. `plaintext` is true when the stored
    // value is a bare secret, so the UI can warn without the caller re-parsing it.
    // An empty input is a success with an empty value (an unconfigured widget just
    // sends no Authorization header) - NOT an error.
    Q_INVOKABLE QVariantMap resolveSecret(const QString& raw) const {
        return resolveSecretValue(raw);
    }

    static QVariantMap resolveSecretValue(const QString& raw) {
        QVariantMap r;
        r["ok"] = false;
        r["value"] = QString();
        r["error"] = QString();
        r["plaintext"] = false;
        if (raw.isEmpty()) {
            r["ok"] = true;
            return r;
        }
        const QByteArray rawUtf8 = raw.toUtf8();
        r["plaintext"] = xeneon_secret_is_plaintext(rawUtf8.constData()) == 1;

        char* errRaw = nullptr;
        XeneonString value(xeneon_secret_resolve(rawUtf8.constData(), &errRaw));
        XeneonString err(errRaw);   // owned even on success (then null) - RAII frees both.
        if (value) {
            r["ok"] = true;
            r["value"] = value.qstring();
        } else {
            r["error"] = err.qstring();
        }
        return r;
    }

    // Read one local KPI metric without giving QML general filesystem access.
    // The public invokable has a fixed allowlist. The roots-taking overload is a
    // deterministic test seam and is intentionally not invokable.
    Q_INVOKABLE QVariantMap readMetricFile(const QString& rawPath) const {
        return readMetricFileFromRoots(
            rawPath,
            {QStringLiteral("/run"), QStringLiteral("/var/run"),
             QStringLiteral("/proc"), QStringLiteral("/sys")});
    }

    static QVariantMap readMetricFileFromRoots(const QString& rawPath,
                                               const QStringList& approvedRoots) {
        return readMetricFileFromRootsWithOps(
            rawPath, approvedRoots, MetricFileOps{});
    }

    static QVariantMap readMetricFileFromRootsWithOps(
        const QString& rawPath, const QStringList& approvedRoots,
        const MetricFileOps& ops) {
        auto fail = [](const QString& code, const QString& message) {
            return QVariantMap{{QStringLiteral("ok"), false},
                               {QStringLiteral("body"), QString()},
                               {QStringLiteral("error"), code},
                               {QStringLiteral("message"), message}};
        };
        QString path = rawPath.trimmed();
        if (path.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive)) {
            const QUrl url(path);
            if (!url.isLocalFile() || !url.host().isEmpty())
                return fail(QStringLiteral("invalid-path"),
                            QStringLiteral("Use an absolute local file path."));
            path = url.toLocalFile();
        }
        if (path.isEmpty() || path.contains(QChar::Null) || !QFileInfo(path).isAbsolute())
            return fail(QStringLiteral("invalid-path"),
                        QStringLiteral("Use an absolute local file path."));
        const QString slashPath = QDir::fromNativeSeparators(path);
        if (slashPath.contains(QStringLiteral("/../")) ||
            slashPath.endsWith(QStringLiteral("/..")) ||
            slashPath.contains(QStringLiteral("/./")) ||
            slashPath.endsWith(QStringLiteral("/."))) {
            return fail(QStringLiteral("traversal"),
                        QStringLiteral("Parent and current-directory segments are not allowed."));
        }

        const QFileInfo candidate(path);
        const QString canonical = candidate.canonicalFilePath();
        if (canonical.isEmpty())
            return fail(QStringLiteral("not-found"),
                        QStringLiteral("The metric file does not exist."));

        bool inside = false;
        for (const QString& rawRoot : approvedRoots) {
            QString root = QFileInfo(rawRoot).canonicalFilePath();
            if (root.isEmpty())
                root = QDir::cleanPath(rawRoot);
            if (canonical == root || canonical.startsWith(root + QLatin1Char('/'))) {
                inside = true;
                break;
            }
        }
        if (!inside)
            return fail(QStringLiteral("outside-approved-roots"),
                        QStringLiteral("Metric files must stay under an approved system metric directory."));

        const QByteArray encoded = QFile::encodeName(path);
        const int fd = ops.openFile(
            encoded.constData(),
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0)
            return fail(errno == ELOOP ? QStringLiteral("symlink")
                                       : QStringLiteral("unreadable"),
                        errno == ELOOP
                            ? QStringLiteral("Symbolic-link metric files are not allowed.")
                            : QStringLiteral("The metric file could not be opened."));

        struct stat st {};
        if (ops.statFile(fd, &st) != 0) {
            ops.closeFile(fd);
            return fail(QStringLiteral("unreadable"),
                        QStringLiteral("The metric file could not be inspected."));
        }
        if (!S_ISREG(st.st_mode)) {
            ops.closeFile(fd);
            return fail(QStringLiteral("not-regular-file"),
                        QStringLiteral("The path must be a regular file."));
        }
        constexpr qint64 kMaxBytes = 1024 * 1024;
        if (st.st_size > kMaxBytes) {
            ops.closeFile(fd);
            return fail(QStringLiteral("too-large"),
                        QStringLiteral("Metric files may be at most 1 MiB."));
        }

        QByteArray bytes;
        bytes.reserve(st.st_size > 0 ? int(st.st_size) : 4096);
        char chunk[8192];
        while (true) {
            const ssize_t got = ops.readFile(fd, chunk, sizeof(chunk));
            if (got == 0)
                break;
            if (got < 0) {
                if (errno == EINTR)
                    continue;
                ops.closeFile(fd);
                return fail(QStringLiteral("unreadable"),
                            QStringLiteral("The metric file could not be read."));
            }
            if (qint64(bytes.size()) + qint64(got) > kMaxBytes) {
                ops.closeFile(fd);
                return fail(QStringLiteral("too-large"),
                            QStringLiteral("Metric files may be at most 1 MiB."));
            }
            bytes.append(chunk, qsizetype(got));
        }
        ops.closeFile(fd);
        return QVariantMap{{QStringLiteral("ok"), true},
                           {QStringLiteral("body"), QString::fromUtf8(bytes)},
                           {QStringLiteral("error"), QString()},
                           {QStringLiteral("message"), QString()}};
    }

    // --- Managed / org policy (E9) --------------------------------------------
    // The effective org policy, as one QVariantMap (mirrors resolveSecret: the
    // FFI answers, the bridge shapes it for QML). Keys - always all present:
    //   active               bool   false only when NO policy file exists
    //   source               string "absent" | "policy" | "fail-closed"
    //   reason               string non-empty only for fail-closed
    //   forcePreset          string layout locked to this preset ("" = none)
    //   netOffline           bool   pins NetHub's kill switch on
    //   allowedHosts         list   pins NetHub.allowHosts (empty = no pin)
    //   disableUserWidgets   bool   pins the E3 user-widget loader flag off
    //   disabledWidgetTypes  list   hidden from the picker, never rendered
    //
    // Deliberately INDEPENDENT of m_config (no detach guard): policy comes from
    // /etc (or $XENEON_POLICY_PATH - a test-only seam), not from the user's
    // config handle. Cached: the file is root-owned and static per launch, and
    // QML bindings would otherwise re-read it on every evaluation.
    //
    // Never log the returned map wholesale - allowedHosts may name internal
    // infrastructure (same discipline as core/src/secrets.rs).
    static QVariantMap policyFromJson(const QString& json) {
        const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
        QVariantMap p = doc.object().toVariantMap();
        if (!p.contains("active")) {
            qWarning() << "Policy FFI returned an unusable answer; failing closed";
            p.clear();
            p["active"] = true;
            p["source"] = QStringLiteral("fail-closed");
            p["reason"] = QStringLiteral("policy FFI returned an unusable answer");
            p["forcePreset"] = QString();
            p["netOffline"] = true;
            p["allowedHosts"] = QVariantList();
            p["disableUserWidgets"] = true;
            p["disabledWidgetTypes"] = QVariantList();
        }
        return p;
    }

    Q_INVOKABLE QVariantMap policy() const {
        if (m_policyLoaded) return m_policy;
        XeneonString s(xeneon_policy_json());
        m_policy = policyFromJson(s.qstring());
        m_policyLoaded = true;
        return m_policy;
    }

    // Detach from the Rust config handle before it is freed at shutdown, so any
    // late QML call becomes a guarded no-op instead of a use-after-free.
    void detach() { m_config = nullptr; }

signals:
    void persistenceWarning(const QString& message);

private:
    ConfigHandle* m_config;
    mutable bool m_policyLoaded = false;
    mutable QVariantMap m_policy;
};
