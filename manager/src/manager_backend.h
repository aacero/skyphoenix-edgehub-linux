#pragma once

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QStandardPaths>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <QProcess>
#include <QScreen>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QUrl>

#include <functional>

#include "path_sanitize.h"
#include "reconcile.h"
#include "manager_hub_launch.h"
#include "xeneon_core.h"
#include "../../app/src/build_version.h"
// The hub owns the socket-path contract; both ends must resolve it identically,
// so this is included rather than restated. (Same relative-include shape the
// Manager's main.cpp already uses for single_instance.h / timezone_bridge.h.)
#include "../../app/src/control_socket_path.h"
#include "../../app/src/autostart.h"
#include "../../app/src/config_bridge.h"
#include "../../app/src/config_transaction.h"
#include "../../app/src/control_protocol.h"
#include "../../app/src/single_instance.h"
#include "../../app/src/ui_state_recovery.h"

// --- ManagerBackend ---
// Presents the SAME interface the hub's ConfigBridge exposes (uiState/
// saveUiState/starterLayout/configJson) so the shared DashboardStore.qml drives
// it unchanged, plus display/image/startup operations and LIVE two-way sync with
// a running hub (push our edits + pull the hub's over the control socket, plus a
// file watcher for the offline case).
class ManagerBackend : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool hubConnected READ hubConnected NOTIFY hubConnectedChanged)
    Q_PROPERTY(bool layoutLiveApplied READ layoutLiveApplied NOTIFY layoutLiveAppliedChanged)
    // The panel's live content rotation (0/90/180/270, or -1 unknown), pulled from
    // the hub with the periodic getUiState. Lets the Manager's Edge preview mirror
    // the panel's orientation when it is physically turned (auto mode).
    Q_PROPERTY(int hubRotation READ hubRotation NOTIFY hubRotationChanged)
    Q_PROPERTY(int hubCurrentPage READ hubCurrentPage NOTIFY hubCurrentPageChanged)
public:
    explicit ManagerBackend(
        QObject* parent = nullptr, bool managerInjectedQtPlatform = false)
        : QObject(parent),
          m_managerInjectedQtPlatform(managerInjectedQtPlatform) {
        m_config = xeneon_config_load();
        if (!m_config)
            qCritical() << "Manager: failed to load config";   // GCOVR_EXCL_LINE (defensive; core never fails to load a default config)

        XeneonString cd(xeneon_config_dir());
        m_configPath = cd.qstring() + "/config.toml";

        m_sock = new QLocalSocket(this);
        connect(m_sock, &QLocalSocket::connected, this, [this] {
            m_hubConnected = true;
            m_hubUiStateReceiptLogged = false;
            m_connectedSessionNeedsReload = true;
            // Generation tokens are process-local. A restarted Hub can begin a
            // new token namespace, so the first reply on every connection must
            // establish a fresh baseline.
            m_lastHubConfigGenerationToken.clear();
            emit hubConnectedChanged();
            // Correct reconnect order: PULL the hub's authoritative state FIRST,
            // then reconcile any edit buffered while the socket was down against it
            // (in onSocketReadyRead, when the reply arrives) before pushing.
            // Flushing the buffered edit here - BEFORE pulling - would clobber edits
            // made on the device while the Manager was offline.
            if (!m_pendingPush.isEmpty())
                m_pendingPushAwaitingHub = true;
            syncFromHub();
        });
        connect(m_sock, &QLocalSocket::disconnected, this,
                [this] { handleHubDisconnect(); });
        connect(m_sock, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
            // A failed initial connection has never owned config.toml and needs
            // no reload. For an established socket, disconnected normally
            // follows. Some platform backends enter UnconnectedState directly,
            // so use the same idempotent path in that case.
            if (m_sock->state() == QLocalSocket::UnconnectedState)
                handleHubDisconnect();
        });
        connect(m_sock, &QLocalSocket::readyRead, this, &ManagerBackend::onSocketReadyRead);

        // Reconnect loop so the "connected" indicator recovers when the hub starts
        // AFTER the Manager (or restarts) - the ctor connect alone isn't enough.
        auto* reconnect = new QTimer(this);
        reconnect->setInterval(2000);
        connect(reconnect, &QTimer::timeout, this, [this] { tryConnectHub(); });
        reconnect->start();

        // A short local pull keeps device-side edits visibly live in the Manager.
        // getUiState is a tiny local-socket message and QML reloads only when the
        // state differs, so 500 ms gives WYSIWYG feedback without repaint churn.
        auto* pull = new QTimer(this);
        pull->setInterval(500);
        connect(pull, &QTimer::timeout, this, [this] { syncFromHub(); });
        pull->start();

        // Watch the config file so an OFFLINE external change (e.g. hub shutdown
        // save) is reflected. When the hub is connected we prefer getUiState.
        m_watcher = new QFileSystemWatcher(this);
        if (QFile::exists(m_configPath)) m_watcher->addPath(m_configPath);
        // Also watch the containing directory so that if config.toml does NOT exist
        // yet at startup, we arm the file watch the moment it first appears - without
        // this, later external writes to a config that was initially absent go unseen.
        const QString cfgDir = QFileInfo(m_configPath).absolutePath();
        QDir().mkpath(cfgDir);
        if (QFile::exists(cfgDir)) m_watcher->addPath(cfgDir);
        connect(m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] {
            if (m_watcher->files().contains(m_configPath) || !QFile::exists(m_configPath))
                return;                       // already armed, or still absent
            m_watcher->addPath(m_configPath); // config just appeared - arm the watch
            if (m_nowMs() < m_ignoreWatchUntilMs) return;
            if (m_hubConnected) return;
            handleOfflineExternalConfigChange(); // pick up the just-created config  // GCOVR_EXCL_LINE (offline external-change reload = inotify/timing glue)
        });
        connect(m_watcher, &QFileSystemWatcher::fileChanged, this, [this] {
            // Atomic saves rename over the file and drop the watch - re-add it.
            QTimer::singleShot(60, this, [this] {
                if (!m_watcher->files().contains(m_configPath) && QFile::exists(m_configPath))
                    m_watcher->addPath(m_configPath);
                if (m_nowMs() < m_ignoreWatchUntilMs) return; // our own write
                if (m_hubConnected) return;   // IPC keeps us in sync when connected  // GCOVR_EXCL_LINE
                handleOfflineExternalConfigChange();                                  // GCOVR_EXCL_LINE (offline external-change reload = inotify/timing glue)
            });
        });

        // Live display hotplug → Display tab refresh.
        connect(qApp, &QGuiApplication::screenAdded, this, [this](QScreen*) { emit screensChanged(); });
        connect(qApp, &QGuiApplication::screenRemoved, this, [this](QScreen*) { emit screensChanged(); });

        tryConnectHub();
    }
    ~ManagerBackend() override {                    // GCOVR_EXCL_START (dtor teardown; brace-only lines gcov mis-attributes)
        if (m_config) xeneon_config_free(m_config);
    }                                               // GCOVR_EXCL_STOP

    bool configAvailable() const { return m_config != nullptr; }

    // Inject a deterministic clock (milliseconds-since-epoch) so the suppression
    // windows are testable with zero real waiting. Defaults to the wall clock.
    void setClockForTest(std::function<qint64()> nowMs) { m_nowMs = std::move(nowMs); }
    void setOfflineExternalChangePreflight(std::function<bool()> preflight) {
        m_offlineExternalChangePreflight = std::move(preflight);
    }
    void setLocalUiStatePendingProbe(std::function<bool()> probe) {
        m_localUiStatePendingProbe = std::move(probe);
    }

    // Test seam: expose the pending RX buffer size so a flood test can assert the
    // cap holds without reaching into private state. Not used in production.
    int rxBufferSizeForTest() const { return m_rxBuf.size(); }
    bool hasPendingUiStateForTest() const { return !m_pendingPush.isEmpty(); }
    QString pendingUiStateForTest() const { return m_pendingPush; }
    int configDiskGenerationProbeCountForTest() const {
        return m_configDiskGenerationProbeCount;
    }
    QString lastHubConfigGenerationTokenForTest() const {
        return m_lastHubConfigGenerationToken;
    }

    bool hubConnected() const { return m_hubConnected; }
    bool layoutLiveApplied() const { return m_layoutLiveApplied; }
    int hubRotation() const { return m_hubRotation; }
    int hubCurrentPage() const { return m_hubCurrentPage; }
    Q_INVOKABLE void setLayoutSavePending(bool pending) {
        m_layoutSavePending = pending;
    }
    Q_INVOKABLE bool preparePendingLayoutRetry() {
        if (!m_externalConfigConflictPending)
            return true;

        // Retry is an explicit "keep my Manager document" decision. Rebase the
        // local handle on the latest disk generation first when the Hub is not
        // the writer, but do not emit configChanged: that would replace the
        // document the user just chose to keep.
        if (!m_hubConnected) {
            ConfigHandle* fresh = xeneon_config_load();
            if (!fresh) {
                emit saveError(QStringLiteral(
                    "The latest configuration could not be loaded for retry"));
                return false;
            }
            if (m_config)
                xeneon_config_free(m_config);
            m_config = fresh;
        }
        m_externalConfigConflictPending = false;
        return true;
    }
    Q_INVOKABLE void discardLocalAndReload() {
        m_externalConfigConflictPending = false;
        m_discardAwaitingHubState = false;
        reloadConfig();
    }
    Q_INVOKABLE void discardPendingLayoutAndSync() {
        clearPendingUiState();
        m_pendingPushAwaitingHub = false;
        m_externalConfigConflictPending = false;
        m_layoutSavePending = false;
        // The QML store deliberately remains dirty until a Hub reply supplies
        // the authoritative document. Bypass that local-pending guard exactly
        // once and emit configChanged even if this backend handle already happens
        // to contain the Hub bytes, so Discard cannot leave stale QML state alive.
        m_discardAwaitingHubState = true;
        syncFromHub();
    }

    // Launch the hub if it isn't already running. Returns false only when the
    // launch could not be started (missing binary). If a hub is already up (or
    // we're mid-connect to one), it's a no-op success - avoids a double instance.
    Q_INVOKABLE bool startHub() {
        if (m_hubConnected || m_sock->state() == QLocalSocket::ConnectedState)
            return true;
        // A hub may be running that we simply haven't connected to yet (e.g. the
        // Manager just started). Probe synchronously before spawning a duplicate.
        {
            QLocalSocket probe;
            probe.connectToServer(xeneon::controlSocketPath());
            if (probe.waitForConnected(250)) {
                probe.disconnectFromServer();
                tryConnectHub();
                return true;
            }
        }
        // GCOVR_EXCL_START (QProcess-launch glue: spawns the real hub binary + timed
        // reconnect nudges; the "already reachable" probe path above IS tested).
        const HubLaunchCommand command = hubLaunchCommand(hubBinaryPath());
        const bool ok =
            startHubDetached(command, m_managerInjectedQtPlatform);
        if (!ok) {
            qWarning() << "Manager: failed to launch hub" << command.program;
            return false;
        }
        // The hub needs a moment to come up and listen; nudge the connection a few
        // times so the "connected" state (and Stop button) appears promptly.
        for (int delay : {300, 700, 1200, 2000})
            QTimer::singleShot(delay, this, [this] { tryConnectHub(); });
        return true;
        // GCOVR_EXCL_STOP
    }

    // O1 - tell the hub which screen the Manager has selected, so the panel
    // mirrors what the user is editing instead of always showing the first page.
    // Fire-and-forget over the live socket; a no-op when the hub is offline (the
    // Manager still works standalone). The hub clamps out-of-range indices.
    Q_INVOKABLE void setHubActivePage(int page) {
        if (m_sock->state() != QLocalSocket::ConnectedState) return;
        writeMsg(QJsonObject{{"type", "setActivePage"},
                             {"page", page},
                             {"requestId", nextRequestId()}});
    }

    // Ask a running hub to quit cleanly over the control socket. Returns false if
    // no hub is reachable to stop.
    Q_INVOKABLE bool stopHub() {
        if (m_sock->state() != QLocalSocket::ConnectedState) return false;
        writeMsg(QJsonObject{{"type", "shutdown"},
                             {"requestId", nextRequestId()}});
        m_sock->flush();
        return true;
    }

    // Dev/doc affordances (headless capture) - compiled in only under
    // XENEON_QA_HOOKS; return inert defaults in production packages.
#ifdef XENEON_QA_HOOKS
    Q_INVOKABLE QString grabPath() const { return qEnvironmentVariable("XENEON_GRAB"); }
    Q_INVOKABLE int startTab() const { return qEnvironmentVariable("XENEON_TAB", "0").toInt(); }
    Q_INVOKABLE QString autoConfig() const { return qEnvironmentVariable("XENEON_CFG"); }
#else
    Q_INVOKABLE QString grabPath() const { return QString(); }
    Q_INVOKABLE int startTab() const { return 0; }
    Q_INVOKABLE QString autoConfig() const { return QString(); }
#endif

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

    // Live system metrics (same source + JSON shape the hub uses).
    Q_INVOKABLE QString metricsJson() const {
        MetricsHandle* m = xeneon_metrics_collect();
        if (!m) return QStringLiteral("{}");
        XeneonString s(xeneon_metrics_to_json(m));
        xeneon_metrics_free(m);
        return s.qstring();
    }

    // Match the Hub's managed-policy, secret-reference, and local-metric
    // surfaces. Manager connection tests must never bypass an organisation's
    // egress policy or disagree with what the same widget can read on the Hub.
    Q_INVOKABLE QVariantMap policy() const {
        if (m_policyLoaded) return m_policy;
        XeneonString value(xeneon_policy_json());
        m_policy = ConfigBridge::policyFromJson(value.qstring());
        m_policyLoaded = true;
        return m_policy;
    }

    Q_INVOKABLE QVariantMap resolveSecret(const QString& raw) const {
        return ConfigBridge::resolveSecretValue(raw);
    }

    Q_INVOKABLE QVariantMap readMetricFile(const QString& rawPath) const {
        return ConfigBridge::readMetricFileFromRoots(
            rawPath,
            {QStringLiteral("/run"), QStringLiteral("/var/run"),
             QStringLiteral("/proc"), QStringLiteral("/sys")});
    }

    // ── configBridge-compatible surface (DashboardStore uses these) ──
    Q_INVOKABLE QString uiState() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_ui_state(m_config));
        return s.qstring();
    }
    Q_INVOKABLE bool saveUiState(const QString& json) {
        if (!m_config) return false;
        const QByteArray encoded = json.toUtf8();
        if (xeneon_ui_state_validate(encoded.constData()) != 0) {
            qWarning() << "Manager: rejected invalid or unsupported UI state";
            reportLayoutSaveError(
                QStringLiteral("The layout format is invalid or newer than this Manager"));
            return false;
        }
        if (m_externalConfigConflictPending) {
            reportLayoutSaveError(QStringLiteral(
                "The Hub or configuration file changed while this layout was being edited. "
                "Choose Retry to keep the Manager version or Discard to load the other version."));
            return false;
        }
        // Single-writer: when the hub is connected it OWNS config.toml. Push the edit
        // over the control socket and let the hub persist it - do NOT also atomically
        // rename the file here, which would race the hub's writer (the two-writer save
        // race). When offline the Manager is the sole writer and persists directly, so
        // offline edits are never lost.
        if (m_sock->state() != QLocalSocket::UnconnectedState) {
            // Keep the backend view aligned with DashboardStore immediately.
            // This is an in-memory adoption only: the generation remains the
            // Hub-owned disk generation until the tagged acknowledgement and
            // subsequent token refresh confirm publication.
            if (xeneon_config_set_ui_state(
                    m_config, encoded.constData()) != 0) {
                reportLayoutSaveError(
                    QStringLiteral("Failed to stage the layout for the Hub"));
                return false;
            }
            pushLive(json);   // hub applies + saves
            return true;
        }
        auto offlineWriter = xeneon::acquireSingleInstance(
            QStringLiteral("hub"), false);
        if (!offlineWriter) {
            if (xeneon_config_set_ui_state(
                    m_config, encoded.constData()) != 0) {
                reportLayoutSaveError(
                    QStringLiteral("Failed to stage the layout for the Hub"));
                return false;
            }
            pushLive(json);
            return true;
        }
        ConfigTransaction transaction(m_config);
        if (!transaction
            || xeneon_config_set_ui_state(
                   transaction.candidate(), encoded.constData()) != 0) {
            reportLayoutSaveError(QStringLiteral("Failed to prepare the layout save"));
            return false;
        }
        markSelfWrite();
        const bool ok = transaction.commit();
        if (ok && transaction.durabilityUncertain())
            emit saveError(QStringLiteral(
                "The layout was published, but storage could not confirm crash durability"));
        if (!ok) {
            qWarning() << "Manager: failed to persist UI state";
            reportLayoutSaveError(QStringLiteral("Failed to save the layout"));
            return false;
        }
        // Keep a reconciliation copy so a Hub appearing later can be compared
        // against this edit, but remember that this exact document is already
        // durably on disk. A normal offline shutdown therefore needs no Hub ack.
        pushLive(json, true);
        return true;
    }
    // The normal live-edit path remains asynchronous. Clean shutdown is rare
    // and must be stronger: after QML forces its final save, wait for the Hub's
    // tagged acknowledgement that it applied and persisted that document.
    bool confirmShutdownUiStatePersisted() {
        if (m_pendingPush.isEmpty())
            return true;
        if (m_pendingPushFailed)
            return false;
        if (m_pendingPushDurablyPersisted
            && m_pendingPushRequestId.isEmpty())
            return true;
        // A document accepted while connected stays pending until the matching
        // Hub acknowledgement. If the socket drops first, do not misclassify it
        // as an offline synchronous save.
        if (!m_hubConnected
            || !m_sock
            || m_sock->state() != QLocalSocket::ConnectedState)
            return false;
        return waitForAck(
            QStringLiteral("setUiState"), m_pendingPushRequestId);
    }
    Q_INVOKABLE QString starterLayout() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_starter_layout(m_config));
        return s.qstring();
    }
    Q_INVOKABLE QString configJson() const {
        if (!m_config) return QString();
        // Rust returns a non-reversible diagnostics summary, never raw config.
        XeneonString s(xeneon_config_to_json(m_config));
        return s.qstring();
    }
    Q_INVOKABLE QString exportUiStateRecovery(const QString& json) const {
        XeneonString directory(xeneon_config_dir());
        return xeneon::exportUiStateRecovery(directory.qstring(), json);
    }
    QString exportPendingUiStateRecovery() const {
        if (m_pendingPush.isEmpty())
            return QString();
        return exportUiStateRecovery(m_pendingPush);
    }
    // Pull the hub's current UI state over IPC (called on connect + window focus).
    Q_INVOKABLE void syncFromHub() {
        if (m_sock->state() == QLocalSocket::ConnectedState)
            writeMsg(QJsonObject{{"type", "getUiState"}});
    }

    // ── Display / startup settings ──
    Q_INVOKABLE QString screensJson() const {
        // Headless/offscreen exposes a single bogus 800x800 screen - hide it so the
        // Display tab doesn't offer a garbage target in dev/capture runs.
        if (QGuiApplication::platformName().contains("offscreen", Qt::CaseInsensitive))
            return QStringLiteral("[]");
        // GCOVR_EXCL_START (live-QScreen enumeration: requires real, non-offscreen
        // displays; tests run offscreen and take the "[]" branch above).
        QJsonArray arr;
        const auto screens = QGuiApplication::screens();
        QScreen* primary = QGuiApplication::primaryScreen();
        for (auto* s : screens) {
            // Use the NATIVE/physical pixel resolution, not the logical (DPI-scaled)
            // size: QScreen::size() is in device-independent pixels, so on a scaled
            // display a 2560x720 Edge reports e.g. 1707x480 and the isEdge match (and
            // the resolution shown to the user) would be wrong. Multiplying by the
            // device pixel ratio recovers the real panel resolution.
            const qreal dpr = s->devicePixelRatio();
            const int nativeW = qRound(s->size().width() * dpr);
            const int nativeH = qRound(s->size().height() * dpr);
            arr.append(QJsonObject{
                {"name", s->name()},
                {"model", s->model()},
                {"manufacturer", s->manufacturer()},
                {"serial", s->serialNumber()},
                {"width", nativeW},
                {"height", nativeH},
                {"primary", s == primary},
                {"isEdge", (nativeW == 2560 && nativeH == 720)
                            || (nativeW == 720 && nativeH == 2560)
                            || s->model().contains("XENEON", Qt::CaseInsensitive)}
            });
        }
        return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
        // GCOVR_EXCL_STOP
    }
    Q_INVOKABLE QString targetConnector() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_target_connector(m_config)); return s.qstring();
    }
    Q_INVOKABLE QString targetModel() const {
        if (!m_config) return QString();
        XeneonString s(xeneon_config_get_target_model(m_config)); return s.qstring();
    }
    Q_INVOKABLE bool setTargetDisplay(const QString& connector, const QString& model) {
        if (!m_config) return false;
        // Single-writer (B5), same rule saveUiState follows: when the hub is connected
        // it OWNS config.toml. Writing the file here would be REVERTED by the hub's
        // next save, because the hub's in-memory config would still hold the old
        // target. Ask the hub to adopt + re-match + persist instead.
        if (m_sock->state() == QLocalSocket::ConnectedState) {
            bool durabilityUncertain = false;
            const bool ok = sendSetterAndWait(
                QJsonObject{{"type", "setTargetDisplay"},
                            {"connector", connector},
                            {"model", model}},
                &durabilityUncertain);
            if (ok) {
                // The Hub replaces this with the selected live screen's hash.
                // Clear our stale local copy until the next authoritative pull.
                xeneon_config_set_target_edid_hash(m_config, nullptr);
                xeneon_config_set_target_connector(
                    m_config, connector.toUtf8().constData());
                xeneon_config_set_target_model(
                    m_config, model.toUtf8().constData());
            }
            if (ok && durabilityUncertain)
                emit saveError(QStringLiteral(
                    "The display target was published, but storage could not confirm crash durability"));
            if (!ok) emit saveError(QStringLiteral("Failed to save the display target"));
            return ok;
        }
        if (m_sock->state() == QLocalSocket::ConnectingState) {
            emit saveError(QStringLiteral(
                "The Manager is still connecting to the Hub. Retry the display change."));
            return false;
        }
        auto offlineWriter = xeneon::acquireSingleInstance(
            QStringLiteral("hub"), false);
        if (!offlineWriter) {
            tryConnectHub();
            emit saveError(QStringLiteral(
                "The Hub owns configuration. Retry when the connection indicator is active."));
            return false;
        }
        ConfigTransaction transaction(m_config);
        if (!transaction
            // With the Hub offline there may be no live QScreen from which to
            // derive a new hash. Clearing the previous target's hash is safer
            // than letting it outrank the user's new connector/model at boot.
            || xeneon_config_set_target_edid_hash(
                   transaction.candidate(), nullptr) != 0
            || xeneon_config_set_target_connector(
                   transaction.candidate(), connector.toUtf8().constData()) != 0
            || xeneon_config_set_target_model(
                   transaction.candidate(), model.toUtf8().constData()) != 0)
            return false;
        markSelfWrite();
        // Callers previously ignored this bool; a failed save was silent. Log + signal
        // so the failure is honest (and the return value stays truthful).
        const bool ok = transaction.commit();
        if (ok && transaction.durabilityUncertain())
            emit saveError(QStringLiteral(
                "The display target was published, but storage could not confirm crash durability"));
        if (!ok) {
            qWarning() << "Manager: failed to persist target display";
            emit saveError(QStringLiteral("Failed to save the display target"));
        }
        return ok;
    }
    Q_INVOKABLE bool setAutostart(bool enabled) {
        if (!m_config) return false;
        // Single-writer (B5): see setTargetDisplay. The hub installs/removes the XDG
        // entry AND persists the flag, so the .desktop and config.toml never disagree
        // about who wrote them last. waitForAck is what lets the caller re-read
        // isAutostart() on the very next line and see the hub's write.
        if (m_sock->state() == QLocalSocket::ConnectedState) {
            bool durabilityUncertain = false;
            const bool ok = sendSetterAndWait(
                QJsonObject{{"type", "setAutostart"}, {"enabled", enabled}},
                &durabilityUncertain);
            if (ok)
                xeneon_config_set_autostart(m_config, enabled ? 1 : 0);
            if (ok && durabilityUncertain)
                emit saveError(QStringLiteral(
                    "Autostart was published, but storage could not confirm crash durability"));
            if (!ok) emit saveError(QStringLiteral("Failed to update autostart"));
            return ok;
        }
        if (m_sock->state() == QLocalSocket::ConnectingState) {
            emit saveError(QStringLiteral(
                "The Manager is still connecting to the Hub. Retry the autostart change."));
            return false;
        }
        auto offlineWriter = xeneon::acquireSingleInstance(
            QStringLiteral("hub"), false);
        if (!offlineWriter) {
            tryConnectHub();
            emit saveError(QStringLiteral(
                "The Hub owns configuration. Retry when the connection indicator is active."));
            return false;
        }
        ConfigTransaction transaction(m_config);
        if (!transaction
            || xeneon_config_set_autostart(
                   transaction.candidate(), enabled ? 1 : 0) != 0)
            return false;
        // Install/remove the XDG entry AND persist the flag - both must succeed for
        // the switch to be honest. Report the combined result.
        const bool previousEnabled = isAutostart();
        const bool fileOk = applyAutostart(enabled);
        if (!fileOk) {
            qWarning() << "Manager: autostart .desktop write failed";
            emit saveError(QStringLiteral("Failed to update autostart"));
            return false;
        }
        markSelfWrite();
        const bool saveOk = transaction.commit();
        if (saveOk && transaction.durabilityUncertain())
            emit saveError(QStringLiteral(
                "Autostart was published, but storage could not confirm crash durability"));
        if (!saveOk) qWarning() << "Manager: failed to persist autostart flag";
        if (!saveOk) {
            const bool restored = applyAutostart(previousEnabled);
            qWarning() << "Manager: restored previous autostart state:" << restored;
            emit saveError(restored
                ? QStringLiteral("Failed to update autostart")
                : QStringLiteral(
                    "Autostart could not be restored after a configuration failure. "
                    "Restart the Hub to repair it from the saved setting."));
        }
        return saveOk;
    }
    // Effective autostart state = the XDG autostart entry actually exists.
    Q_INVOKABLE bool isAutostart() const {
        return QFile::exists(autostartPath());
    }

    // ── Licensing (Pro tier) ──
    // Verify a candidate key WITHOUT storing it - the dialog previews "unlocks Pro
    // for <name>" / "expired" / "not a valid key" before the user commits.
    Q_INVOKABLE QString verifyLicenseCandidate(const QString& key) const {
        XeneonString js(xeneon_license_verify_json(key.toUtf8().constData()));
        return js.qstring();
    }
    // The effective entitlement from the STORED key, same JSON shape as the
    // candidate verify (state/tier/issuedTo/id/expires). What the Manager shows.
    Q_INVOKABLE QString licenseStatusJson() const {
        if (!m_config) return QStringLiteral("{\"state\":\"unlicensed\",\"tier\":\"free\"}");
        XeneonString js(xeneon_config_license_status_json(m_config));
        return js.qstring();
    }
    // Store (or clear, with an empty string) the Pro key. Single-writer (B5), same
    // as setAutostart: when the hub is connected it OWNS config.toml, so push the
    // key over the socket and let the hub persist AND re-gate live; when offline
    // the Manager writes directly. Either way our in-memory copy is updated first
    // so licenseStatusJson() on the next line reflects the change. Emits
    // licenseChanged() so the Manager UI re-reads without a manual refresh.
    Q_INVOKABLE bool setLicenseKey(const QString& key) {
        if (!m_config) return false;
        const QByteArray k = key.toUtf8();
        bool ok;
        if (m_sock->state() == QLocalSocket::ConnectedState) {
            // Always send a real string field (empty string = explicit clear); the
            // hub rejects a missing field so a malformed push can't silently wipe
            // the licence.
            ok = sendSetterAndWait(
                QJsonObject{{"type", "setLicenseKey"}, {"key", key}});
            if (ok)
                xeneon_config_set_license_key(
                    m_config, key.isEmpty() ? nullptr : k.constData());
        } else {
            if (m_sock->state() == QLocalSocket::ConnectingState) {
                emit saveError(QStringLiteral(
                    "The Manager is still connecting to the Hub. Retry the licence change."));
                return false;
            }
            auto offlineWriter = xeneon::acquireSingleInstance(
                QStringLiteral("hub"), false);
            if (!offlineWriter) {
                tryConnectHub();
                emit saveError(QStringLiteral(
                    "The Hub owns configuration. Retry when the connection indicator is active."));
                return false;
            }
            ConfigTransaction transaction(m_config);
            if (!transaction
                || xeneon_config_set_license_key(
                       transaction.candidate(),
                       key.isEmpty() ? nullptr : k.constData()) != 0)
                return false;
            markSelfWrite();
            ok = transaction.commit();
            if (ok && transaction.durabilityUncertain())
                emit saveError(QStringLiteral(
                    "The licence was published, but storage could not confirm crash durability"));
        }
        if (!ok) emit saveError(QStringLiteral("Failed to save the licence key"));
        if (ok) emit licenseChanged();
        return ok;
    }
    Q_INVOKABLE bool clearLicenseKey() { return setLicenseKey(QString()); }

    // ── Images ──
    Q_INVOKABLE QString imagesDir() const {
        XeneonString cd(xeneon_config_dir());
        QString dir = cd.qstring() + "/images";
        QDir().mkpath(dir);
        return dir;
    }
    Q_INVOKABLE QStringList listImages() const {
        QDir d(imagesDir());
        return d.entryList({"*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.bmp"},
                           QDir::Files, QDir::Time);
    }
    // Copy an image into the hub's images dir, keeping a unique name (never
    // silently overwrite an existing image with a colliding basename).
    Q_INVOKABLE QString importImage(const QString& fileUrl) {
        QString src = fileUrl;
        if (src.startsWith("file:")) src = QUrl(src).toLocalFile();
        QFileInfo fi(src);
        if (!fi.exists() || !fi.isReadable()) { qWarning() << "importImage: unreadable" << src; return QString(); }
        // Guard the synchronous copy below: stat the source and reject anything over
        // the cap so a huge or slow network-mounted file can't freeze the GUI thread.
        if (fi.size() > kMaxImportBytes) {
            qWarning() << "importImage: rejecting oversized file" << src << fi.size()
                       << "bytes (cap" << kMaxImportBytes << ")";
            return QString();
        }
        const QString dir = imagesDir();
        const QString base = fi.completeBaseName();
        const QString ext = fi.suffix();
        QString name = fi.fileName();
        QString dst = dir + "/" + name;
        for (int n = 1; QFile::exists(dst); ++n) {
            name = base + "-" + QString::number(n) + (ext.isEmpty() ? QString() : "." + ext);
            dst = dir + "/" + name;
        }
        if (!QFile::copy(src, dst)) { qWarning() << "importImage: copy failed" << src << "→" << dst; return QString(); }
        emit imagesChanged();
        return name;
    }
    Q_INVOKABLE bool deleteImage(const QString& name) {
        // Sanitize: collapse to a bare filename inside the images dir so a crafted
        // name (e.g. "../../.config/foo") can't traverse outside it, then verify the
        // resolved path really stays within it before removing anything.
        const std::optional<QString> target = sanitizeImageName(name, imagesDir());
        if (!target) return false;
        bool ok = QFile::remove(*target);
        if (ok) emit imagesChanged();
        return ok;
    }
    // Properly percent-encoded file:// URL for an image in the hub's images dir.
    // Building the URL here via QUrl ensures paths containing spaces or '#' survive
    // - naive "file://" + path string concatenation (as done in the QML) produces a
    // malformed URL that fails to load for those characters.
    Q_INVOKABLE QString imageUrl(const QString& name) const {
        const QString base = QFileInfo(name).fileName();
        if (base.isEmpty()) return QString();
        return QUrl::fromLocalFile(imagesDir() + "/" + base).toString();
    }

signals:
    void hubConnectedChanged();
    void hubRotationChanged();
    void hubCurrentPageChanged();
    void layoutLiveAppliedChanged();
    void imagesChanged();
    void screensChanged();
    void configChanged();   // config reloaded (from the hub or disk) → QML re-reads
    // Non-layout fields were refreshed from the Hub-owned config file while the
    // socket stayed connected. QML must refresh target/startup/licence controls,
    // but must not reload DashboardStore and discard a local layout edit.
    void hubConfigChanged();
    void licenseChanged();  // the Pro key was set/cleared → QML re-reads the tier
    // Emitted when a persist/apply the user asked for did NOT succeed, so the QML
    // side can surface an honest error (a toast) instead of a silent no-op. The
    // C++ return values are already truthful; this makes the failure observable.
    void saveError(const QString& what);
    void layoutSaveError(const QString& what);
    void externalConfigConflict();

private slots:
    void onSocketReadyRead() {
        m_rxBuf += m_sock->readAll();
        int nl;
        while ((nl = m_rxBuf.indexOf('\n')) >= 0) {
            if (nl > xeneon::kMaxControlFrameBytes) {
                qWarning() << "Manager: oversized IPC frame; closing Hub connection";
                m_rxBuf.clear();
                m_sock->abort();
                return;
            }
            const QByteArray line = m_rxBuf.left(nl);
            m_rxBuf.remove(0, nl + 1);
            if (line.trimmed().isEmpty()) continue;   // keep-alive / blank framing
            // Parse defensively: a malformed or non-object line is LOGGED and skipped
            // (was silently swallowed). The newline framing already consumed the bad
            // line, so a single garbage message can't desync the rest of the stream.
            QJsonParseError perr{};
            const QJsonDocument doc = QJsonDocument::fromJson(line, &perr);
            if (doc.isNull() || !doc.isObject()) {
                qWarning() << "Manager: ignoring malformed IPC line:"
                           << perr.errorString() << "(" << line.size() << "bytes)";
                continue;
            }
            const QJsonObject o = doc.object();
            const QString type = o.value("type").toString();
            if (type == "uiState") {
                // The hub tags its reply with the live panel rotation (optional; a
                // mock/older hub omits it). Drives the Manager preview's orientation.
                if (o.contains("rotation")) {
                    const int r = o.value("rotation").toInt(-1);
                    if (r != m_hubRotation) { m_hubRotation = r; emit hubRotationChanged(); }
                }
                if (o.value(QStringLiteral("currentPage")).isDouble()) {
                    const int page =
                        o.value(QStringLiteral("currentPage")).toInt(-1);
                    if (page != m_hubCurrentPage) {
                        m_hubCurrentPage = page;
                        emit hubCurrentPageChanged();
                    }
                }
                if (!o.value("state").isString()) {
                    qWarning() << "Manager: Hub UI-state reply has no string state";
                    emit saveError(QStringLiteral("The Hub returned an invalid layout reply"));
                    continue;
                }
                const QString st = o.value("state").toString();
                if (o.value("stateLive").isBool()) {
                    const bool live = o.value("stateLive").toBool();
                    if (live != m_layoutLiveApplied) {
                        m_layoutLiveApplied = live;
                        emit layoutLiveAppliedChanged();
                    }
                }
                if (!st.isEmpty()
                    && xeneon_ui_state_validate(st.toUtf8().constData()) != 0) {
                    qWarning() << "Manager: refused invalid or unsupported Hub UI state";
                    emit saveError(QStringLiteral("The Hub layout is newer than this Manager"));
                    continue;
                }
                // This one-shot receipt is consumed by packaging smoke as proof
                // of a complete Manager-to-Hub request/reply round trip. Keep it
                // once per connection so the 500 ms live pull cannot flood logs.
                if (!m_hubUiStateReceiptLogged) {
                    qInfo() << "Manager: Hub UI-state reply accepted";
                    m_hubUiStateReceiptLogged = true;
                }
                QString currentConfigState;
                if (m_config) {
                    XeneonString currentState(
                        xeneon_config_get_ui_state(m_config));
                    currentConfigState = currentState.qstring();
                }
                // DashboardStore debounces local structural/settings edits for
                // 400 ms, and editors such as Quick Note have their own local
                // debounce before touching DashboardStore. During either window
                // m_config still contains the previous document, so adopting a
                // periodic Hub pull would silently replace the unsaved Manager
                // model. If the Hub also changed against that known document,
                // stop and require an explicit keep/discard decision. Otherwise
                // defer the unchanged pull until the pending save is complete.
                const bool localUiStatePending =
                    !m_discardAwaitingHubState
                    && (m_layoutSavePending
                        || (st != currentConfigState
                            && m_localUiStatePendingProbe
                            && m_localUiStatePendingProbe()));
                if (localUiStatePending
                    && m_pendingPush.isEmpty()
                    && !m_pendingPushAwaitingHub) {
                    if (st != currentConfigState
                        && !m_externalConfigConflictPending) {
                        m_externalConfigConflictPending = true;
                        emit externalConfigConflict();
                    }
                    continue;
                }
                if (m_externalConfigConflictPending)
                    continue;
                const bool layoutChangedBeforeRefresh =
                    m_config && currentConfigState != st;
                const QJsonValue tokenValue =
                    o.value(QStringLiteral("configGenerationToken"));
                const QString generationToken =
                    tokenValue.isString()
                    && !tokenValue.toString().isEmpty()
                    && tokenValue.toString().size() <= 128
                        ? tokenValue.toString()
                        : QString();
                refreshHubOwnedConfig(st, generationToken);
                // ── Reconnect reconciliation ──
                // On the first pull after reconnecting, decide the fate of any edit
                // buffered while the socket was down BEFORE adopting or pushing.
                // If the hub's state changed while we were offline (a device-side
                // edit) - OR we have no prior baseline yet the hub reports a non-empty
                // state - the hub is authoritative and the stale buffered push is
                // dropped; otherwise the device didn't touch it and our offline edit
                // is applied. This pull → reconcile → push order is what prevents
                // clobbering device-side changes.
                if (m_pendingPushAwaitingHub) {
                    m_pendingPushAwaitingHub = false;
                    const ReconcileAction a = reconcileOnPull(
                        true, !m_pendingPush.isEmpty(), st, m_lastHubState,
                        m_nowMs() < m_suppressAdoptUntilMs);
                    if (a == ReconcileAction::RequireConflict) {
                        // Both documents are valuable and their relative age is
                        // unknown. Keep the pending Manager bytes, keep the Hub
                        // bytes unapplied, and surface the existing explicit
                        // Retry/Discard recovery UI. QML creates an owner-only
                        // recovery copy when it receives layoutSaveError.
                        m_externalConfigConflictPending = true;
                        emit externalConfigConflict();
                        emit layoutSaveError(QStringLiteral(
                            "The Hub changed while the Manager was disconnected. "
                            "Choose Retry to keep this Manager layout or Discard "
                            "to load the Hub layout."));
                    } else if (a == ReconcileAction::KeepAndPushEdit) {
                        const QString edit = m_pendingPush;
                        clearPendingUiState();
                        pushLive(edit);            // hub unchanged - apply our edit
                    }
                    m_lastHubState = st;
                }
                // A mutation acknowledgement, not elapsed time, is the proof
                // that a connected edit was persisted. Any pull arriving while
                // the newest edit is pending can predate that edit and must not
                // replace the Manager model.
                if (!m_pendingPush.isEmpty() && !m_pendingPushAwaitingHub)
                    continue;
                m_lastHubState = st;   // empty is an authoritative reset
                if (m_config
                    && (layoutChangedBeforeRefresh
                        || m_discardAwaitingHubState)) {
                    // This IS the hub's live state - adopt it WITHOUT re-saving, and
                    // tell QML exactly once when it differed before the config
                    // refresh. refreshHubOwnedConfig may already have loaded the
                    // same state from disk, but that must not suppress the signal.
                    XeneonString cur(xeneon_config_get_ui_state(m_config));
                    bool adopted = true;
                    if (cur.qstring() != st) {
                        const QByteArray stateBytes = st.toUtf8();
                        adopted = xeneon_config_set_ui_state(
                                      m_config,
                                      st.isEmpty() ? nullptr : stateBytes.constData())
                                  == 0;
                    }
                    if (adopted) {
                        m_discardAwaitingHubState = false;
                        emit configChanged();
                    } else {
                        qWarning() << "Manager: refused invalid or unsupported Hub UI state";
                        emit saveError(QStringLiteral(
                            "The Hub layout is newer than this Manager"));
                    }
                }
            } else if (type == "ok" || type == "error") {
                if (type == "error")
                    qWarning() << "Manager: hub rejected update:" << o.value("message").toString();
                const QString forType = o.value("for").toString();
                const QString requestId = o.value("requestId").toString();
                bool matchesLatestUiState = false;
                int inFlightBeforeAck = 0;
                if (forType == QStringLiteral("setUiState")) {
                    inFlightBeforeAck = m_uiStateRequestsInFlight;
                    if (m_uiStateRequestsInFlight > 0)
                        --m_uiStateRequestsInFlight;
                }
                if (forType == QStringLiteral("setUiState") && !m_pendingPush.isEmpty()) {
                    // Current peers echo requestId. Accept an untagged ack only
                    // when it is the only in-flight reply, which keeps
                    // compatibility with an older Hub while preventing the
                    // first of multiple rapid-edit acks from clearing the newest
                    // pending layout.
                    matchesLatestUiState =
                        (!requestId.isEmpty() && requestId == m_pendingPushRequestId)
                        || (requestId.isEmpty() && inFlightBeforeAck == 1);
                    if (matchesLatestUiState && type == QStringLiteral("ok")) {
                        const bool live = o.value(QStringLiteral("liveApplied")).toBool(true);
                        if (live != m_layoutLiveApplied) {
                            m_layoutLiveApplied = live;
                            emit layoutLiveAppliedChanged();
                        }
                        const QString persistedState = m_pendingPush;
                        m_lastHubState = persistedState;
                        clearPendingUiState();
                        if (m_config
                            && xeneon_config_set_ui_state(
                                   m_config,
                                   persistedState.toUtf8().constData()) != 0) {
                            qWarning() << "Manager: could not adopt acknowledged UI state";
                            emit saveError(QStringLiteral(
                                "The saved Hub layout could not be loaded in the Manager"));
                        }
                    } else if (matchesLatestUiState) {
                        m_pendingPushFailed = true;
                        reportLayoutSaveError(
                            QStringLiteral("The Hub could not save the layout"));
                    }
                }
                // Match the ack to the per-field setter that is blocking on it. The
                // "for" tag is what keeps an untagged setUiState ack (fire-and-forget,
                // possibly still in flight) from being mistaken for ours.
                const bool awaitedAckMatches =
                    !m_awaitAckFor.isEmpty()
                    && forType == m_awaitAckFor
                    && !requestId.isEmpty()
                    && requestId == m_awaitAckRequestId
                    && (forType != QStringLiteral("setUiState") || matchesLatestUiState);
                if (awaitedAckMatches) {
                    m_ackSeen = true;
                    m_ackOk = (type == "ok");
                    m_ackDurabilityUncertain =
                        m_ackOk
                        && o.value(QStringLiteral("durabilityUncertain")).toBool(false);
                    if (m_ackLoop) m_ackLoop->quit();
                }
            }
        }
        if (m_rxBuf.size() > xeneon::kMaxControlFrameBytes) {
            qWarning() << "Manager: oversized partial IPC frame; closing Hub connection";
            m_rxBuf.clear();
            m_sock->abort();
        }
    }

private:
    static QString hubOwnedConfigSignature(ConfigHandle* config) {
        if (!config)
            return QString();
        XeneonString targetHash(xeneon_config_get_target_edid_hash(config));
        XeneonString targetConnector(xeneon_config_get_target_connector(config));
        XeneonString targetModel(xeneon_config_get_target_model(config));
        XeneonString starterLayout(xeneon_config_get_starter_layout(config));
        XeneonString themeMode(xeneon_config_get_theme_mode(config));
        XeneonString licenseStatus(xeneon_config_license_status_json(config));
        const QJsonArray signature{
            targetHash.qstring(),
            targetConnector.qstring(),
            targetModel.qstring(),
            starterLayout.qstring(),
            themeMode.qstring(),
            licenseStatus.qstring(),
            xeneon_config_is_first_run(config),
            xeneon_config_get_reconnect(config),
            xeneon_config_get_notify_disconnect(config),
            xeneon_config_get_autostart(config),
        };
        return QString::fromUtf8(
            QJsonDocument(signature).toJson(QJsonDocument::Compact));
    }
    void refreshHubOwnedConfig(
        const QString& reportedUiState,
        const QString& hubGenerationToken) {
        if (!m_config || !m_hubConnected)
            return;

        const bool tokenAware = !hubGenerationToken.isEmpty();
        if (tokenAware) {
            // The token is the current Hub process's random in-memory identity
            // for its persisted config generation. Equality is enough to prove
            // that no Hub-owned field changed since the previous accepted pull,
            // without reading or hashing config.toml every 500 ms.
            if (hubGenerationToken == m_lastHubConfigGenerationToken) {
                m_hubConfigReloadErrorActive = false;
                return;
            }
        } else {
            // Compatibility path for older Hub versions which omit the token.
            // A disk generation check is slower but remains an honest way to
            // discover their non-layout config changes.
            ++m_configDiskGenerationProbeCount;
            const int generationMatches =
                xeneon_config_disk_generation_matches(m_config);
            if (generationMatches == 1) {
                m_hubConfigReloadErrorActive = false;
                return;
            }
            if (generationMatches < 0) {
                if (!m_hubConfigReloadErrorActive) {
                    m_hubConfigReloadErrorActive = true;
                    emit saveError(QStringLiteral(
                        "The Hub configuration could not be checked for live changes"));
                }
                return;
            }
        }

        ConfigHandle* fresh = xeneon_config_load();
        if (!fresh) {
            if (!m_hubConfigReloadErrorActive) {
                m_hubConfigReloadErrorActive = true;
                emit saveError(QStringLiteral(
                    "The Hub configuration changed but could not be reloaded"));
            }
            return;
        }
        XeneonString freshStateValue(xeneon_config_get_ui_state(fresh));
        const QString freshState = freshStateValue.qstring();
        if (freshState != reportedUiState) {
            // The Hub wrote again between its reply and our snapshot. Keep the
            // current handle and let the next periodic pull pair matching state
            // and config bytes.
            xeneon_config_free(fresh);
            return;
        }

        const QString before = hubOwnedConfigSignature(m_config);
        const QString after = hubOwnedConfigSignature(fresh);
        xeneon_config_free(m_config);
        m_config = fresh;
        if (tokenAware)
            m_lastHubConfigGenerationToken = hubGenerationToken;
        m_hubConfigReloadErrorActive = false;
        if (before != after)
            emit hubConfigChanged();
    }
    void reportLayoutSaveError(const QString& message) {
        emit saveError(message);
        emit layoutSaveError(message);
    }
    static QString autostartPath() {
        // ConfigLocation, matching the hub's applyAutostart(): homePath() ignores
        // XDG_CONFIG_HOME (the sandbox-escape bug), and TWO path derivations that
        // can disagree is exactly how the Manager and hub would silently manage
        // two different autostart entries.
        return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
               + "/autostart/xeneon-edge-hub.desktop";
    }
    // Locate the hub executable: prefer the one shipped next to this Manager, else
    // rely on PATH (installed system-wide). Returns an absolute path when found.
    static QString hubBinaryPath() {
        const QString local = QCoreApplication::applicationDirPath() + "/xeneon-edge-hub";
        if (QFile::exists(local)) return local;
        return QStringLiteral("xeneon-edge-hub");   // resolved via PATH by QProcess
    }
    void markSelfWrite() {
        m_ignoreWatchUntilMs = m_nowMs() + 900;
        // A time window alone can hide a real external replacement that happens
        // to land beside our write. Always re-read after the window; the reload
        // is harmless for our own bytes and guarantees an external final file is
        // not missed permanently.
        QTimer::singleShot(950, this, [this] { checkForMissedExternalWrite(); });
    }
    void checkForMissedExternalWrite() {
        if (m_hubConnected || !m_config)
            return;
        const int matches = xeneon_config_disk_generation_matches(m_config);
        if (matches == 1)
            return;
        if (matches < 0) {
            emit saveError(QStringLiteral(
                "The configuration file could not be checked after saving"));
            return;
        }
        // Do not reload automatically. DashboardStore's debounce is not the
        // only local buffer: an editor such as Quick Note can still hold text in
        // its own timer. Let QML flush every WidgetHost into a recovery snapshot,
        // then require an explicit Retry or Discard decision.
        m_externalConfigConflictPending = true;
        emit externalConfigConflict();
        emit saveError(QStringLiteral(
            "The configuration changed outside the Manager. Local edits were kept for recovery."));
    }
    void handleHubDisconnect() {
        const bool wasConnected = m_hubConnected;
        const bool needsReload = m_connectedSessionNeedsReload;
        m_hubConnected = false;
        m_connectedSessionNeedsReload = false;
        m_uiStateRequestsInFlight = 0;
        m_hubUiStateReceiptLogged = false;
        m_lastHubConfigGenerationToken.clear();
        if (wasConnected)
            emit hubConnectedChanged();

        // The Hub may have persisted fields while it owned config.toml, so
        // this handle's generation is now stale. Reload exactly once after
        // every established connection, regardless of whether Qt reports the
        // transport error before or after disconnected.
        if (needsReload)
            reloadAfterHubDisconnect();
    }
    void tryConnectHub() {
        if (m_sock->state() == QLocalSocket::UnconnectedState)
            m_sock->connectToServer(xeneon::controlSocketPath());
    }
    void writeMsg(const QJsonObject& o) {
        m_sock->write(QJsonDocument(o).toJson(QJsonDocument::Compact));
        m_sock->write("\n");
        m_sock->flush();
    }
    void clearPendingUiState() {
        m_pendingPush.clear();
        m_pendingPushRequestId.clear();
        m_pendingPushFailed = false;
        m_pendingPushDurablyPersisted = false;
    }
    // Block (briefly, bounded) until the hub acks the per-field setter `forType`.
    // Returns false on a reject, a timeout, or a socket that dropped mid-request -
    // never a silent optimistic "true".
    //
    // Blocking is deliberate and confined to the RARE display/startup writes: the QML
    // calls these synchronously and re-reads the effective state on the next line
    // (the autostart Switch does `setAutostart(c); c = isAutostart()`), and the state
    // it reads is the .desktop entry the HUB writes. A fire-and-forget push would be
    // read back before the hub had done anything. The hot saveUiState path is NOT
    // acked this way - it stays fire-and-forget.
    QString nextRequestId() {
        return QString::number(m_nextRequestId++);
    }
    bool sendSetterAndWait(
        QJsonObject message, bool* durabilityUncertain = nullptr) {
        const QString forType = message.value(QStringLiteral("type")).toString();
        const QString requestId = nextRequestId();
        message.insert(QStringLiteral("requestId"), requestId);
        prepareAckWait(forType, requestId);
        writeMsg(message);
        return finishAckWait(durabilityUncertain);
    }
    void prepareAckWait(const QString& forType, const QString& requestId) {
        m_awaitAckFor = forType;
        m_awaitAckRequestId = requestId;
        m_ackSeen = false;
        m_ackOk = false;
        m_ackDurabilityUncertain = false;
    }
    bool waitForAck(const QString& forType, const QString& requestId) {
        prepareAckWait(forType, requestId);
        return finishAckWait();
    }
    bool finishAckWait(bool* durabilityUncertain = nullptr) {
        const QString forType = m_awaitAckFor;

        // A nested QEventLoop, NOT QLocalSocket::waitForReadyRead: the latter pumps
        // only this socket, which deadlocks whenever the hub shares our event loop
        // (the in-process regression tests) and stalls every other Manager timer even
        // when it doesn't. ExcludeUserInputEvents keeps the reentrancy honest - the
        // user cannot toggle the same control again while we are inside the wait.
        QEventLoop loop;
        m_ackLoop = &loop;
        connect(m_sock, &QLocalSocket::disconnected, &loop, &QEventLoop::quit);
        connect(m_sock, &QLocalSocket::errorOccurred, &loop, [&loop] { loop.quit(); });
        QTimer::singleShot(kAckTimeoutMs, &loop, &QEventLoop::quit);
        if (!m_ackSeen)
            loop.exec(QEventLoop::ExcludeUserInputEvents);
        m_ackLoop = nullptr;

        m_awaitAckFor.clear();
        m_awaitAckRequestId.clear();
        if (!m_ackSeen)
            qWarning() << "Manager: no ack from hub for" << forType;
        if (durabilityUncertain)
            *durabilityUncertain =
                m_ackSeen && m_ackOk && m_ackDurabilityUncertain;
        return m_ackSeen && m_ackOk;
    }
    void pushLive(
        const QString& uiStateJson,
        bool alreadyDurablyPersisted = false) {
        m_suppressAdoptUntilMs = m_nowMs() + 1500;
        if (m_sock->state() == QLocalSocket::ConnectedState) {
            // A live edit on a CONNECTED socket SUPERSEDES any edit that was buffered
            // while offline: a newer live edit always wins over an older buffered one.
            // Clear the pending offline push AND its awaiting-reconcile flag so that a
            // getUiState reply still in flight from the reconnect can't resurrect and
            // re-push the OLDER buffered edit over this newer one - the stale-repush
            // edit-loss heisenbug (edit A buffered, connect arms reconcile, live edit B
            // pushes here, then the reply reconciles with A and re-pushes it, losing B).
            clearPendingUiState();
            m_pendingPushAwaitingHub = false;
            m_pendingPush = uiStateJson;
            m_pendingPushRequestId = nextRequestId();
            m_pendingPushFailed = false;
            m_pendingPushDurablyPersisted = alreadyDurablyPersisted;
            ++m_uiStateRequestsInFlight;
            writeMsg(QJsonObject{{"type", "setUiState"},
                                 {"state", uiStateJson},
                                 {"requestId", m_pendingPushRequestId}});
            // Do not advance m_lastHubState optimistically. The matching tagged
            // ack is the proof that the Hub persisted this exact edit.
        } else {
            // connectToServer is async - buffer and flush on the `connected` signal
            // so the edit is never silently lost (was the "first save dropped" bug).
            clearPendingUiState();
            m_pendingPush = uiStateJson;
            m_pendingPushDurablyPersisted = alreadyDurablyPersisted;
            tryConnectHub();
        }
    }
    void reloadAfterHubDisconnect() {
        ConfigHandle* fresh = xeneon_config_load();
        if (!fresh) {
            qWarning() << "Manager: cannot reload config after Hub disconnect";
            emit saveError(QStringLiteral(
                "The Hub disconnected, but its saved configuration could not be reloaded"));
            return;
        }

        // A Hub pull may have exposed a concurrent edit while DashboardStore or
        // a widget-local editor still has unsaved input. Disconnecting must not
        // turn that already surfaced conflict into an implicit Discard. Refresh
        // the backend's non-layout fields, but preserve its prior layout and do
        // not emit configChanged; the QML document remains intact until the user
        // chooses Retry or Discard.
        if (m_externalConfigConflictPending || m_layoutSavePending) {
            XeneonString currentStateValue(
                m_config ? xeneon_config_get_ui_state(m_config) : nullptr);
            const QString currentState = currentStateValue.qstring();
            const QByteArray currentBytes = currentState.toUtf8();
            if (xeneon_config_set_ui_state(
                    fresh,
                    currentState.isEmpty() ? nullptr : currentBytes.constData())
                != 0) {
                xeneon_config_free(fresh);
                emit saveError(QStringLiteral(
                    "The local layout could not be preserved after the Hub disconnected"));
                return;
            }
            const QString before = hubOwnedConfigSignature(m_config);
            const QString after = hubOwnedConfigSignature(fresh);
            if (m_config)
                xeneon_config_free(m_config);
            m_config = fresh;
            if (before != after)
                emit hubConfigChanged();
            return;
        }

        // A request can be in flight when the socket drops. Keep the newest
        // locally validated edit visible and ready for reconnect reconciliation,
        // but do not write it here: a transient socket failure does not prove the
        // Hub process stopped owning config.toml.
        if (!m_pendingPush.isEmpty()
            && xeneon_config_set_ui_state(
                   fresh, m_pendingPush.toUtf8().constData()) != 0) {
            qWarning() << "Manager: pending UI state became invalid during disconnect reload";
            xeneon_config_free(fresh);
            emit saveError(QStringLiteral("The pending layout could not be recovered"));
            return;
        }
        if (m_config)
            xeneon_config_free(m_config);
        m_config = fresh;
        m_discardAwaitingHubState = false;
        emit configChanged();
    }
    void handleOfflineExternalConfigChange() {
        if (m_hubConnected || m_externalConfigConflictPending)
            return;

        // A file replacement can land while DashboardStore or a widget-local
        // editor still owns a debounce buffer. Let the live Manager flush first.
        // If that flush detects the generation change, or an already accepted
        // socket-bound save is still pending, preserve the current document and
        // require an explicit Retry or Discard decision.
        const bool preflightOk = m_offlineExternalChangePreflight
                                     ? m_offlineExternalChangePreflight()
                                     : !m_layoutSavePending;
        if (!preflightOk || m_layoutSavePending || !m_pendingPush.isEmpty()) {
            m_externalConfigConflictPending = true;
            emit externalConfigConflict();
            emit saveError(QStringLiteral(
                "The configuration changed outside the Manager. Local edits were kept for recovery."));
            return;
        }
        reloadConfig();
    }
    // GCOVR_EXCL_START (only reached from the offline file-watcher reload path above,
    // which is inotify/timing-dependent FS glue).
    void reloadConfig() {
        ConfigHandle* fresh = xeneon_config_load();
        if (!fresh) {
            emit saveError(QStringLiteral(
                "The changed configuration could not be loaded safely"));
            return;
        }
        if (m_config) xeneon_config_free(m_config);
        m_config = fresh;
        emit configChanged();
    }
    // GCOVR_EXCL_STOP
    bool applyAutostart(bool enabled) {
        return applyAutostartForProgram(enabled, hubBinaryPath());
    }

    // Reject import sources larger than this so a huge/network file can't freeze
    // the GUI thread inside the synchronous QFile::copy (see importImage).
    static constexpr qint64 kMaxImportBytes = 25LL << 20;       // 25 MiB
    // Upper bound on the per-field setter ack wait (see waitForAck). Generous for a
    // local socket to a local process, but finite: a wedged hub must degrade to an
    // honest "false", not a frozen Manager window.
    static constexpr qint64 kAckTimeoutMs = 1000;

    ConfigHandle* m_config = nullptr;
    const bool m_managerInjectedQtPlatform = false;
    QLocalSocket* m_sock = nullptr;
    QFileSystemWatcher* m_watcher = nullptr;
    QString m_configPath;
    QString m_pendingPush;          // edit buffered while the socket was down
    QString m_pendingPushRequestId; // tagged id once the latest edit is sent
    QString m_lastHubState;         // last UI state we know the hub held (for reconcile)
    QString m_lastHubConfigGenerationToken;
    QString m_awaitAckFor;          // request type waitForAck is blocking on ("" = none)
    QString m_awaitAckRequestId;    // exact mutation id waitForAck accepts
    QEventLoop* m_ackLoop = nullptr;// non-null only while inside waitForAck
    QByteArray m_rxBuf;
    bool m_ackSeen = false;         // an ack for m_awaitAckFor arrived
    bool m_ackOk = false;           // …and it was "ok" rather than "error"
    bool m_ackDurabilityUncertain = false;
    qint64 m_ignoreWatchUntilMs = 0;
    qint64 m_suppressAdoptUntilMs = 0;
    bool m_hubConnected = false;
    bool m_layoutLiveApplied = true;
    int m_hubRotation = -1;                  // panel's live content rotation from the hub
    int m_hubCurrentPage = -1;               // panel's live Dashboard page
    bool m_pendingPushAwaitingHub = false;  // reconcile buffered push on next pull
    bool m_pendingPushFailed = false;
    bool m_pendingPushDurablyPersisted = false;
    bool m_connectedSessionNeedsReload = false;
    bool m_hubUiStateReceiptLogged = false;
    bool m_layoutSavePending = false;
    bool m_discardAwaitingHubState = false;
    bool m_externalConfigConflictPending = false;
    bool m_hubConfigReloadErrorActive = false;
    int m_configDiskGenerationProbeCount = 0;
    int m_uiStateRequestsInFlight = 0;
    mutable bool m_policyLoaded = false;
    mutable QVariantMap m_policy;
    quint64 m_nextRequestId = 1;
    std::function<bool()> m_offlineExternalChangePreflight;
    std::function<bool()> m_localUiStatePendingProbe;
    // Injectable clock (ms since epoch); defaults to the wall clock. Overridable in
    // tests via setClockForTest so the suppression windows need no real waiting.
    std::function<qint64()> m_nowMs = [] { return QDateTime::currentMSecsSinceEpoch(); };
};
