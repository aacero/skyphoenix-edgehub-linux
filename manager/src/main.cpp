// Xeneon Edge Manager - a standalone companion desktop app to manage the Edge
// hub: build/reorder the widget layout, tune appearance, upload images, and set
// display/startup options. It edits the SAME config the hub reads (via the Rust
// core) and, when the hub is running, stays in live sync over the hub's local
// control socket (pushes its own edits, pulls the hub's). Works with or without
// the hub running.

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QString>
#include <QTimer>
#include <QImage>
#include <QPalette>
#include <QColor>
#include <QQuickWindow>
#include <QQuickStyle>
#include <QScreen>
#include <QRect>
#include <QSize>
#include <QUrl>

#include "xeneon_core.h"
#include "manager_backend.h"
#include "manager_display_policy.h"
#include <cstdio>
#include "../../app/src/single_instance.h"
#include "../../app/src/timezone_bridge.h"
#include "../../app/src/distro_bridge.h"
#include "../../app/src/system_settings_probe.h"
#include "../../app/src/network_access_policy.h"
#include "../../app/src/shutdown_flush.h"

// Build a dark QPalette from the app's dark design tokens. Fusion (set below)
// draws every Qt Quick control that ISN'T hand-restyled (Switch/Slider/Button/
// ScrollBar/Dialog button-boxes) from the application palette; without this it
// falls back to Fusion's default LIGHT gray, which looks broken on the dark UI.
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
    // Disabled group: dim text/placeholder so inactive controls read as muted.
    pal.setColor(QPalette::Disabled, QPalette::Text, muted);
    pal.setColor(QPalette::Disabled, QPalette::WindowText, muted);
    pal.setColor(QPalette::Disabled, QPalette::ButtonText, muted);
    pal.setColor(QPalette::Disabled, QPalette::Highlight, alt);
    return pal;
}

// Is this screen the Xeneon Edge? Mirrors the hub's `likelyXeneonEdge` heuristic
// (app/src/main.cpp): by model/manufacturer, or the panel's telltale resolution
// in either orientation.
static bool screenIsEdge(const QScreen* s) {
    if (!s) return false;
    return managerScreenIsEdge({s->model(), s->manufacturer(), s->size()});
}

// The Manager must never OPEN on the Edge (it configures it). Place it on a
// non-Edge screen, preferring the primary, centered. Return false instead of
// mapping the window when the Edge is the only detected display.
static bool placeManagerOffEdge(QQuickWindow* win) {
    if (!win) return false;
    const QList<QScreen*> screens = QGuiApplication::screens();
    QVector<ManagerScreenIdentity> identities;
    identities.reserve(screens.size());
    for (QScreen* screen : screens)
        identities.append({screen->model(), screen->manufacturer(), screen->size()});
    const int primaryIndex = screens.indexOf(QGuiApplication::primaryScreen());
    const int targetIndex = managerSafeScreenIndex(identities, primaryIndex);
    if (targetIndex < 0) {
        std::fprintf(stderr,
                     "Manager refused to open: no non-Edge display is available.\n");
        std::fflush(stderr);
        return false;
    }
    QScreen* target = screens.at(targetIndex);
    // Always assert the screen + a centred position on it, even if Qt already
    // reports this as the current screen: it is the explicit placement hint the
    // compositor reads for the first map, and skipping it let the compositor fall
    // back to "open on the active output" (the Edge, right after the hub grabbed it).
    win->setScreen(target);
    const QRect g = target->availableGeometry();
    const int px = g.x() + (g.width() - win->width()) / 2;
    const int py = g.y() + (g.height() - win->height()) / 2;
    win->setPosition(px, py);
    // Log the final rect the way the hub logs its own placement. This is the
    // ONLY machine-readable source for where the Manager window actually landed:
    // it has no control socket, and KWin exposes no window geometry over DBus
    // without loading a script. tests/hardware/desktop_target.py parses this to
    // clamp synthetic input to the WINDOW rect rather than the whole monitor -
    // i.e. it is what keeps real-input tests from clicking outside the app.
    // fprintf, NOT qInfo: Qt's default handler routes to journald when stderr is
    // not a TTY (see the single-instance message below), so a redirected log file
    // would silently miss this line - and a test that cannot read the rect must
    // refuse to inject, which would make the whole suite unrunnable.
    std::fprintf(stderr, "Placing Manager on \"%s\" at %d , %d %d x %d\n",
                 target->name().toUtf8().constData(), px, py,
                 win->width(), win->height());
    std::fflush(stderr);
    return true;
}

static bool showManagerOffEdge(QQuickWindow* win) {
    if (!placeManagerOffEdge(win)) return false;
    QObject::connect(win, &QQuickWindow::screenChanged, win, [win](QScreen* screen) {
        if (!screenIsEdge(screen)) return;
        win->hide();
        qCritical() << "Manager closed because the compositor placed it on the Edge";
        QCoreApplication::exit(2);
    });
    win->setVisible(true);
    QTimer::singleShot(0, win, [win]() {
        if (!screenIsEdge(win->screen())) return;
        win->hide();
        qCritical() << "Manager closed because it opened on the Edge";
        QCoreApplication::exit(2);
    });
    return true;
}

int main(int argc, char* argv[]) {
    // KPI "local file" source reads a file:// path via QML XMLHttpRequest; Qt
    // gates that behind this flag. Local read only - no network path is opened.
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");

    // --version BEFORE QGuiApplication: the Manager used to ignore the flag and
    // just launch the GUI, so anything asking it "which build are you?" got a
    // window instead of an answer (and blocked). A test that cannot ask a binary
    // its version cannot refuse to test a stale one.
    for (int i = 1; i < argc; ++i) {
        const QByteArray a(argv[i]);
        if (a == "--version" || a == "-v") {
#ifdef XENEON_VERSION
            std::printf("Xeneon Edge Manager %s\n", XENEON_VERSION);
#else
            std::printf("Xeneon Edge Manager 0.1.0\n");
#endif
            return 0;
        }
    }

    xeneon_logging_init("info");
    QGuiApplication app(argc, argv);
    app.setApplicationName("Xeneon Edge Manager");
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

    // Fusion style so Switch/Button/Slider render properly on the desktop, with a
    // dark palette so those unstyled controls match the dark UI (not light gray).
    QQuickStyle::setStyle(QStringLiteral("Fusion"));
    QGuiApplication::setPalette(darkPalette());

    // QA automation hooks compiled in only under XENEON_QA_HOOKS (CI/tests/
    // marketing); inert in production packages.
#ifdef XENEON_QA_HOOKS
    const bool    qaGrabMode = qEnvironmentVariableIsSet("XENEON_GRAB");
    const QString qaGrabPath = qEnvironmentVariable("XENEON_GRAB");
#else
    const bool    qaGrabMode = false;
    const QString qaGrabPath;
#endif

    // Single-instance guard - multiple managers writing config.toml race the hub
    // and each other. Skipped in grab mode for headless QA captures.
    auto instanceLock = xeneon::acquireSingleInstance(
        QStringLiteral("manager"), qaGrabMode);
    if (!instanceLock) {
        // fprintf (not qWarning): Qt's default handler routes to journald when
        // stderr isn't a TTY, so a plain write guarantees the message is visible.
        std::fprintf(stderr, "Another Xeneon Edge Manager is already running - exiting.\n");
        std::fflush(stderr);
        return 0;
    }

    // Declare the backend BEFORE the engine so it outlives it (locals destroy in
    // reverse order; the engine holds context-property references to the backend).
    ManagerBackend backend;
    XeneonNetworkAccessManagerFactory networkAccessFactory;
    QQmlApplicationEngine engine;
    engine.setNetworkAccessManagerFactory(&networkAccessFactory);
    engine.rootContext()->setContextProperty("configBridge", &backend);
    engine.rootContext()->setContextProperty("backend", &backend);

    // The Manager renders live widget PREVIEWS of the same QML, so it needs the
    // same time-zone bridge the hub has - without it a world clock in the preview
    // would silently fall back to a fixed offset and disagree with the Edge.
    TimeZoneBridge timeZoneBridge;
    engine.rootContext()->setContextProperty("timeZones", &timeZoneBridge);

    // Same reasoning for the distro bridge: the Manager previews PackagesWidget /
    // SinceInstallWidget, and without this they would render their "unknown"
    // placeholder in the preview while the Edge showed a real count.
    DistroBridge distroBridge;
    engine.rootContext()->setContextProperty("distro", &distroBridge);

    // Same OS reduce-motion probe as the hub (XDG settings portal), so the
    // Manager's live previews honor the desktop's a11y setting too.
    SystemSettingsProbe systemSettings;
    systemSettings.start();
    engine.rootContext()->setContextProperty("systemSettings", &systemSettings);

    // Keep the window hidden until we've placed it off the Edge (see below). Set
    // before load so the QML `visible` binding starts false; we show it ourselves.
    engine.rootContext()->setContextProperty("_deferInitialShow", true);

    engine.load(QUrl(QStringLiteral("qrc:/manager/Manager.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "Manager: failed to load QML";
        return 1;
    }

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &engine, [&engine, &backend]() {
        const auto flushed = xeneon::flushPendingUiState(engine.rootObjects());
        const bool persisted = flushed.ok() && backend.confirmShutdownUiStatePersisted();
        if (!persisted)
            qWarning() << "Manager: clean-shutdown UI flush failed"
                       << "invoked:" << flushed.invoked
                       << "failed:" << flushed.failed
                       << "hub-confirmed:" << persisted;
    });

    // Doc/review capture: XENEON_GRAB=<path> renders the window to a PNG and quits.
    // Optional XENEON_GRAB_W / XENEON_GRAB_H resize the window first - without them an
    // offscreen grab is clamped to the offscreen platform's tiny virtual screen, so a
    // UX audit of the panes could never see them at the size a user sees (mirrors the
    // hub's branch in app/src/main.cpp; W5 finding 19).
    const QString grabPath = qaGrabPath;   // empty unless built with XENEON_QA_HOOKS
    if (!grabPath.isEmpty()) {
        if (auto* gwin = qobject_cast<QQuickWindow*>(engine.rootObjects().first())) {
            const int gw = qEnvironmentVariable("XENEON_GRAB_W", "0").toInt();
            const int gh = qEnvironmentVariable("XENEON_GRAB_H", "0").toInt();
            if (gw > 0 && gh > 0) gwin->resize(gw, gh);
            if (!showManagerOffEdge(gwin)) return 2;
        }
        QObject* root = engine.rootObjects().first();
        QTimer::singleShot(1800, [root, grabPath]() {
            auto* win = qobject_cast<QQuickWindow*>(root);
            if (win) {
                const QImage img = win->grabWindow();
                if (!img.isNull() && img.save(grabPath))
                    qInfo() << "Manager: saved grab to" << grabPath;
                else
                    qWarning() << "Manager: grab failed";
            } else {
                qWarning() << "Manager: grab skipped (root is not a window)";
            }
            QCoreApplication::quit();   // always quit so a headless run never hangs
        });
    } else {
        // Normal launch: keep the Manager OFF the Edge. It configures the Edge, so
        // it must never open ON it - which is exactly what happened after the hub
        // grabbed the Edge fullscreen and a launcher (e.g. update-local.sh) started
        // the Manager onto the now-active output. The QML window starts HIDDEN; we
        // pick a non-Edge screen (prefer the primary) and only THEN show it, because
        // a Wayland client can only choose its output before the surface is mapped.
        if (auto* w = qobject_cast<QQuickWindow*>(engine.rootObjects().first())) {
            if (!showManagerOffEdge(w)) return 2;
        }
    }

    return app.exec();
}
