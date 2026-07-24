// Integration tests for ManagerBackend: live two-way sync with a fake hub over a
// REAL QLocalSocket, PULL-before-PUSH reconnect reconciliation, the post-push
// suppression window (driven by an INJECTED clock so there is zero real waiting),
// and the image import/delete/sanitize surface. Needs a QGuiApplication (offscreen).
#include <QtTest>
#include <QStandardPaths>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QImage>
#include <QTemporaryFile>

#include "autostart.h"
#include "control_server.h"
#include "manager_backend.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

// Bind exactly where production resolves it (manager_backend.h pulls in the
// same header), so the fake hub and the ManagerBackend under test cannot
// drift apart - and so this never binds the shared /tmp node a live hub used
// to own. See app/src/control_socket_path.h.
static QString kSock() { return xeneon::controlSocketPath(); }

// Emulates the REAL hub for the B5 two-writer-race tests: the REAL ControlServer
// wired to a REAL ConfigHandle exactly as app/src/main.cpp wires it (minus the
// window migration, which needs a live QScreen the offscreen platform can't give).
// This is what lets a test reproduce "the hub's next save reverts the Manager's
// change" - a hand-rolled fake that never held a config could not.
class HubEmu : public QObject {
    Q_OBJECT
public:
    ConfigHandle* cfg = nullptr;
    ControlServer srv;
    bool failApply = false;           // make the owner's apply report failure

    HubEmu() {
        cfg = xeneon_config_load();
        connect(&srv, &ControlServer::targetDisplayReceived, this,
                [this](const QString& c, const QString& m, bool* ok) {
                    if (failApply) { if (ok) *ok = false; return; }
                    xeneon_config_set_target_connector(cfg, c.toUtf8().constData());
                    xeneon_config_set_target_model(cfg, m.toUtf8().constData());
                    if (ok) *ok = xeneon_config_save(cfg) == 0;
                }, Qt::DirectConnection);
        connect(&srv, &ControlServer::autostartReceived, this,
                [this](bool enabled, bool* ok) {
                    if (failApply) { if (ok) *ok = false; return; }
                    xeneon_config_set_autostart(cfg, enabled ? 1 : 0);
                    const bool fileOk = applyAutostart(enabled);
                    if (ok) *ok = fileOk && xeneon_config_save(cfg) == 0;
                }, Qt::DirectConnection);
        connect(&srv, &ControlServer::licenseKeyReceived, this,
                [this](const QString& key, bool* ok) {
                    if (failApply) { if (ok) *ok = false; return; }
                    const QByteArray bytes = key.toUtf8();
                    xeneon_config_set_license_key(
                        cfg, key.isEmpty() ? nullptr : bytes.constData());
                    if (ok) *ok = xeneon_config_save(cfg) == 0;
                }, Qt::DirectConnection);
    }
    ~HubEmu() override { if (cfg) xeneon_config_free(cfg); }

    // What the real hub does on clean exit / SIGTERM (app/src/main.cpp): persist its
    // in-memory config. THIS is the write that used to revert the Manager's edit.
    void save() { QVERIFY(xeneon_config_save(cfg) == 0); }
};

// A minimal stand-in for the hub's ControlServer: records the requests it receives
// and lets the test push uiState replies on demand.
class FakeHub : public QObject {
    Q_OBJECT
public:
    QLocalServer server;
    QLocalSocket* client = nullptr;
    QByteArray rx;
    QString getReply;                 // state returned for getUiState
    QStringList received;             // request types, in order
    QStringList setStates;            // states received via setUiState
    QList<int> activePages;           // page payloads received via setActivePage
    bool holdGet = false;             // when true, DON'T auto-reply to getUiState…
    bool getPending = false;          // …record that one is owed, release it later

    bool start() {
        QLocalServer::removeServer(kSock());
        connect(&server, &QLocalServer::newConnection, this, [this] {
            client = server.nextPendingConnection();
            connect(client, &QLocalSocket::readyRead, this, &FakeHub::onRx);
        });
        return server.listen(kSock());
    }
    void sendUiState(const QString& state, int rotation = -1000) {
        if (!client) return;
        QJsonObject reply{{"type", "uiState"}, {"state", state}};
        if (rotation != -1000)
            reply.insert(QStringLiteral("rotation"), rotation);
        client->write(QJsonDocument(reply).toJson(QJsonDocument::Compact));
        client->write("\n");
        client->flush();
    }
    void sendAck(bool ok, const QString& forType, const QString& message = QString()) {
        if (!client) return;
        QJsonObject reply{{"type", ok ? "ok" : "error"}, {"for", forType}};
        if (!ok) reply.insert(QStringLiteral("message"), message);
        client->write(QJsonDocument(reply).toJson(QJsonDocument::Compact));
        client->write("\n");
        client->flush();
    }
    // Release a getUiState reply that was withheld while holdGet was set.
    void releaseGet() {
        if (getPending) { getPending = false; sendUiState(getReply); }
    }
private slots:
    void onRx() {
        rx += client->readAll();
        int nl;
        while ((nl = rx.indexOf('\n')) >= 0) {
            const QByteArray line = rx.left(nl);
            rx.remove(0, nl + 1);
            const QJsonObject o = QJsonDocument::fromJson(line).object();
            const QString type = o.value("type").toString();
            received << type;
            if (type == "getUiState") {
                if (holdGet) getPending = true;   // slip an edit into the reply window
                else sendUiState(getReply);
            } else if (type == "setUiState") {
                setStates << o.value("state").toString();
                sendAck(true, QStringLiteral("setUiState"));
            } else if (type == "setActivePage") {
                activePages << o.value("page").toInt(-1);
            }
        }
    }
};

class TstManagerBackendSync : public QObject {
    Q_OBJECT
    qint64 clockMs_ = 100000;
private slots:

    // ── Image surface (no socket needed) ──
    void importImageUniqueNaming() {
        ManagerBackend b;
        const QString imgDir = b.imagesDir();
        // Fresh dir.
        for (const QString& f : QDir(imgDir).entryList(QDir::Files)) QFile::remove(imgDir + "/" + f);

        const QString src = QDir::tempPath() + "/xe-src.png";
        QImage(4, 4, QImage::Format_RGB32).save(src, "PNG");

        const QString n1 = b.importImage("file://" + src);
        QCOMPARE(n1, QStringLiteral("xe-src.png"));
        QVERIFY(QFile::exists(imgDir + "/" + n1));

        // A second import of the same basename must NOT overwrite → unique name.
        const QString n2 = b.importImage("file://" + src);
        QVERIFY(n2 != n1);
        QCOMPARE(n2, QStringLiteral("xe-src-1.png"));
        QVERIFY(QFile::exists(imgDir + "/" + n2));

        // Unreadable source → empty.
        QVERIFY(b.importImage("file:///no/such/file.png").isEmpty());

        // A sparse source just over the synchronous-copy cap is rejected before
        // QFile::copy, so a huge/network-backed file cannot freeze the UI thread.
        QTemporaryFile oversized;
        QVERIFY(oversized.open());
        QVERIFY(oversized.resize((25LL << 20) + 1));
        QVERIFY(b.importImage(oversized.fileName()).isEmpty());
    }

    void deleteImageAndTraversal() {
        ManagerBackend b;
        const QString imgDir = b.imagesDir();
        const QString src = QDir::tempPath() + "/xe-del.png";
        QImage(4, 4, QImage::Format_RGB32).save(src, "PNG");
        const QString name = b.importImage("file://" + src);
        QVERIFY(QFile::exists(imgDir + "/" + name));

        // A crafted traversal name must not delete anything outside the images dir.
        const QString outside = QFileInfo(imgDir).absolutePath() + "/keep.txt";
        QFile kf(outside); QVERIFY(kf.open(QIODevice::WriteOnly)); kf.write("x"); kf.close();
        QVERIFY(!b.deleteImage("../keep.txt"));
        QVERIFY(QFile::exists(outside));      // untouched
        QFile::remove(outside);

        // A real image deletes.
        QVERIFY(b.deleteImage(name));
        QVERIFY(!QFile::exists(imgDir + "/" + name));
    }

    // ── Live push on save (connected) ──
    void livePushOnSave() {
        FakeHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        b.saveUiState(QStringLiteral("{\"pushed\":1}"));
        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 5000);
        QCOMPARE(hub.setStates.last(), QStringLiteral("{\"pushed\":1}"));

        b.setHubActivePage(3);
        QTRY_VERIFY_WITH_TIMEOUT(!hub.activePages.isEmpty(), 5000);
        QCOMPARE(hub.activePages.last(), 3);

        // startHub is a no-op success when a hub is already connected (no 2nd instance).
        QVERIFY(b.startHub());
        // stopHub over a connected socket asks the hub to quit (shutdown message).
        QVERIFY(b.stopHub());
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("shutdown")), 5000);
    }

    void cleanShutdownWaitsForTheHubPersistenceAck() {
        FakeHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.saveUiState(QStringLiteral("{\"shutdown\":1}")));
        QVERIFY(b.confirmShutdownUiStatePersisted());
        QCOMPARE(hub.setStates.last(), QStringLiteral("{\"shutdown\":1}"));
    }

    // ── Invokable/config/env surface exercised without a hub (single-writer offline). ──
    void invokableSurface() {
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });

        // Metrics + config getters return well-formed, non-null JSON strings.
        QVERIFY(b.metricsJson().startsWith('{'));
        QVERIFY(!b.configJson().isEmpty());
        QVERIFY(!b.appVersion().isEmpty());
        QCOMPARE(b.hubRotation(), -1);
        b.saveUiState(QStringLiteral("{\"k\":1}"));            // offline persist
        QCOMPARE(b.uiState(), QStringLiteral("{\"k\":1}"));
        const QString starter = b.starterLayout();
        QVERIFY(starter.isEmpty() || starter.startsWith('{') || starter.startsWith('['));

        // Target display round-trips through the config.
        QVERIFY(b.setTargetDisplay(QStringLiteral("DP-2"), QStringLiteral("XENEON EDGE")));
        QCOMPARE(b.targetConnector(), QStringLiteral("DP-2"));
        QCOMPARE(b.targetModel(), QStringLiteral("XENEON EDGE"));

        // Offscreen platform hides the bogus 800x800 screen → "[]".
        QCOMPARE(b.screensJson(), QStringLiteral("[]"));

        // imageUrl: empty name → empty; a real name → a file:// URL for that file.
        QVERIFY(b.imageUrl(QString()).isEmpty());
        const QString url = b.imageUrl(QStringLiteral("a b.png"));
        QVERIFY(url.startsWith(QStringLiteral("file://")));
        QVERIFY(url.endsWith(QStringLiteral("a b.png")) || url.contains(QStringLiteral("%20")));
        // A path component is stripped to the bare filename (no traversal in the URL).
        QVERIFY(!b.imageUrl(QStringLiteral("../../etc/passwd")).contains(QStringLiteral("..")));

        // Dev affordances default to empty/0 when the env vars are unset.
        qunsetenv("XENEON_GRAB"); qunsetenv("XENEON_TAB"); qunsetenv("XENEON_CFG");
        QVERIFY(b.grabPath().isEmpty());
        QCOMPARE(b.startTab(), 0);
        QVERIFY(b.autoConfig().isEmpty());

        b.listImages();                 // returns without crashing (possibly empty)
        b.setHubActivePage(7);          // offline is a safe no-op
        QVERIFY(!b.stopHub());          // no hub connected → honest false
    }

    void diagnosticsConfigIsStructuredAndRedacted() {
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        const QString state = QString::fromUtf8(
            "{\"pages\":[{\"name\":\"MANAGER_PRIVATE_PAGE_CANARY\","
            "\"tiles\":[{\"type\":\"meds\"}]}],\"settings\":{"
            "\"meds-1\":{\"medication\":\"MANAGER_MEDICATION_CANARY\"},"
            "\"tasks-1\":{\"tasks\":[\"MANAGER_TASK_CANARY\"]},"
            "\"calendar-1\":{\"url\":\"https://MANAGER_PRIVATE_URL_CANARY\"},"
            "\"http-1\":{\"authToken\":\"MANAGER_AUTH_CANARY\"}}}");
        QVERIFY(b.saveUiState(state));
        QVERIFY(b.setLicenseKey(QStringLiteral("XE1.MANAGER_KEY_CANARY.MANAGER_IDENTITY_CANARY")));

        const QString rendered = b.configJson();
        for (const QString& canary : {
                 QStringLiteral("MANAGER_PRIVATE_PAGE_CANARY"),
                 QStringLiteral("MANAGER_MEDICATION_CANARY"),
                 QStringLiteral("MANAGER_TASK_CANARY"),
                 QStringLiteral("MANAGER_PRIVATE_URL_CANARY"),
                 QStringLiteral("MANAGER_AUTH_CANARY"),
                 QStringLiteral("MANAGER_KEY_CANARY"),
                 QStringLiteral("MANAGER_IDENTITY_CANARY")}) {
            QVERIFY2(!rendered.contains(canary), qPrintable("diagnostics leaked " + canary));
        }
        const QJsonObject summary = QJsonDocument::fromJson(rendered.toUtf8()).object();
        QCOMPARE(summary.value(QStringLiteral("format")).toString(),
                 QStringLiteral("xeneon-config-diagnostics-v1"));
        QCOMPARE(summary.value(QStringLiteral("redaction")).toObject()
                     .value(QStringLiteral("raw_config_available")).toBool(), false);

        QVERIFY(b.clearLicenseKey());
        QVERIFY(b.saveUiState(QStringLiteral("{}")));
    }

    // ── Licensing surface: candidate preview, stored status, offline persistence,
    //    explicit clear, and change notifications all use the real Rust verifier. ──
    void licenseOfflineSurface() {
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QVERIFY(!b.hubConnected());

        const auto parse = [](const QString& json) {
            QJsonParseError err{};
            const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &err);
            [&] { QCOMPARE(err.error, QJsonParseError::NoError); QVERIFY(doc.isObject()); }();
            return doc.object();
        };

        const QJsonObject candidate = parse(b.verifyLicenseCandidate(QStringLiteral("garbage")));
        QCOMPARE(candidate.value(QStringLiteral("state")).toString(),
                 QStringLiteral("unlicensed"));
        QCOMPARE(candidate.value(QStringLiteral("tier")).toString(), QStringLiteral("free"));

        const QJsonObject before = parse(b.licenseStatusJson());
        QVERIFY(before.contains(QStringLiteral("state")));
        QVERIFY(before.contains(QStringLiteral("tier")));

        QSignalSpy changed(&b, &ManagerBackend::licenseChanged);
        QSignalSpy errors(&b, &ManagerBackend::saveError);
        QVERIFY(b.setLicenseKey(QStringLiteral("garbage")));
        QCOMPARE(changed.count(), 1);
        QCOMPARE(errors.count(), 0);
        const QJsonObject stored = parse(b.licenseStatusJson());
        QCOMPARE(stored.value(QStringLiteral("tier")).toString(), QStringLiteral("free"));

        QVERIFY(b.clearLicenseKey());
        QCOMPARE(changed.count(), 2);
        QCOMPARE(errors.count(), 0);
    }

    // Connected writes must go through the Hub's ControlServer (the sole config
    // writer), wait for its tagged ack, and support an explicit empty-string clear.
    void licenseConnectedSingleWriter() {
        HubEmu hub;
        QVERIFY(hub.srv.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QSignalSpy changed(&b, &ManagerBackend::licenseChanged);
        QVERIFY(b.setLicenseKey(QStringLiteral("XE1.invalid.signature")));
        QCOMPARE(changed.count(), 1);
        XeneonString setKey(xeneon_config_get_license_key(hub.cfg));
        QCOMPARE(setKey.qstring(), QStringLiteral("XE1.invalid.signature"));

        QVERIFY(b.clearLicenseKey());
        QCOMPARE(changed.count(), 2);
        XeneonString cleared(xeneon_config_get_license_key(hub.cfg));
        QVERIFY(cleared.qstring().isEmpty());
    }

    // ── Autostart install/remove via the Manager surface (HOME = per-test temp). ──
    void autostartSurface() {
        ManagerBackend b;
        // ConfigLocation, matching applyAutostart(): homePath() was the sandbox-escape
        // bug - see tst_autostart::entryFollowsXdgNotHome.
        const QString entry = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                              + "/autostart/xeneon-edge-hub.desktop";
        QFile::remove(entry);
        QVERIFY(!b.isAutostart());
        QVERIFY(b.setAutostart(true));
        QVERIFY(b.isAutostart());
        QVERIFY(QFile::exists(entry));
        QVERIFY(b.setAutostart(false));
        QVERIFY(!b.isAutostart());
        QVERIFY(!QFile::exists(entry));
        // Disabling again when already absent is honest success (nothing to remove).
        QVERIFY(b.setAutostart(false));
        QVERIFY(!b.isAutostart());
    }

    // ── Adopt the hub's pushed state once outside the suppression window ──
    void adoptFromHub() {
        FakeHub hub; hub.getReply = QString(); QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);

        QSignalSpy spy(&b, &ManagerBackend::configChanged);
        QSignalSpy rotations(&b, &ManagerBackend::hubRotationChanged);
        hub.sendUiState(QStringLiteral("{\"fromhub\":7}"), 90);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
        QCOMPARE(b.uiState(), QStringLiteral("{\"fromhub\":7}"));
        QCOMPARE(b.hubRotation(), 90);
        QCOMPARE(rotations.count(), 1);

        // Repeating the same orientation must not churn the preview binding.
        hub.sendUiState(QStringLiteral("{\"fromhub\":8}"), 90);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), QStringLiteral("{\"fromhub\":8}"), 5000);
        QCOMPARE(rotations.count(), 1);
    }

    // ── Suppression window: a stale hub reply right after our push is IGNORED, while
    //    a later reply past the window is adopted. De-flaked: instead of a bare qWait
    //    (which could pass simply because the stale line hadn't arrived yet), we send
    //    BOTH the stale and the fresh state in ONE write so they are received and
    //    processed IN ORDER, and use a counting clock that evaluates the first inbound
    //    line in-window and the second past it. Fresh being adopted PROVES both lines
    //    were processed; exactly ONE configChanged PROVES the stale one was ignored. ──
    void suppressionWindow() {
        FakeHub hub; hub.getReply = QString(); QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);

        clockMs_ = 100000;
        b.saveUiState(QStringLiteral("{\"mine\":1}"));   // sets suppress until 101500
        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 5000);
        QCOMPARE(b.uiState(), QStringLiteral("{\"mine\":1}"));

        // Drain the initial (empty) pull reply so the counting clock below maps 1:1
        // onto exactly the two inbound lines we are about to send.
        QTest::qWait(50);

        // Counting clock: the 1st inbound uiState (stale) is evaluated in-window
        // (100000 < 101500 → IGNORED); the 2nd (fresh) is past the window (200000 →
        // ADOPTED). Both are delivered in one write, so they process in order.
        int tick = 0;
        b.setClockForTest([&tick] { return tick++ == 0 ? qint64(100000) : qint64(200000); });

        QSignalSpy spy(&b, &ManagerBackend::configChanged);
        QByteArray twoMsgs;
        twoMsgs += QJsonDocument(QJsonObject{{"type", "uiState"}, {"state", "{\"stale\":2}"}})
                       .toJson(QJsonDocument::Compact) + "\n";
        twoMsgs += QJsonDocument(QJsonObject{{"type", "uiState"}, {"state", "{\"fresh\":3}"}})
                       .toJson(QJsonDocument::Compact) + "\n";
        hub.client->write(twoMsgs);
        hub.client->flush();

        // Fresh is adopted → both lines were received & processed, in order…
        QTRY_VERIFY_WITH_TIMEOUT(b.uiState() == QStringLiteral("{\"fresh\":3}"), 5000);
        // …and the in-window stale line produced NO adoption (only fresh did).
        QCOMPARE(spy.count(), 1);
    }

    // ── #7 regression: a live edit on a CONNECTED socket must SUPERSEDE an older edit
    //    buffered while offline. Reproduce the stale-repush edit-loss window: buffer
    //    edit A offline; on reconnect the getUiState reply is HELD; slip a live edit B
    //    in; then release the reply - the reconcile must NOT re-push the stale A over
    //    the newer B. Without the fix, B is lost (final hub state reverts to A). ──
    void connectedEditSupersedesBufferedOfflineEdit() {
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        clockMs_ = 100000;
        b.saveUiState(QStringLiteral("{\"A\":1}"));   // offline → buffered pending edit

        // Bring the hub up but HOLD its getUiState reply, so we sit inside the reconnect
        // window (pull sent, not yet answered) - exactly where the heisenbug lives.
        FakeHub hub; hub.holdGet = true; hub.getReply = QString();
        QVERIFY(hub.start());
        QVERIFY(b.startHub());
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 8000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("getUiState")), 8000);
        QVERIFY(hub.getPending);   // reply is genuinely withheld → we're in the window

        // Live edit B on the CONNECTED socket must win over the buffered A.
        b.saveUiState(QStringLiteral("{\"B\":2}"));
        QTRY_VERIFY_WITH_TIMEOUT(hub.setStates.contains(QStringLiteral("{\"B\":2}")), 8000);

        // Release the held pull reply: the (now superseded) reconcile must NOT re-push A.
        hub.releaseGet();
        QTest::qWait(200);   // give any (buggy) stale re-push time to arrive

        QVERIFY(!hub.setStates.isEmpty());
        QCOMPARE(hub.setStates.last(), QStringLiteral("{\"B\":2}"));   // newer edit wins
        const int bIdx = hub.setStates.lastIndexOf(QStringLiteral("{\"B\":2}"));
        QVERIFY2(!hub.setStates.mid(bIdx + 1).contains(QStringLiteral("{\"A\":1}")),
                 "stale buffered edit A was re-pushed AFTER the newer live edit B");
    }

    // ── #1 (deep-review) regression: an offline edit made AFTER a connected edit must
    //    survive a hub restart + reconnect. A prior pull set a non-empty baseline S0;
    //    a connected push of A must update that baseline, else the reconnect reconcile
    //    sees the hub reporting our own A against the stale S0, judges it a device-side
    //    change, and DROPS the newer offline edit B. ──
    void offlineEditSurvivesReconnectAfterConnectedEdit() {
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        clockMs_ = 100000;
        {
            // hub1 reports a non-empty baseline S0 → b pulls it and records m_lastHubState.
            FakeHub hub1; hub1.getReply = QStringLiteral("{\"S0\":1}");
            QVERIFY(hub1.start());
            QVERIFY(b.startHub());
            QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 8000);
            QTRY_VERIFY_WITH_TIMEOUT(b.uiState() == QStringLiteral("{\"S0\":1}"), 8000);
            // Connected edit A - the fix records that the hub will now hold A.
            b.saveUiState(QStringLiteral("{\"A\":1}"));
            QTRY_VERIFY_WITH_TIMEOUT(hub1.setStates.contains(QStringLiteral("{\"A\":1}")), 8000);
        }  // hub1 destroyed → the socket drops → b disconnects
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 8000);

        // Offline edit B (buffered while disconnected).
        b.saveUiState(QStringLiteral("{\"B\":2}"));

        // Hub restarts persisting A (the last thing it applied). b auto-reconnects,
        // pulls A, and must KEEP + push the newer offline edit B - not drop it.
        FakeHub hub2; hub2.getReply = QStringLiteral("{\"A\":1}");
        QVERIFY(hub2.start());
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 12000);
        QTRY_VERIFY_WITH_TIMEOUT(hub2.setStates.contains(QStringLiteral("{\"B\":2}")), 12000);
        QCOMPARE(hub2.setStates.last(), QStringLiteral("{\"B\":2}"));
    }

    // ── #7 companion: DropEdit integration. After a real disconnect the hub's state
    //    CHANGED (differs from the tracked lastHubState); on reconnect the buffered
    //    offline edit is stale and must be DROPPED - no setUiState is sent. ──
    void reconnectDropsStaleEditWhenHubChanged() {
        FakeHub hub; hub.getReply = QStringLiteral("{\"OLD\":1}"); QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        clockMs_ = 100000;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        // First pull establishes the tracked baseline: lastHubState = OLD.
        QTRY_VERIFY_WITH_TIMEOUT(b.uiState() == QStringLiteral("{\"OLD\":1}"), 5000);

        // Drop the connection so the next edit buffers as an offline (pending) edit.
        hub.client->abort();
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 5000);

        // The hub CHANGED while we were offline (device-side edit): OLD → NEW.
        hub.getReply = QStringLiteral("{\"NEW\":9}");
        hub.setStates.clear();
        hub.received.clear();

        // Offline edit buffers AND triggers a reconnect (tryConnectHub in pushLive).
        b.saveUiState(QStringLiteral("{\"stale\":42}"));

        // On reconnect the pull returns NEW ≠ OLD → the stale buffered edit is DROPPED,
        // so NO setUiState is ever sent.
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("getUiState")), 8000);
        QTest::qWait(200);
        QVERIFY2(hub.setStates.isEmpty(), "stale buffered edit must be dropped, not pushed");
    }

    // ── PULL-before-PUSH: an edit made while OFFLINE is buffered, and on reconnect
    //    the hub is pulled FIRST; since the hub didn't change, our edit is (re)pushed
    //    rather than lost - and getUiState is seen before setUiState. ──
    void reconnectKeepsOfflineEdit() {
        // No server yet → the save buffers as a pending offline edit.
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        b.saveUiState(QStringLiteral("{\"offline\":42}"));

        // Bring the hub up and force a connect.
        FakeHub hub; hub.getReply = QString(); QVERIFY(hub.start());
        clockMs_ = 500000;   // well past any suppression window
        QVERIFY(b.startHub());

        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 8000);
        QCOMPARE(hub.setStates.last(), QStringLiteral("{\"offline\":42}"));
        // PULL happened before the PUSH.
        QVERIFY(hub.received.indexOf("getUiState") >= 0);
        QVERIFY(hub.received.indexOf("getUiState") < hub.received.lastIndexOf("setUiState"));
    }

    // ── Single-writer: when the hub is connected it owns config.toml. A saveUiState
    //    must push over IPC and must NOT also write the file itself (the two-writer
    //    save race is removed). We observe the socket push AND the absence of a file. ──
    void connectedSaveIsIpcOnlyNoFileWrite() {
        XeneonString cd(xeneon_config_dir());
        const QString cfg = cd.qstring() + "/config.toml";
        QFile::remove(cfg);                       // start from a known no-file state

        FakeHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        b.saveUiState(QStringLiteral("{\"connected\":9}"));
        // Pushed over the socket…
        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 5000);
        QCOMPARE(hub.setStates.last(), QStringLiteral("{\"connected\":9}"));
        // …and the in-memory copy reflects the edit…
        QCOMPARE(b.uiState(), QStringLiteral("{\"connected\":9}"));
        // …but the Manager did NOT persist config.toml itself (hub is the writer).
        QVERIFY(!QFile::exists(cfg));
    }

    // ── B5 REGRESSION (two-writer race): with a hub CONNECTED, a Manager
    //    setTargetDisplay must survive the hub's next save.
    //    Pre-fix the Manager wrote config.toml itself while the hub's in-memory config
    //    still held the old target, so the hub's next save (clean exit / SIGTERM)
    //    silently REVERTED the user's choice. The fix routes the change through the
    //    hub, which adopts it into its LIVE config - so its own save re-writes the NEW
    //    value. ──
    void targetDisplaySurvivesHubSave() {
        XeneonString cd(xeneon_config_dir());
        const QString cfgPath = cd.qstring() + "/config.toml";
        QFile::remove(cfgPath);

        HubEmu hub;                          // in-memory config: no target set
        QVERIFY(hub.srv.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.setTargetDisplay(QStringLiteral("DP-9"), QStringLiteral("XENEON EDGE 45")));

        // The HUB adopted the change into its LIVE config…
        XeneonString hc(xeneon_config_get_target_connector(hub.cfg));
        XeneonString hm(xeneon_config_get_target_model(hub.cfg));
        QCOMPARE(hc.qstring(), QStringLiteral("DP-9"));
        QCOMPARE(hm.qstring(), QStringLiteral("XENEON EDGE 45"));

        // …so the hub's next save cannot clobber it.
        hub.save();

        ConfigHandle* onDisk = xeneon_config_load();
        QVERIFY(onDisk);
        XeneonString dc(xeneon_config_get_target_connector(onDisk));
        XeneonString dm(xeneon_config_get_target_model(onDisk));
        xeneon_config_free(onDisk);
        QCOMPARE(dc.qstring(), QStringLiteral("DP-9"));
        QCOMPARE(dm.qstring(), QStringLiteral("XENEON EDGE 45"));
    }

    // ── B5 REGRESSION: the same for autostart - the flag survives the hub's next
    //    save, the HUB (not the Manager) writes the XDG entry, and the Manager's
    //    immediate isAutostart() readback (which the QML Switch does on the very next
    //    line) already sees it because the setter waits for the hub's ack. ──
    void autostartSurvivesHubSave() {
        XeneonString cd(xeneon_config_dir());
        const QString cfgPath = cd.qstring() + "/config.toml";
        // ConfigLocation, matching applyAutostart(): homePath() was the sandbox-escape
        // bug - see tst_autostart::entryFollowsXdgNotHome.
        const QString entry = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                              + "/autostart/xeneon-edge-hub.desktop";
        QFile::remove(cfgPath);
        QFile::remove(entry);

        HubEmu hub;
        QVERIFY(hub.srv.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.setAutostart(true));
        QVERIFY(QFile::exists(entry));   // hub wrote the entry BEFORE acking…
        QVERIFY(b.isAutostart());        // …so the readback is honest, not racy.

        hub.save();
        ConfigHandle* onDisk = xeneon_config_load();
        QVERIFY(onDisk);
        XeneonString js(xeneon_config_to_json(onDisk));
        xeneon_config_free(onDisk);
        const QJsonObject o = QJsonDocument::fromJson(js.qstring().toUtf8()).object();
        QCOMPARE(o.value("startup").toObject().value("autostart").toBool(), true);

        // …and off again, through the same path.
        QVERIFY(b.setAutostart(false));
        QVERIFY(!QFile::exists(entry));
        QVERIFY(!b.isAutostart());
    }

    // ── An honest error ack must surface as false + saveError, never an optimistic
    //    true (the user would think the target was saved when it wasn't). ──
    void rejectedSetterReportsFailure() {
        HubEmu hub; hub.failApply = true;
        QVERIFY(hub.srv.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QSignalSpy spy(&b, &ManagerBackend::saveError);
        QVERIFY(!b.setTargetDisplay(QStringLiteral("DP-1"), QStringLiteral("M")));
        QCOMPARE(spy.count(), 1);
        QVERIFY(!b.setAutostart(true));
        QCOMPARE(spy.count(), 2);
    }

    // ── A hub that accepts the connection but never acks must not hang the Manager:
    //    the bounded wait expires and the setter reports an honest false. FakeHub
    //    ignores the per-field setters entirely, which is exactly that case. ──
    void unackedSetterTimesOutHonestly() {
        FakeHub hub; hub.getReply = QString(); QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QElapsedTimer t; t.start();
        QVERIFY(!b.setTargetDisplay(QStringLiteral("DP-1"), QStringLiteral("M")));
        QVERIFY2(t.elapsed() < 5000, "waitForAck must be bounded");
        QVERIFY(hub.received.contains(QStringLiteral("setTargetDisplay")));
    }

    // ── Offline: with no hub reachable, the Manager is the sole writer and persists
    //    the edit directly so offline editing is preserved. ──
    void disconnectedSaveWritesFile() {
        XeneonString cd(xeneon_config_dir());
        const QString cfg = cd.qstring() + "/config.toml";
        QFile::remove(cfg);

        ManagerBackend b;                          // no FakeHub → stays disconnected
        b.setClockForTest([this] { return clockMs_; });
        QVERIFY(!b.hubConnected());

        QVERIFY(b.saveUiState(QStringLiteral("{\"offline\":5}")));
        QVERIFY(QFile::exists(cfg));               // sole writer persisted directly
    }
};

QTEST_MAIN(TstManagerBackendSync)
#include "tst_manager_backend_sync.moc"
