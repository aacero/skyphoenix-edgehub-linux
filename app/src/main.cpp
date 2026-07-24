#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QScreen>
#include <QWindow>
#include <QQuickWindow>
#include <QImage>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDebug>
#include <QCommandLineParser>
#include <QObject>
#include <QFile>
#include <QDir>
#include <QUrl>
#include <QTextStream>
#include <QQuickStyle>
#include <QPalette>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

#include <cstdio>

#include "single_instance.h"
#include "timezone_bridge.h"
#include "distro_bridge.h"
#include "system_settings_probe.h"
#include <QColor>
#include <csignal>
#include <unistd.h>
#include <QSocketNotifier>
#include <QThread>

#include "xeneon_core.h"
#include "mpris_bridge.h"
#include "control_server.h"
#include "orientation_sensor.h"
#include "xeneon_string.h"
#include "autostart.h"
#include "display_match.h"
#include "config_bridge.h"
#include "network_access_policy.h"
#include "notification_bridge.h"
#include "license_bridge.h"
#include "metrics_worker.h"
#include "shutdown_flush.h"

// --- Global handle for signal handler access ---
static ConfigHandle* g_config = nullptr;

// --- Qt → Rust log bridge ---

static XeneonLogLevel qtMsgTypeToXeneon(QtMsgType type) {
    switch (type) {
    case QtDebugMsg:    return XENEON_LOG_DEBUG;
    case QtInfoMsg:     return XENEON_LOG_INFO;
    case QtWarningMsg:  return XENEON_LOG_WARN;
    case QtCriticalMsg: return XENEON_LOG_ERROR;
    case QtFatalMsg:    return XENEON_LOG_ERROR;
    }
    return XENEON_LOG_INFO;
}

static void qtLogBridge(QtMsgType type, const QMessageLogContext& ctx, const QString& msg) {
    const char* file = ctx.file ? ctx.file : "qml";
    int line = ctx.line ? ctx.line : 0;
    xeneon_logging_log(qtMsgTypeToXeneon(type), file, line, msg.toUtf8().constData());
}

// --- Dark palette ---
// Qt Quick Controls that aren't hand-restyled draw their chrome (Switch/Slider/
// ScrollBar/Dialog button-boxes) from the application QPalette. Without a dark
// one they fall back to the style's default LIGHT gray on the dark UI. Build it
// from the same design tokens the QML theme uses.
static QPalette darkPalette() {
    const QColor window("#0D1117");
    const QColor base("#161B22");
    const QColor alt("#1C222B");
    const QColor button("#1C222B");
    const QColor text("#E6EDF3");
    const QColor muted("#8B949E");
    const QColor accent("#F26D6D");
    const QColor onAccent("#0D1117");

    QPalette pal;
    pal.setColor(QPalette::Window, window);
    pal.setColor(QPalette::WindowText, text);
    pal.setColor(QPalette::Base, base);
    pal.setColor(QPalette::AlternateBase, alt);
    pal.setColor(QPalette::Button, button);
    pal.setColor(QPalette::ButtonText, text);
    pal.setColor(QPalette::Text, text);
    pal.setColor(QPalette::PlaceholderText, muted);
    pal.setColor(QPalette::BrightText, text);
    pal.setColor(QPalette::ToolTipBase, base);
    pal.setColor(QPalette::ToolTipText, text);
    pal.setColor(QPalette::Highlight, accent);
    pal.setColor(QPalette::HighlightedText, onAccent);
    pal.setColor(QPalette::Link, accent);
    pal.setColor(QPalette::Disabled, QPalette::Text, muted);
    pal.setColor(QPalette::Disabled, QPalette::WindowText, muted);
    pal.setColor(QPalette::Disabled, QPalette::ButtonText, muted);
    pal.setColor(QPalette::Disabled, QPalette::Highlight, alt);
    return pal;
}

static uint g_displayNotificationId = 0;
static quint64 g_displayNotificationGeneration = 0;

static void closeDesktopNotificationId(uint id) {
    if (id == 0) return;
    QDBusInterface notifications(QStringLiteral("org.freedesktop.Notifications"),
                                 QStringLiteral("/org/freedesktop/Notifications"),
                                 QStringLiteral("org.freedesktop.Notifications"),
                                 QDBusConnection::sessionBus());
    if (notifications.isValid())
        notifications.asyncCall(QStringLiteral("CloseNotification"), id);
}

// Send a real desktop notification, not a popup inside the Hub window.  The Hub
// is deliberately hidden before this runs so a compositor cannot relocate it
// onto the primary display; org.freedesktop.Notifications lets the desktop show
// the guidance independently on its normal notification surface.  The returned
// daemon id is retained so reconnect can close stale recovery guidance.
static void sendDisplayDisconnectNotification(const DisplayDisconnectNotice& notice) {
    qInfo() << "Hub: desktop disconnect notice:" << notice.summary << notice.body;
    QDBusInterface notifications(QStringLiteral("org.freedesktop.Notifications"),
                                 QStringLiteral("/org/freedesktop/Notifications"),
                                 QStringLiteral("org.freedesktop.Notifications"),
                                 QDBusConnection::sessionBus());
    if (!notifications.isValid()) {
        qWarning() << "Hub: desktop notification service unavailable; display "
                      "disconnect was still handled fail-closed";
        return;
    }
    QVariantMap hints;
    hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("xeneon-edge-hub"));
    hints.insert(QStringLiteral("urgency"), QVariant::fromValue<uchar>(1));
    const QList<QVariant> arguments{
        QStringLiteral("Xeneon Edge"),
        QVariant::fromValue<uint>(g_displayNotificationId),
        QStringLiteral("xeneon-edge-hub"),
        notice.summary,
        notice.body,
        QStringList{},
        hints,
        10000,
    };
    const quint64 generation = ++g_displayNotificationGeneration;
    auto* watcher = new QDBusPendingCallWatcher(
        notifications.asyncCallWithArgumentList(QStringLiteral("Notify"), arguments),
        QCoreApplication::instance());
    QObject::connect(watcher, &QDBusPendingCallWatcher::finished, watcher,
                     [watcher, generation]() {
        const QDBusPendingReply<uint> reply = *watcher;
        if (reply.isError()) {
            qWarning() << "Hub: desktop disconnect notification failed:"
                       << reply.error().message();
        } else if (generation == g_displayNotificationGeneration) {
            g_displayNotificationId = reply.value();
        } else {
            // The target reconnected before the asynchronous Notify reply.
            closeDesktopNotificationId(reply.value());
        }
        watcher->deleteLater();
    });
}

static void closeDisplayDisconnectNotification() {
    ++g_displayNotificationGeneration;
    const uint id = g_displayNotificationId;
    g_displayNotificationId = 0;
    closeDesktopNotificationId(id);
}

// --- Display helper ---

static QJsonObject screenToJson(QScreen* screen) {
    QJsonObject obj;
    obj["name"] = screen->name();
    obj["model"] = screen->model();
    obj["manufacturer"] = screen->manufacturer();
    obj["serialNumber"] = screen->serialNumber();
    obj["geometry"] = QJsonObject{
        {"x", screen->geometry().x()},
        {"y", screen->geometry().y()},
        {"width", screen->geometry().width()},
        {"height", screen->geometry().height()}
    };
    obj["availableGeometry"] = QJsonObject{
        {"x", screen->availableGeometry().x()},
        {"y", screen->availableGeometry().y()},
        {"width", screen->availableGeometry().width()},
        {"height", screen->availableGeometry().height()}
    };
    obj["logicalDpi"] = screen->logicalDotsPerInch();
    obj["physicalDpi"] = screen->physicalDotsPerInch();
    obj["devicePixelRatio"] = screen->devicePixelRatio();
    obj["refreshRate"] = screen->refreshRate();
    obj["physicalSize"] = QJsonObject{
        {"width", screen->physicalSize().width()},
        {"height", screen->physicalSize().height()}
    };
    {
        const QString on = orientationName(screen->orientation());
        obj["orientation"] = on.isEmpty() ? QStringLiteral("portrait") : on;
    }
    obj["isPrimary"] = (screen == QGuiApplication::primaryScreen());
    obj["size"] = QJsonObject{
        {"width", screen->size().width()},
        {"height", screen->size().height()}
    };

    obj["edidHash"] = screenIdentityHash(screen->name(), screen->model(),
                                         screen->manufacturer(), screen->serialNumber());

    obj["likelyXeneonEdge"] = (screen->model().contains("XENEON", Qt::CaseInsensitive)
        || screen->manufacturer().contains("Corsair", Qt::CaseInsensitive)
        || (screen->size().width() == 2560 && screen->size().height() == 720)
        || (screen->size().width() == 720 && screen->size().height() == 2560));

    return obj;
}

// --- Signal handler ---
// Uses a self-pipe to safely forward POSIX signals to the Qt event loop.
// Calling QCoreApplication::quit() or doing I/O from a signal handler
// is NOT async-signal-safe and can deadlock or corrupt state.

static int sigFd[2] = {-1, -1};

static void signalHandler(int sig) {
    // ONLY async-signal-safe operations: write the signal number to the pipe
    char c = static_cast<char>(sig);
    ssize_t rc = ::write(sigFd[1], &c, 1);
    (void)rc;   // async-signal-safe; nothing useful to do on failure
}

// --- Find target display ---

// Positive identity match ONLY (hash → model → connector → XENEON → resolution).
// Returns nullptr when nothing matches - NO primary-screen fallback. Used to decide
// whether a hotplugged screen is genuinely the Edge: the primary fallback must not
// count as a match there, or plugging in an unrelated (primary) monitor while the
// Edge is absent would hijack it fullscreen.
static QScreen* findTargetScreenStrict(ConfigHandle* config) {
    XeneonString targetHash(xeneon_config_get_target_edid_hash(config));
    XeneonString targetModel(xeneon_config_get_target_model(config));
    XeneonString targetConnector(xeneon_config_get_target_connector(config));
    const bool configuredTarget = hasConfiguredTargetIdentity(
        targetHash.qstring(), targetModel.qstring(), targetConnector.qstring());

    auto screens = QGuiApplication::screens();

    qInfo() << "Finding target screen among" << screens.size() << "screens"
            << "(hash:" << (targetHash ? targetHash.c_str() : "none")
            << "model:" << (targetModel ? targetModel.c_str() : "none")
            << "connector:" << (targetConnector ? targetConnector.c_str() : "none") << ")";

    // Try EDID hash match first
    if (targetHash) {
        for (auto* s : screens) {
            const QString hash = screenIdentityHash(s->name(), s->model(),
                                                    s->manufacturer(), s->serialNumber());
            if (hash == targetHash.qstring()) {
                qInfo() << "Target found by EDID hash:" << s->name();
                return s;
            }
        }
    }

    // Try model name match
    if (targetModel) {
        for (auto* s : screens) {
            if (s->model() == targetModel.qstring()) {
                qInfo() << "Target found by model:" << s->name();
                return s;
            }
        }
    }

    // Try connector match
    if (targetConnector) {
        for (auto* s : screens) {
            if (s->name() == targetConnector.qstring()) {
                qInfo() << "Target found by connector:" << s->name();
                return s;
            }
        }
    }

    // A persisted identity is an explicit user choice. If none of its resilient
    // fields matched, that display is absent; do not reinterpret an unrelated
    // Xeneon-shaped screen as the target. The caller will keep the Hub hidden.
    if (configuredTarget) {
        qWarning() << "Configured target display is not attached";
        return nullptr;
    }

    // No explicit target yet: preserve first-run auto-detection.
    for (auto* s : screens) {
        if (s->model().contains("XENEON", Qt::CaseInsensitive)) {
            qInfo() << "Target found by XENEON model substring:" << s->name();
            return s;
        }
    }

    // Fallback: find Xeneon-typical resolution (2560x720 or 720x2560)
    for (auto* s : screens) {
        int w = s->size().width(), h = s->size().height();
        if ((w == 2560 && h == 720) || (w == 720 && h == 2560)) {
            qInfo() << "Target found by Xeneon-typical resolution:" << s->name()
                    << w << "x" << h;
            return s;
        }
    }

    return nullptr;   // no positive match - caller decides on the fallback
}

int main(int argc, char *argv[]) {
    // Answer identity queries before touching Qt's GUI stack. Package tools and
    // the hardware E2E freshness guard run this in headless contexts; creating a
    // QGuiApplication first makes Qt abort when neither a compositor nor an X
    // server is available, even though printing a version needs neither.
    for (int vi = 1; vi < argc; ++vi) {
        const QByteArray va(argv[vi]);
        if (va == "--version" || va == "-v") {
#ifdef XENEON_VERSION
            std::printf("Xeneon Edge Linux Hub %s\n", XENEON_VERSION);
#else
            std::printf("Xeneon Edge Linux Hub 0.1.0\n");
#endif
            std::fflush(stdout);
            return 0;
        }
    }

    // Allow QML XMLHttpRequest to read local file:// paths - the KPI widget's
    // "local file" source (a bare number or JSON on disk) relies on it. This is
    // a LOCAL read only; it opens no network path (remote egress is separately
    // gated by NetHub), so it does not weaken the no-telemetry guarantee.
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");

    // Initialize Rust core logging FIRST
    xeneon_logging_init("info");

    // Install Qt → Rust log bridge
    qInstallMessageHandler(qtLogBridge);

    QGuiApplication app(argc, argv);
    app.setApplicationName("Xeneon Edge Linux Hub");
    // XENEON_VERSION, not a literal: CMakeLists passes the git-describe string
    // (or the packaged pkgver via XENEON_VERSION_OVERRIDE). This used to be a
    // hardcoded "0.1.0", so `--version` reported 0.1.0 for EVERY build ever
    // made - dev, packaged, and release alike - which made it impossible to
    // tell which build you were actually running or testing.
#ifdef XENEON_VERSION
    app.setApplicationVersion(QStringLiteral(XENEON_VERSION));
#else
    app.setApplicationVersion(QStringLiteral("0.1.0"));
#endif
    app.setOrganizationName("xeneon-edge-hub");

    // Fusion style + dark palette so on-device config controls (Switch/Slider/
    // ScrollBar/Dialog button-boxes) render dark instead of the default light gray.
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
    QGuiApplication::setPalette(darkPalette());

    // QA automation hooks (screenshot capture + auto-expand + single-instance
    // bypass + simulated target removal) are compiled in ONLY when
    // XENEON_QA_HOOKS is defined (CI / tests / marketing builds). In production
    // packages these stay empty/false, so the env vars are inert - no
    // screenshot/automation surface ships.
#ifdef XENEON_QA_HOOKS
    const bool    qaGrabMode = qEnvironmentVariableIsSet("XENEON_GRAB");
    const QString qaGrabPath = qEnvironmentVariable("XENEON_GRAB");
    const QString qaExpand   = qEnvironmentVariable("XENEON_EXPAND");
    // Adds N pages after load and logs the resulting SwipeView.currentIndex - so the
    // add-page navigation can be verified against the REAL stack (main→StackView→
    // Dashboard→SwipeView), which a qmltestrunner can't load (qrc: initialItem).
    const int     qaAddPages = qEnvironmentVariable("XENEON_QA_ADDPAGES", "0").toInt();
#else
    const bool    qaGrabMode = false;
    const QString qaGrabPath;
    const QString qaExpand;
    const int     qaAddPages = 0;
#endif

    // Single-instance guard - two hubs racing the shared config.toml corrupt it.
    // Skipped in grab mode so headless QA captures run alongside a real instance.
    auto instanceLock = xeneon::acquireSingleInstance(
        QStringLiteral("hub"), qaGrabMode);
    if (!instanceLock) {
        // fprintf (not qWarning): Qt's default handler routes to journald when
        // stderr isn't a TTY, so a plain write guarantees the user sees why the
        // second instance didn't open.
        std::fprintf(stderr, "Another Xeneon Edge Hub is already running - exiting.\n");
        std::fflush(stderr);
        return 0;
    }

    // Self-pipe for signal handling: forward POSIX signals to Qt event loop safely
    if (::pipe(sigFd) == 0) {
        QSocketNotifier* sigNotifier = new QSocketNotifier(sigFd[0], QSocketNotifier::Read, &app);
        QObject::connect(sigNotifier, &QSocketNotifier::activated, [&](int) {
            char c;
            if (::read(sigFd[0], &c, 1) == 1) {
                int sig = static_cast<int>(c);
                qInfo() << "Received signal" << sig << "- shutting down gracefully";
                if (g_config) {
                    xeneon_config_save(g_config);
                }
                QCoreApplication::quit();
            }
        });
        signal(SIGINT, signalHandler);
        signal(SIGTERM, signalHandler);
        signal(SIGHUP, signalHandler);
    } else {
        qWarning() << "Failed to create self-pipe for signal handling";
    }

    // CLI arguments
    QCommandLineParser parser;
    parser.addHelpOption();
    parser.addVersionOption();
    // The two reset flags are one word apart and differ by the user's whole
    // layout, so the help text has to say which one throws it away. (The core
    // now copies config.toml to config.toml.bak first, so this is recoverable -
    // but a flag that reads as harmless is still the wrong flag to reach for.)
    QCommandLineOption resetOpt(
        "reset", "Discard ALL configuration, including your dashboard layout, and start "
                 "from defaults. The discarded config is kept as config.toml.bak. "
                 "To only re-run the wizard, use --reset-wizard.");
    QCommandLineOption safeModeOpt("safe-mode", "Start in safe mode (all widgets disabled)");
    QCommandLineOption resetWizardOpt("reset-wizard",
                                      "Re-run the first-run wizard, KEEPING your configuration.");
    QCommandLineOption diagOpt("diagnostics", "Start directly in diagnostics view");
    QCommandLineOption windowedOpt("windowed", "Run in windowed mode instead of borderless fullscreen");
    parser.addOption(resetOpt);
    parser.addOption(safeModeOpt);
    parser.addOption(resetWizardOpt);
    parser.addOption(diagOpt);
    parser.addOption(windowedOpt);
    parser.process(app);

    // Load configuration
    ConfigHandle* config = nullptr;
    const bool resetting = parser.isSet(resetOpt);
    if (resetting) {
        config = xeneon_config_reset();
        if (config) {
            // Name the backup. A safety net nobody is told about is only half a
            // safety net: the user who reaches for --reset by mistake needs the
            // path in front of them, not in a doc.
            XeneonString dir(xeneon_config_dir());
            qInfo().noquote() << "Configuration reset to defaults. Your previous config was "
                                 "saved to"
                              << (dir ? dir.qstring() + "/config.toml.bak"
                                      : QStringLiteral("config.toml.bak beside your config"));
        }
    } else {
        config = xeneon_config_load();
    }
    if (!config) {
        // Distinguish the two failures. A reset only fails now if the backup
        // could not be written, in which case the core deliberately left the
        // config ALONE - saying "failed to load" would send the user hunting for
        // a corrupt config that is in fact intact.
        if (resetting) {
            qCritical() << "Reset aborted: could not back up the existing configuration, so it "
                           "was left untouched. Free some disk space or check permissions on"
                        << XeneonString(xeneon_config_dir()).qstring();
        } else {
            qCritical() << "Failed to load configuration";
        }
        return 1;
    }
    g_config = config;

    int isFirstRun = xeneon_config_is_first_run(config);
    if (parser.isSet(resetWizardOpt)) {
        isFirstRun = 1;
    }

    // Collect display information. A single builder so the initial snapshot and
    // every hotplug refresh serialize screens identically (S9: the list was frozen
    // at boot - the Display/Diagnostics tabs never saw a plugged/unplugged screen).
    auto buildScreensJson = []() -> QByteArray {
        QJsonArray arr;
        for (auto* screen : QGuiApplication::screens())
            arr.append(screenToJson(screen));
        return QJsonDocument(arr).toJson(QJsonDocument::Compact);
    };

    // Find target display for fullscreen placement. A saved identity changes
    // failure semantics: missing configured targets stay hidden, while a fresh
    // unconfigured install retains its primary-screen first-run fallback.
    XeneonString targetHash(xeneon_config_get_target_edid_hash(config));
    XeneonString targetConnector(xeneon_config_get_target_connector(config));
    XeneonString targetModel(xeneon_config_get_target_model(config));
    const bool configuredTarget = hasConfiguredTargetIdentity(
        targetHash.qstring(), targetModel.qstring(), targetConnector.qstring());
    QScreen* targetScreen = findTargetScreenStrict(config);
    const StartupDisplayPlacement startupPlacement = decideStartupDisplayPlacement(
        configuredTarget, targetScreen != nullptr, parser.isSet(resetWizardOpt));
    // An explicit --reset-wizard is the safe recovery path when the saved target
    // is absent: show the wizard windowed on primary instead of trapping it in a
    // hidden window. Ordinary missing-target startups still remain hidden.
    const bool windowedMode = parser.isSet(windowedOpt)
                              || startupPlacement == StartupDisplayPlacement::PrimaryRecovery;

    // Collect system metrics for initial display
    QJsonObject metricsJson = metricsToJson();

    // Create QML engine. The factory must outlive the engine (Qt does not take
    // ownership); declaration order gives us engine-first destruction.
    XeneonNetworkAccessManagerFactory networkAccessFactory;
    QQmlApplicationEngine engine;
    engine.setNetworkAccessManagerFactory(&networkAccessFactory);

    // Expose data to QML
    engine.rootContext()->setContextProperty("_isFirstRun", isFirstRun);
    engine.rootContext()->setContextProperty("_screens", buildScreensJson());
    engine.rootContext()->setContextProperty("_metricsJson", QJsonDocument(metricsJson).toJson(QJsonDocument::Compact));
    engine.rootContext()->setContextProperty("_safeMode", parser.isSet(safeModeOpt));
    engine.rootContext()->setContextProperty("_startInDiagnostics", parser.isSet(diagOpt));
    engine.rootContext()->setContextProperty("_windowedMode", windowedMode);
    // QA affordance: XENEON_EXPAND=<type> auto-opens that widget's expanded
    // config view on the first matching tile (mirrors the Manager's XENEON_CFG).
    engine.rootContext()->setContextProperty("_expandType", qaExpand);
    engine.rootContext()->setContextProperty("_qaAddPages", qaAddPages);

    // Config path for diagnostics
    XeneonString configDir(xeneon_config_dir());
    engine.rootContext()->setContextProperty("_configDir", configDir.qstring());

    // Theme mode
    XeneonString themeMode(xeneon_config_get_theme_mode(config));
    engine.rootContext()->setContextProperty("_themeMode", themeMode.qstring());

    // Expose target display info
    engine.rootContext()->setContextProperty("_targetEdidHash", targetHash.qstring());
    engine.rootContext()->setContextProperty("_targetConnector", targetConnector.qstring());
    engine.rootContext()->setContextProperty("_targetModel", targetModel.qstring());

    // Target screen geometry for window placement
    if (targetScreen) {
        engine.rootContext()->setContextProperty("_targetScreenX", targetScreen->geometry().x());
        engine.rootContext()->setContextProperty("_targetScreenY", targetScreen->geometry().y());
        engine.rootContext()->setContextProperty("_targetScreenWidth", targetScreen->geometry().width());
        engine.rootContext()->setContextProperty("_targetScreenHeight", targetScreen->geometry().height());
    }

    // Expose WizardBridge for first-run config persistence
    // Parent to engine so it's cleaned up when the engine is destroyed
    WizardBridge* wizardBridge = new WizardBridge(config, &engine);
    engine.rootContext()->setContextProperty("wizardBridge", wizardBridge);

    // Expose ConfigBridge for runtime layout/state persistence + diagnostics.
    ConfigBridge* configBridge = new ConfigBridge(config, &engine);
    engine.rootContext()->setContextProperty("configBridge", configBridge);

    NotificationBridge* notificationBridge = new NotificationBridge(&engine);
    engine.rootContext()->setContextProperty("notifications", notificationBridge);

    // The Pro tier, live. QML gates premium content on `license.isPro`; a key
    // pasted in the Manager (pushed over the control socket, below) re-gates
    // without a restart. Verification is offline and fails-soft (see license.rs).
    LicenseBridge* licenseBridge = new LicenseBridge(config, &engine);
    engine.rootContext()->setContextProperty("license", licenseBridge);

    // Real IANA time zones. QML cannot resolve one at all (no Intl; the timeZone
    // option on toLocaleString is silently ignored), so the clock needs this.
    TimeZoneBridge* timeZoneBridge = new TimeZoneBridge(&engine);
    engine.rootContext()->setContextProperty("timeZones", timeZoneBridge);

    // Distro identity / package count / system age. QML has no filesystem access,
    // so /etc/os-release and the package db can only be read over the FFI. The
    // bridge probes on its own thread - see distro_bridge.h.
    DistroBridge* distroBridge = new DistroBridge(&engine);
    engine.rootContext()->setContextProperty("distro", distroBridge);

    // OS reduce-motion signal via the XDG settings portal. Qt has no style hint
    // for it on any Qt 6, so QML binds theme.systemReduceMotion to this probe.
    // No bus / no portal → the property just stays false, silently.
    SystemSettingsProbe* systemSettings = new SystemSettingsProbe(&engine);
    systemSettings->start();
    engine.rootContext()->setContextProperty("systemSettings", systemSettings);

    // Expose the MPRIS media bridge (Now Playing + transport control).
    MprisBridge* mediaBridge = new MprisBridge(&engine);
    engine.rootContext()->setContextProperty("media", mediaBridge);

    // Live control endpoint for the companion "Xeneon Edge Manager" app. It can
    // push a new layout/appearance document, which we persist and live-reload.
    ControlServer* controlServer = new ControlServer(&engine);
    controlServer->setStateProvider([configBridge]() { return configBridge->uiState(); });
    QObject::connect(controlServer, &ControlServer::uiStateReceived, &engine,
                     [configBridge, &engine](const QString& json, bool* ok) {
        // *ok reports the apply result back to ControlServer so the socket ack is
        // honest (was: always "ok"). Same-thread direct connection, so it's set on
        // return. Set on BOTH paths.
        if (!configBridge->applyExternalUiState(json)) {
            qWarning() << "Failed to apply externally pushed UI state";
            if (ok) *ok = false;
            return;
        }
        if (ok) *ok = true;
        // Trigger a live reload in QML. The writable property is the primary
        // bridge because its change signal is observable and covered by the shell
        // integration test. main.qml retains the latest state and retries briefly
        // if the StackView has not finished constructing Dashboard yet, so an IPC
        // request accepted during startup cannot stop at persistence without ever
        // repainting the panel. An alternate root without that property falls back
        // to the direct method.
        for (auto* obj : engine.rootObjects()) {
            if (obj->setProperty("externalUiState", json)) {
                qInfo() << "Hub: external UI state delivered to QML property,"
                        << "applied:" << obj->property("externalUiStateApplied").toBool();
            } else {
                const bool invoked = QMetaObject::invokeMethod(
                    obj, "applyExternalUiState", Q_ARG(QVariant, json));
                if (!invoked)
                    qWarning() << "Hub: QML root cannot accept external UI state";
            }
        }
    // EXPLICIT Qt::DirectConnection is REQUIRED, not incidental: both the ack
    // correctness and the validity of the `bool* ok` argument depend on SAME-THREAD
    // synchronous delivery - the slot must run and write *ok BEFORE handleLine() reads
    // it (the pointer is into handleLine's stack frame). If ControlServer were ever
    // moved to another thread, an auto/queued connection would (a) deliver AFTER emit
    // returns → the ack always reports false, and (b) write *ok into a since-unwound
    // stack frame → a use-after-free. Keep this Direct.
    }, Qt::DirectConnection);
    // A Pro key pasted in the Manager arrives here (single-writer: the Manager
    // pushes over IPC, the hub is the one that writes config). Persist + re-gate
    // live. Same Direct-connection discipline as uiStateReceived - `ok` is a
    // pointer into the socket handler's stack frame.
    QObject::connect(controlServer, &ControlServer::licenseKeyReceived, &engine,
                     [licenseBridge](const QString& key, bool* ok) {
        const bool applied = licenseBridge->applyExternalKey(key);
        if (ok) *ok = applied;
        if (!applied) qWarning() << "Failed to apply externally pushed licence key";
    }, Qt::DirectConnection);
    // Manager "Stop hub" → quit cleanly. Defer briefly so the "ok" ack flushes to
    // the socket before the event loop tears down.
    QObject::connect(controlServer, &ControlServer::shutdownRequested, &engine, [] {
        qInfo() << "Hub: shutdown requested by Manager";
        QTimer::singleShot(80, qApp, &QCoreApplication::quit);
    });
    // NOTE: start() is deferred until AFTER the display/autostart handlers are wired
    // below, so the socket never accepts a request the hub can't yet apply.

    // Load main QML
    engine.load(QUrl(QStringLiteral("qrc:/qml/main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "Failed to load QML";
        g_config = nullptr;   // clear before free so a late signal can't touch it
        xeneon_config_free(config);
        return 1;
    }

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &engine, [&engine]() {
        const auto flushed = xeneon::flushPendingUiState(engine.rootObjects());
        if (!flushed.ok())
            qWarning() << "Hub: clean-shutdown UI flush failed"
                       << "invoked:" << flushed.invoked
                       << "failed:" << flushed.failed;
    });

    // Window placement: QML starts invisible and Windowed (see main.qml).
    // C++ positions it on the target screen FIRST, then shows it.
    // This is critical for Wayland where the compositor controls placement.
    QWindow* mainWindow = qobject_cast<QWindow*>(engine.rootObjects().first());
    QScreen* placeScreen = nullptr;
    if (startupPlacement == StartupDisplayPlacement::MatchedTarget) {
        placeScreen = targetScreen;
    } else if (startupPlacement == StartupDisplayPlacement::PrimaryFallback
               || startupPlacement == StartupDisplayPlacement::PrimaryRecovery) {
        placeScreen = QGuiApplication::primaryScreen();
        if (startupPlacement == StartupDisplayPlacement::PrimaryRecovery) {
            qWarning() << "Configured target is absent; --reset-wizard requested, showing "
                          "windowed recovery on primary screen:"
                       << (placeScreen ? placeScreen->name() : QStringLiteral("<none>"));
        } else {
            qWarning() << "No target display configured or auto-detected; using primary "
                          "screen for first-run setup:"
                       << (placeScreen ? placeScreen->name() : QStringLiteral("<none>"));
        }
    } else {
        XeneonString fallback(xeneon_config_get_fallback_behavior(config));
        qWarning() << "Hub: configured target display is not attached; keeping window "
                      "hidden and waiting for reconnect (fallback:"
                   << fallback.qstring() << ")";
    }

    // Either screen may be null on a headless/no-display host. In the explicit
    // missing-target case placeScreen deliberately remains null, so the QML
    // window retains its initial Hidden visibility.
    if (mainWindow && placeScreen) {
        QRect geo = placeScreen->geometry();
        qInfo() << "Placing window on" << placeScreen->name()
                << "model:" << placeScreen->model()
                << "at" << geo.x() << "," << geo.y()
                << geo.width() << "x" << geo.height();

        // Position on the target screen BEFORE making visible
        mainWindow->setScreen(placeScreen);
        mainWindow->setPosition(geo.x(), geo.y());
        mainWindow->resize(geo.width(), geo.height());

        if (!windowedMode) {
            // Now safe to go fullscreen - we're on the right screen
            mainWindow->showFullScreen();
            mainWindow->setVisible(true);
            qInfo() << "Fullscreen on" << (mainWindow->screen() ? mainWindow->screen()->name() : QStringLiteral("(unknown screen)"));
        } else {
            mainWindow->show();
            mainWindow->setVisible(true);
            qInfo() << "Windowed on" << (mainWindow->screen() ? mainWindow->screen()->name() : QStringLiteral("(unknown screen)"));
        }
    }

    // Live orientation from the Edge's built-in sensor (read over its vendor HID
    // pipe). In "auto" mode QML rotates + reflows the UI to match. The manual
    // orientation modes ignore this and apply a fixed rotation instead.
    auto* orientation = new OrientationSensor(&app);
    // Remember orientation across runs: panels that answer no startup GET_REPORT
    // (only pushing on physical change) would otherwise restart mis-rotated until
    // the user turns the panel. The state file lives beside the config.
    orientation->setStatePath(XeneonString(xeneon_config_dir()).qstring()
                              + QStringLiteral("/orientation.state"));
    auto pushRotation = [&engine](int rot) {
        for (auto* obj : engine.rootObjects())
            obj->setProperty("sensorRotation", rot);
    };
    QObject::connect(orientation, &OrientationSensor::rotationChanged, &engine,
                     [pushRotation](int rot) {
        qInfo() << "Orientation sensor: content rotation" << rot << "deg";
        pushRotation(rot);
    });
    if (orientation->start() && orientation->rotation() >= 0)
        pushRotation(orientation->rotation());
    // Let a connected Manager mirror the panel's live orientation in its preview:
    // the getUiState reply carries the EFFECTIVE content rotation.
    //
    // This used to return the raw SENSOR rotation (orientation->rotation()),
    // which is -1 when the panel answers no startup GET_REPORT - but in that
    // very case the hub DEFAULTS its content to landscape (main.qml
    // contentRotation, "the Edge's primary orientation"). So the panel showed
    // landscape while the Manager, in auto, was told "unknown" and fell back to
    // portrait: hub horizontal, Manager vertical. Reported by the owner and
    // reproduced by tests/hardware/manager_reflection_test.py.
    //
    // main.qml's `contentRotation` is the single source of truth for what the
    // panel actually displays (it already folds the orientation mode together
    // with the sensor). Reporting THAT makes the Manager's auto preview mirror
    // the panel exactly. Safe to read here: ControlServer is parented to the
    // engine and never moved off the GUI thread, so this runs on the same thread
    // that owns the QML objects. Falls back to the raw sensor value if the root
    // has not exposed contentRotation (e.g. a future/alternate shell).
    controlServer->setRotationProvider([&engine, orientation]() -> int {
        for (auto* obj : engine.rootObjects()) {
            const QVariant v = obj->property("contentRotation");
            if (v.isValid())
                return v.toInt();
        }
        return orientation->rotation();
    });

    // O1 - Manager screen mirroring. The getUiState reply reports the page the
    // panel is showing (hubCurrentPage), and setActivePage asks the panel to show
    // the screen the Manager selected (requestHubPage). Both invoke QML functions
    // on the root, on the GUI thread (ControlServer is engine-parented, never
    // moved), so reading/driving the SwipeView here is safe.
    controlServer->setPageProvider([&engine]() -> int {
        for (auto* obj : engine.rootObjects()) {
            QVariant ret;
            if (QMetaObject::invokeMethod(obj, "hubCurrentPage",
                                          Q_RETURN_ARG(QVariant, ret)))
                return ret.toInt();
        }
        return -1;
    });
    controlServer->setActivePageHandler([&engine](int page) {
        for (auto* obj : engine.rootObjects())
            QMetaObject::invokeMethod(obj, "requestHubPage", Q_ARG(QVariant, page));
    });

    // Metrics on a dedicated worker thread (every 2s), so the Rust FFI collection
    // + JSON serialization never janks the GUI event loop. Results arrive on the
    // GUI thread via a queued signal and are pushed onto the QML roots. `metricsThread`
    // is declared BEFORE `metricsWorker` so the worker is destroyed first (while the
    // QThread object is still alive), after we join the thread below.
    QThread metricsThread;
    MetricsWorker metricsWorker;
    metricsWorker.moveToThread(&metricsThread);
    QObject::connect(&metricsThread, &QThread::started, &metricsWorker, &MetricsWorker::begin);
    QObject::connect(&metricsWorker, &MetricsWorker::metricsReady, &engine,
                     [&engine](const QByteArray& json) {
        for (auto* obj : engine.rootObjects())
            obj->setProperty("metricsJson", json);
    }, Qt::QueuedConnection);
    metricsThread.start();

    // Screen change monitoring. Pass &engine as the context object so these
    // connections are severed when the engine is destroyed - otherwise the
    // QGuiApplication (which outlives the engine) emits screenRemoved during its
    // own teardown and the lambda dereferences a freed engine.
    // On any hotplug, rebuild the FULL screen list and push it as `screensData`
    // (a proper notifiable string property) so the Display/Diagnostics tabs reflect
    // the live topology instead of the boot snapshot. The old code only set a
    // screen-name marker and never refreshed the list itself (S9). The distinct
    // added/removed name markers are kept for logging/toast affordances in QML.
    auto pushScreens = [&engine, buildScreensJson]() {
        const QByteArray json = buildScreensJson();
        for (auto* obj : engine.rootObjects())
            obj->setProperty("screensData", json);
    };

    // S10: honor the display disconnect/reconnect keys on live hotplug.
    //  - every TARGET loss hides immediately, regardless of fallback policy, so
    //    a compositor cannot relocate the fullscreen window onto primary.
    //  - notify_disconnect / fallback "notify" surface a disconnect signal.
    //  - fallback "ask" additionally requests display-selection guidance.
    //  - reconnect re-runs the target match and migrates back when it returns.
    // `targetScreen` is tracked live so we know which physical screen is ours, and
    // `targetHidden` remembers the safety hide so we can un-hide on reconnect.
    bool targetHidden = false;
    QObject::connect(&app, &QGuiApplication::screenAdded, &engine,
                     [&engine, config, &targetScreen, &targetHidden, &mainWindow,
                      windowedMode, pushScreens](QScreen* screen) {
        qInfo() << "Screen added:" << screen->name();
        const bool reconnectEnabled = xeneon_config_get_reconnect(config) == 1;
        // STRICT match (no primary fallback): only migrate onto the hotplugged
        // screen when it POSITIVELY identifies as the target. Otherwise plugging in
        // any unrelated (primary) monitor while the Edge is absent would make the hub
        // hijack it fullscreen and mislabel it as the target.
        QScreen* newTarget = findTargetScreenStrict(config);
        if (newTarget && shouldReconnectToScreen(reconnectEnabled, newTarget == screen) && mainWindow) {
            qInfo() << "Hub: target display returned - migrating window to" << screen->name();
            targetScreen = screen;
            const QRect geo = screen->geometry();
            mainWindow->setScreen(screen);
            mainWindow->setPosition(geo.x(), geo.y());
            mainWindow->resize(geo.width(), geo.height());
            if (windowedMode) mainWindow->show();
            else              mainWindow->showFullScreen();
            mainWindow->setVisible(true);
            targetHidden = false;
            closeDisplayDisconnectNotification();
            for (auto* obj : engine.rootObjects()) {
                obj->setProperty("displayDisconnected", QString());
                obj->setProperty("displaySelectionRequested", QString());
            }
        }
        for (auto* obj : engine.rootObjects())
            obj->setProperty("screenAddedChanged", screen->name());
        pushScreens();
    });
    auto handleScreenRemoved = [&engine, config, &targetScreen, &targetHidden,
                                &mainWindow, pushScreens](QScreen* screen) {
        qInfo() << "Screen removed:" << screen->name();
        const bool wasTarget = (screen == targetScreen);
        XeneonString fb(xeneon_config_get_fallback_behavior(config));
        const bool notifyDisconnect = xeneon_config_get_notify_disconnect(config) == 1;
        const TargetRemovalSafetyDecision d = decideTargetRemovalSafety(
            wasTarget, fb.qstring(), notifyDisconnect);
        if (d.hideWindow && mainWindow) {
            // Hide before notifications/list refreshes: Qt/compositors may already
            // be reassigning windows from the removed output to primary.
            mainWindow->setVisible(false);
            targetHidden = true;
            qInfo() << "Hub: target display removed; window hidden before compositor "
                       "fallback (policy:"
                    << fb.qstring() << ")";
        }
        if (d.notify) {
            qWarning() << "Hub: target display disconnected:" << screen->name();
            sendDisplayDisconnectNotification(
                displayDisconnectNotice(screen->name(), d.requestSelection));
            for (auto* obj : engine.rootObjects())
                obj->setProperty("displayDisconnected", screen->name());
        }
        if (d.requestSelection) {
            qWarning() << "Hub: fallback=ask; display selection is required in the Manager";
            for (auto* obj : engine.rootObjects())
                obj->setProperty("displaySelectionRequested", screen->name());
        }
        if (wasTarget) targetScreen = nullptr;   // target gone until it returns
        for (auto* obj : engine.rootObjects())
            obj->setProperty("screenRemovedChanged", screen->name());
        pushScreens();
    };
    QObject::connect(&app, &QGuiApplication::screenRemoved, &engine, handleScreenRemoved);
#ifdef XENEON_QA_HOOKS
    // Offscreen Qt exposes only one immutable virtual QScreen, so the smoke suite
    // cannot physically unplug it. This QA-only seam invokes the EXACT production
    // handler against the current window screen and reports the resulting visibility.
    // It is compiled out of release packages and makes no hardware-coverage claim.
    if (qEnvironmentVariableIsSet("XENEON_SIMULATE_TARGET_REMOVAL")) {
        QTimer::singleShot(350, &engine,
                           [&targetScreen, &mainWindow, handleScreenRemoved]() {
            QScreen* simulatedTarget = mainWindow ? mainWindow->screen() : nullptr;
            if (!simulatedTarget) {
                qWarning() << "Hub QA target-removal simulation skipped: no window screen";
                return;
            }
            targetScreen = simulatedTarget;
            handleScreenRemoved(simulatedTarget);
            qInfo() << "Hub QA simulated target removal; visible:"
                    << (mainWindow && mainWindow->isVisible());
        });
    }
#endif
    // A primary-screen swap (e.g. the Edge becomes/stops being primary) changes the
    // isPrimary flags without an add/remove, so refresh on that too.
    QObject::connect(&app, &QGuiApplication::primaryScreenChanged, &engine,
                     [pushScreens](QScreen*) { pushScreens(); });

    // B5 (two-writer race): while the hub runs it is the SINGLE writer of
    // config.toml, so the Manager stops writing display/startup fields itself and
    // asks us to apply them. Adopting into the live config is what makes that safe -
    // a handler that only re-saved the file would still be overwritten by our own
    // next save from an in-memory config that never saw the change.
    //
    // These are wired here (not next to the ControlServer construction above)
    // because applying a target display LIVE needs the window + hotplug state that
    // only exists past window placement. The event loop starts at app.exec(), so no
    // request can arrive before this point.
    QObject::connect(controlServer, &ControlServer::targetDisplayReceived, &engine,
                     [&engine, config, &targetScreen, &mainWindow, windowedMode](
                         const QString& connector, const QString& model, bool* ok) {
        xeneon_config_set_target_connector(config, connector.toUtf8().constData());
        xeneon_config_set_target_model(config, model.toUtf8().constData());
        const bool saved = xeneon_config_save(config) == 0;
        if (!saved)
            qWarning() << "Hub: failed to persist target display" << connector << model;
        if (ok) *ok = saved;

        // Live-apply: re-run the SAME match + placement the hub does at boot, so the
        // choice takes effect now instead of at the next start. STRICT (no primary
        // fallback) - a target that isn't attached must not make the hub hijack
        // whatever screen happens to be primary.
        engine.rootContext()->setContextProperty("_targetConnector", connector);
        engine.rootContext()->setContextProperty("_targetModel", model);
        QScreen* s = findTargetScreenStrict(config);
        if (s && mainWindow) {
            qInfo() << "Hub: target display set to" << connector << model
                    << "- migrating window to" << s->name();
            targetScreen = s;
            const QRect geo = s->geometry();
            mainWindow->setScreen(s);
            mainWindow->setPosition(geo.x(), geo.y());
            mainWindow->resize(geo.width(), geo.height());
            if (windowedMode) mainWindow->show();
            else              mainWindow->showFullScreen();
            mainWindow->setVisible(true);
        } else {
            qWarning() << "Hub: target display" << connector << model
                       << "is not attached - saved, placement unchanged";
        }
    }, Qt::DirectConnection);   // see the uiStateReceived connection: `ok` is a stack pointer
    QObject::connect(controlServer, &ControlServer::autostartReceived, &engine,
                     [config](bool enabled, bool* ok) {
        xeneon_config_set_autostart(config, enabled ? 1 : 0);
        // The flag on its own does nothing at runtime - the EFFECTIVE state is the
        // XDG autostart entry (the same one the first-run wizard installs), so write
        // it here. Both halves must succeed for the ack to be honest: the client's
        // "is autostart on?" readback reads the entry, not the flag.
        const bool fileOk = applyAutostart(enabled);
        const bool saved = xeneon_config_save(config) == 0;
        if (!fileOk) qWarning() << "Hub: autostart .desktop write failed";
        if (!saved)  qWarning() << "Hub: failed to persist autostart flag";
        if (ok) *ok = fileOk && saved;
    }, Qt::DirectConnection);
    controlServer->start();

    // QA capture: XENEON_GRAB=<path> renders the window to a PNG and quits (mirrors
    // the Manager). Optional XENEON_GRAB_W / XENEON_GRAB_H resize the window first so
    // a tall portrait shell renders fully on a smaller dev monitor. Always quits, so
    // a headless/bg run can never hang (addresses the earlier no-fallback-quit note).
    const QString grabPath = qaGrabPath;   // empty unless built with XENEON_QA_HOOKS
    if (!grabPath.isEmpty()) {
        if (mainWindow) {
            const int gw = qEnvironmentVariable("XENEON_GRAB_W", "0").toInt();
            const int gh = qEnvironmentVariable("XENEON_GRAB_H", "0").toInt();
            if (gw > 0 && gh > 0) {
                mainWindow->setVisibility(QWindow::Windowed);
                mainWindow->resize(gw, gh);
            }
        }
        QObject* root = engine.rootObjects().first();
        QTimer::singleShot(2200, [root, grabPath]() {
            auto* win = qobject_cast<QQuickWindow*>(root);
            if (win) {
                const QImage img = win->grabWindow();
                if (!img.isNull() && img.save(grabPath))
                    qInfo() << "Hub: saved grab to" << grabPath;
                else
                    qWarning() << "Hub: grab failed";
            } else {
                qWarning() << "Hub: grab skipped (root is not a window)";
            }
            QCoreApplication::quit();
        });
    }

    int result = app.exec();

    // Stop the metrics worker (delete its timer on the worker thread) and join the
    // thread before any stack teardown, so no metrics callback fires into a
    // half-destroyed engine.
    QMetaObject::invokeMethod(&metricsWorker, "stop", Qt::BlockingQueuedConnection);
    metricsThread.quit();
    metricsThread.wait();

    // Save configuration on clean exit while the handle is still valid.
    xeneon_config_save(config);

    // Detach the QML bridges from the config handle BEFORE freeing it. The
    // engine is a stack object destroyed after this scope returns; a late
    // Component.onDestruction handler calling configBridge.saveUiState()/uiState()
    // would otherwise dereference freed memory. Clear g_config first so the
    // signal handler can't touch it either.
    configBridge->detach();
    wizardBridge->detach();
    g_config = nullptr;
    xeneon_config_free(config);

    return result;
}
