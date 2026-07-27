// Integration tests for ManagerBackend: live two-way sync with a fake hub over a
// REAL QLocalSocket, PULL-before-PUSH reconnect reconciliation, the post-push
// suppression window (driven by an INJECTED clock so there is zero real waiting),
// and the image import/delete/sanitize surface. Needs a QGuiApplication (offscreen).
#include <QtTest>
#include <QStandardPaths>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
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

static int runDetachedAppImageHub(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    QLocalServer server;
    QLocalServer::removeServer(kSock());
    if (!server.listen(kSock()))
        return 2;
    QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
        while (server.hasPendingConnections()) {
            QLocalSocket* socket = server.nextPendingConnection();
            QObject::connect(socket, &QLocalSocket::readyRead, socket,
                             [socket, &app] {
                const QList<QByteArray> lines = socket->readAll().split('\n');
                for (const QByteArray& line : lines) {
                    if (line.trimmed().isEmpty())
                        continue;
                    const QJsonObject request =
                        QJsonDocument::fromJson(line).object();
                    const QString type = request.value("type").toString();
                    QJsonObject response;
                    if (type == QStringLiteral("getUiState")) {
                        response = {{"type", "uiState"}, {"state", ""}};
                    } else if (type == QStringLiteral("ping")) {
                        response = {{"type", "pong"}};
                    } else if (type == QStringLiteral("shutdown")) {
                        response = {{"type", "ok"}, {"for", "shutdown"}};
                        QTimer::singleShot(0, &app, &QCoreApplication::quit);
                    } else {
                        response = {{"type", "error"}};
                    }
                    socket->write(
                        QJsonDocument(response).toJson(QJsonDocument::Compact)
                        + '\n');
                    socket->flush();
                }
            });
            QObject::connect(socket, &QLocalSocket::disconnected,
                             socket, &QObject::deleteLater);
        }
    });
    QTimer::singleShot(30000, &app, &QCoreApplication::quit);
    return app.exec();
}

static QString testState(const char* key, int value) {
    return QString::fromUtf8(
        QJsonDocument(QJsonObject{
                          {"version", 1},
                          {"appearance", QJsonObject{}},
                          {"pages", QJsonArray{}},
                          {"settings", QJsonObject{}},
                          {"test", QJsonObject{{QString::fromLatin1(key), value}}},
                      })
            .toJson(QJsonDocument::Compact));
}

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
                [this](const QString& c, const QString& m, bool* ok,
                       bool* durabilityUncertain) {
                    if (durabilityUncertain) *durabilityUncertain = false;
                    if (failApply) { if (ok) *ok = false; return; }
                    xeneon_config_set_target_edid_hash(cfg, nullptr);
                    xeneon_config_set_target_connector(cfg, c.toUtf8().constData());
                    xeneon_config_set_target_model(cfg, m.toUtf8().constData());
                    if (ok) *ok = xeneon_config_save(cfg) >= 0;
                }, Qt::DirectConnection);
        connect(&srv, &ControlServer::autostartReceived, this,
                [this](bool enabled, bool* ok, bool* durabilityUncertain) {
                    if (durabilityUncertain) *durabilityUncertain = false;
                    if (failApply) { if (ok) *ok = false; return; }
                    xeneon_config_set_autostart(cfg, enabled ? 1 : 0);
                    const bool fileOk = applyAutostart(enabled);
                    if (ok) *ok = fileOk && xeneon_config_save(cfg) >= 0;
                }, Qt::DirectConnection);
        connect(&srv, &ControlServer::licenseKeyReceived, this,
                [this](const QString& key, bool* ok) {
                    if (failApply) { if (ok) *ok = false; return; }
                    const QByteArray bytes = key.toUtf8();
                    xeneon_config_set_license_key(
                        cfg, key.isEmpty() ? nullptr : bytes.constData());
                    if (ok) *ok = xeneon_config_save(cfg) >= 0;
                }, Qt::DirectConnection);
    }
    ~HubEmu() override { if (cfg) xeneon_config_free(cfg); }

    // What the real hub does on clean exit / SIGTERM (app/src/main.cpp): persist its
    // in-memory config. THIS is the write that used to revert the Manager's edit.
    void save() { QVERIFY(xeneon_config_save(cfg) >= 0); }
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
    QString getGenerationToken;       // optional current-Hub generation token
    QStringList received;             // request types, in order
    QStringList setStates;            // states received via setUiState
    QStringList setRequestIds;        // matching request ids for those states
    QList<int> activePages;           // page payloads received via setActivePage
    bool holdGet = false;             // when true, DON'T auto-reply to getUiState…
    bool getPending = false;          // …record that one is owed, release it later
    bool holdSetAcks = false;         // allow out-of-order/stale ack regression tests
    bool setAckLiveApplied = true;
    bool ackFieldSetters = false;
    bool setterDurabilityUncertain = false;

    bool start() {
        QLocalServer::removeServer(kSock());
        connect(&server, &QLocalServer::newConnection, this, [this] {
            client = server.nextPendingConnection();
            connect(client, &QLocalSocket::readyRead, this, &FakeHub::onRx);
        });
        return server.listen(kSock());
    }
    void sendUiState(
        const QString& state,
        int rotation = -1000,
        int stateLive = -1,
        int currentPage = -1000,
        const QString& generationToken = QString()) {
        if (!client) return;
        QJsonObject reply{{"type", "uiState"}, {"state", state}};
        if (rotation != -1000)
            reply.insert(QStringLiteral("rotation"), rotation);
        if (stateLive >= 0)
            reply.insert(QStringLiteral("stateLive"), stateLive != 0);
        if (currentPage != -1000)
            reply.insert(QStringLiteral("currentPage"), currentPage);
        if (!generationToken.isEmpty()) {
            reply.insert(
                QStringLiteral("configGenerationToken"),
                generationToken);
        }
        client->write(QJsonDocument(reply).toJson(QJsonDocument::Compact));
        client->write("\n");
        client->flush();
    }
    void sendAck(
        bool ok,
        const QString& forType,
        const QString& message = QString(),
        const QString& requestId = QString(),
        int liveApplied = -1,
        int durabilityUncertain = -1) {
        if (!client) return;
        QJsonObject reply{{"type", ok ? "ok" : "error"}, {"for", forType}};
        if (!ok) reply.insert(QStringLiteral("message"), message);
        if (!requestId.isEmpty())
            reply.insert(QStringLiteral("requestId"), requestId);
        if (liveApplied >= 0)
            reply.insert(QStringLiteral("liveApplied"), liveApplied != 0);
        if (durabilityUncertain >= 0) {
            reply.insert(
                QStringLiteral("durabilityUncertain"),
                durabilityUncertain != 0);
        }
        client->write(QJsonDocument(reply).toJson(QJsonDocument::Compact));
        client->write("\n");
        client->flush();
    }
    // Release a getUiState reply that was withheld while holdGet was set.
    void releaseGet() {
        if (getPending) {
            getPending = false;
            sendUiState(
                getReply, -1000, -1, -1000, getGenerationToken);
        }
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
                else {
                    sendUiState(
                        getReply, -1000, -1, -1000,
                        getGenerationToken);
                }
            } else if (type == "setUiState") {
                setStates << o.value("state").toString();
                const QString requestId = o.value("requestId").toString();
                setRequestIds << requestId;
                if (!holdSetAcks)
                    sendAck(
                        true,
                        QStringLiteral("setUiState"),
                        QString(),
                        requestId,
                        setAckLiveApplied);
            } else if (type == "setActivePage") {
                activePages << o.value("page").toInt(-1);
            } else if (ackFieldSetters
                       && (type == QStringLiteral("setTargetDisplay")
                           || type == QStringLiteral("setAutostart"))) {
                sendAck(
                    true,
                    type,
                    QString(),
                    o.value(QStringLiteral("requestId")).toString(),
                    -1,
                    setterDurabilityUncertain ? 1 : 0);
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

        b.saveUiState(testState("pushed", 1));
        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 5000);
        QCOMPARE(hub.setStates.last(), testState("pushed", 1));

        b.setHubActivePage(3);
        QTRY_VERIFY_WITH_TIMEOUT(!hub.activePages.isEmpty(), 5000);
        QCOMPARE(hub.activePages.last(), 3);

        // startHub is a no-op success when a hub is already connected (no 2nd instance).
        QVERIFY(b.startHub());
        // stopHub over a connected socket asks the hub to quit (shutdown message).
        QVERIFY(b.stopHub());
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("shutdown")), 5000);
    }

    void staleUiStateAckCannotConfirmANewerRapidEdit() {
        FakeHub hub;
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.saveUiState(testState("first", 1)));
        QVERIFY(b.saveUiState(testState("latest", 2)));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setStates.size(), 2, 5000);
        QCOMPARE(hub.setRequestIds.size(), 2);
        QVERIFY(!hub.setRequestIds[0].isEmpty());
        QVERIFY(hub.setRequestIds[0] != hub.setRequestIds[1]);
        QVERIFY(b.hasPendingUiStateForTest());

        // The first write may persist after the second was already queued. Its
        // ack must not clear the newer pending state.
        hub.sendAck(true, QStringLiteral("setUiState"), QString(),
                    hub.setRequestIds[0]);
        QTest::qWait(50);
        QVERIFY(b.hasPendingUiStateForTest());
        QCOMPARE(b.uiState(), testState("latest", 2));

        hub.sendAck(true, QStringLiteral("setUiState"), QString(),
                    hub.setRequestIds[1]);
        QTRY_VERIFY_WITH_TIMEOUT(!b.hasPendingUiStateForTest(), 5000);
        QVERIFY(b.confirmShutdownUiStatePersisted());
    }

    void everyUiStateAckRetiresItsInFlightSlot() {
        FakeHub hub;
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.saveUiState(testState("first", 1)));
        QVERIFY(b.saveUiState(testState("second", 2)));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setRequestIds.size(), 2, 5000);

        // Exercise defensive out-of-order delivery: the newest tagged ack can
        // clear the pending edit, but the older tagged ack must still retire
        // its accounting slot.
        hub.sendAck(true, QStringLiteral("setUiState"), QString(),
                    hub.setRequestIds[1]);
        QTRY_VERIFY_WITH_TIMEOUT(!b.hasPendingUiStateForTest(), 5000);
        hub.sendAck(true, QStringLiteral("setUiState"), QString(),
                    hub.setRequestIds[0]);
        QTest::qWait(50);

        // An older Hub does not echo requestId. With no leaked slot, this sole
        // untagged reply is unambiguous and confirms the new edit.
        QVERIFY(b.saveUiState(testState("legacy-peer", 3)));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setRequestIds.size(), 3, 5000);
        hub.sendAck(true, QStringLiteral("setUiState"));
        QTRY_VERIFY_WITH_TIMEOUT(!b.hasPendingUiStateForTest(), 5000);
    }

    void cleanShutdownWaitsForTheHubPersistenceAck() {
        FakeHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.saveUiState(testState("shutdown", 1)));
        QVERIFY(b.confirmShutdownUiStatePersisted());
        QCOMPARE(hub.setStates.last(), testState("shutdown", 1));
    }

    void rejectedShutdownSaveExportsExactRecoveryDocument() {
        FakeHub hub;
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        const QString state = testState("shutdown-rejected", 1);
        QVERIFY(b.saveUiState(state));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setRequestIds.size(), 1, 5000);
        hub.sendAck(
            false,
            QStringLiteral("setUiState"),
            QStringLiteral("forced rejection"),
            hub.setRequestIds.first());
        QTRY_VERIFY_WITH_TIMEOUT(b.hasPendingUiStateForTest(), 5000);
        QVERIFY(!b.confirmShutdownUiStatePersisted());

        const QString recovery = b.exportPendingUiStateRecovery();
        QVERIFY2(!recovery.isEmpty(), "rejected save must have a recovery path");
        QFile file(recovery);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(QString::fromUtf8(file.readAll()), state);
        const QFileDevice::Permissions permissions =
            QFileInfo(recovery).permissions();
        QVERIFY(permissions.testFlag(QFileDevice::ReadOwner));
        QVERIFY(permissions.testFlag(QFileDevice::WriteOwner));
        QVERIFY(!(permissions
                  & (QFileDevice::ReadGroup
                     | QFileDevice::WriteGroup
                     | QFileDevice::ExeGroup
                     | QFileDevice::ReadOther
                     | QFileDevice::WriteOther
                     | QFileDevice::ExeOther)));
    }

    void timedOutShutdownSaveExportsExactRecoveryDocument() {
        FakeHub hub;
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        const QString state = testState("shutdown-timeout", 1);
        QVERIFY(b.saveUiState(state));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setRequestIds.size(), 1, 5000);
        QVERIFY(!b.confirmShutdownUiStatePersisted());

        const QString recovery = b.exportPendingUiStateRecovery();
        QVERIFY2(!recovery.isEmpty(), "timed-out save must have a recovery path");
        QFile file(recovery);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(QString::fromUtf8(file.readAll()), state);
    }

    void disconnectedShutdownSaveExportsExactRecoveryDocument() {
        FakeHub hub;
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        const QString state = testState("shutdown-disconnected", 1);
        QVERIFY(b.saveUiState(state));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setRequestIds.size(), 1, 5000);
        QVERIFY(hub.client);
        hub.client->abort();
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 5000);
        QVERIFY(!b.confirmShutdownUiStatePersisted());

        const QString recovery = b.exportPendingUiStateRecovery();
        QVERIFY2(!recovery.isEmpty(), "disconnected save must have a recovery path");
        QFile file(recovery);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(QString::fromUtf8(file.readAll()), state);
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
        b.saveUiState(testState("k", 1));            // offline persist
        QCOMPARE(b.uiState(), testState("k", 1));
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
            "{\"version\":1,\"pages\":[{\"name\":\"MANAGER_PRIVATE_PAGE_CANARY\","
            "\"tiles\":[{\"id\":\"meds-1\",\"type\":\"meds\"}]}],\"settings\":{"
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
        QVERIFY(b.saveUiState(testState("empty", 0)));
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

    void managerUsesTheHubPolicySecretAndMetricContracts() {
        struct PolicyEnvReset {
            ~PolicyEnvReset() { qunsetenv("XENEON_POLICY_PATH"); }
        } resetPolicyEnv;
        QTemporaryDir fixture;
        QVERIFY(fixture.isValid());

        const QString policyPath = fixture.filePath(QStringLiteral("policy.toml"));
        QFile policy(policyPath);
        QVERIFY(policy.open(QIODevice::WriteOnly));
        QCOMPARE(
            policy.write(
                "policy_version = 1\n"
                "net_offline = false\n"
                "allowed_hosts = [\"internal.example.com\"]\n"),
            qint64(80));
        policy.close();
        qputenv("XENEON_POLICY_PATH", policyPath.toUtf8());

        ManagerBackend backend;
        const QVariantMap first = backend.policy();
        QCOMPARE(first.value(QStringLiteral("active")).toBool(), true);
        QCOMPARE(first.value(QStringLiteral("source")).toString(),
                 QStringLiteral("policy"));
        QCOMPARE(
            first.value(QStringLiteral("allowedHosts")).toList().at(0).toString(),
            QStringLiteral("internal.example.com"));

        QVERIFY(policy.open(QIODevice::WriteOnly | QIODevice::Truncate));
        policy.write("policy_version = 1\nnet_offline = true\n");
        policy.close();
        QCOMPARE(
            backend.policy().value(QStringLiteral("netOffline")).toBool(),
            false);

        const QString secretPath = fixture.filePath(QStringLiteral("token"));
        QFile secret(secretPath);
        QVERIFY(secret.open(QIODevice::WriteOnly));
        QCOMPARE(secret.write("manager-secret\n"), qint64(15));
        secret.close();
        QVERIFY(QFile::setPermissions(
            secretPath, QFileDevice::ReadOwner | QFileDevice::WriteOwner));
        const QVariantMap resolved =
            backend.resolveSecret(QStringLiteral("file:") + secretPath);
        QCOMPARE(resolved.value(QStringLiteral("ok")).toBool(), true);
        QCOMPARE(resolved.value(QStringLiteral("value")).toString(),
                 QStringLiteral("manager-secret"));

        const QVariantMap local = backend.readMetricFile(secretPath);
        QCOMPARE(local.value(QStringLiteral("ok")).toBool(), false);
        QCOMPARE(local.value(QStringLiteral("error")).toString(),
                 QStringLiteral("outside-approved-roots"));
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

    void appImageStartHubOutlivesManagerProcess() {
        QLocalServer::removeServer(kSock());
        XeneonString configDirectory(xeneon_config_dir());
        QFile::remove(configDirectory.qstring() + QStringLiteral("/config.toml"));
        const bool hadAppImage = qEnvironmentVariableIsSet("APPIMAGE");
        const QByteArray previousAppImage = qgetenv("APPIMAGE");
        qputenv("APPIMAGE", QCoreApplication::applicationFilePath().toUtf8());

        bool launched = false;
        {
            ManagerBackend backend;
            launched = backend.startHub();
            QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(kSock()), 5000);
        }

        QLocalSocket probe;
        probe.connectToServer(kSock());
        const bool connected = probe.waitForConnected(3000);
        if (connected) {
            probe.write("{\"type\":\"ping\"}\n");
            probe.flush();
        }
        const bool readable = connected && probe.waitForReadyRead(3000);
        const QJsonObject reply = readable
            ? QJsonDocument::fromJson(probe.readLine()).object()
            : QJsonObject{};
        bool shutdownWritten = false;
        bool shutdownReadable = false;
        QJsonObject shutdownReply;
        if (connected) {
            const QByteArray request = QByteArrayLiteral(
                "{\"type\":\"shutdown\"}\n");
            const qint64 queued = probe.write(request);
            probe.flush();
            shutdownWritten =
                queued == request.size()
                && (probe.bytesToWrite() == 0
                    || probe.waitForBytesWritten(1000));
            shutdownReadable =
                probe.canReadLine()
                || probe.waitForReadyRead(3000)
                || probe.canReadLine();
            if (shutdownReadable)
                shutdownReply =
                    QJsonDocument::fromJson(probe.readLine()).object();
            if (probe.state() != QLocalSocket::UnconnectedState) {
                probe.disconnectFromServer();
                if (probe.state() != QLocalSocket::UnconnectedState)
                    probe.waitForDisconnected(3000);
            }
        }
        if (hadAppImage)
            qputenv("APPIMAGE", previousAppImage);
        else
            qunsetenv("APPIMAGE");

        QVERIFY(launched);
        QVERIFY2(connected, "detached AppImage Hub disappeared with ManagerBackend");
        QVERIFY(readable);
        QCOMPARE(reply.value("type").toString(), QStringLiteral("pong"));
        QVERIFY2(
            shutdownWritten,
            "detached AppImage Hub shutdown request was not fully written");
        QVERIFY2(
            shutdownReadable,
            "detached AppImage Hub did not acknowledge clean shutdown");
        QCOMPARE(
            shutdownReply.value(QStringLiteral("type")).toString(),
            QStringLiteral("ok"));
        QCOMPARE(
            shutdownReply.value(QStringLiteral("for")).toString(),
            QStringLiteral("shutdown"));
        // Do not let the next test rebind this path until the detached helper's
        // QLocalServer has finished teardown. Otherwise the exiting helper can
        // unlink the next FakeHub's newly created socket.
        QTRY_VERIFY_WITH_TIMEOUT(!QFileInfo::exists(kSock()), 5000);
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
        hub.sendUiState(testState("fromhub", 7), 90);
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 5000);
        QCOMPARE(b.uiState(), testState("fromhub", 7));
        QCOMPARE(b.hubRotation(), 90);
        QCOMPARE(rotations.count(), 1);

        // Repeating the same orientation must not churn the preview binding.
        hub.sendUiState(testState("fromhub", 8), 90);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), testState("fromhub", 8), 5000);
        QCOMPARE(rotations.count(), 1);
    }

    void hubCurrentPageTracksPanelWithoutSignalChurn() {
        FakeHub hub;
        hub.getReply = testState("page-sync", 1);
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        QSignalSpy pages(&b, &ManagerBackend::hubCurrentPageChanged);

        hub.sendUiState(hub.getReply, -1000, -1, 2);
        QTRY_COMPARE_WITH_TIMEOUT(b.hubCurrentPage(), 2, 5000);
        QCOMPARE(pages.count(), 1);

        hub.sendUiState(hub.getReply, -1000, -1, 2);
        QTest::qWait(50);
        QCOMPARE(pages.count(), 1);

        hub.sendUiState(hub.getReply, -1000, -1, 0);
        QTRY_COMPARE_WITH_TIMEOUT(b.hubCurrentPage(), 0, 5000);
        QCOMPARE(pages.count(), 2);
    }

    void queuedAndLivePanelStateRemainDistinct() {
        FakeHub hub;
        hub.getReply = testState("baseline", 1);
        hub.setAckLiveApplied = false;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), testState("baseline", 1), 5000);

        QSignalSpy liveChanges(&b, &ManagerBackend::layoutLiveAppliedChanged);
        hub.sendUiState(testState("baseline", 1), -1000, 0);
        QTRY_VERIFY_WITH_TIMEOUT(!b.layoutLiveApplied(), 5000);

        const QString queued = testState("queued", 2);
        QVERIFY(b.saveUiState(queued));
        QTRY_VERIFY_WITH_TIMEOUT(hub.setStates.contains(queued), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(!b.hasPendingUiStateForTest(), 5000);
        QVERIFY(!b.layoutLiveApplied());

        hub.getReply = queued;
        hub.sendUiState(queued, -1000, 1);
        QTRY_VERIFY_WITH_TIMEOUT(b.layoutLiveApplied(), 5000);
        QVERIFY(liveChanges.count() >= 2);
    }

    void hubChangeDuringLocalDebounceRequiresExplicitKeepOrDiscard() {
        FakeHub hub;
        hub.getReply = testState("baseline", 1);
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), testState("baseline", 1), 5000);

        const QString localEdit = testState("manager-local", 2);
        const QString hubEdit = testState("hub-local", 3);
        b.setLayoutSavePending(true);
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy layoutErrors(&b, &ManagerBackend::layoutSaveError);
        hub.sendUiState(hubEdit);
        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 5000);
        QVERIFY2(
            b.uiState() == testState("baseline", 1),
            "a Hub pull must not replace the locally edited Manager model");

        b.setLayoutSavePending(false);
        QVERIFY(!b.saveUiState(localEdit));
        QCOMPARE(layoutErrors.count(), 1);
        QVERIFY(hub.setStates.isEmpty());

        // Retry is the explicit keep-local decision. Only after that decision
        // may this exact local document be pushed over the Hub version.
        QVERIFY(b.preparePendingLayoutRetry());
        QVERIFY(b.saveUiState(localEdit));
        QTRY_VERIFY_WITH_TIMEOUT(hub.setStates.contains(localEdit), 5000);
    }

    void hubChangeDuringLocalDebounceCanBeDiscarded() {
        FakeHub hub;
        hub.getReply = testState("baseline", 1);
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), testState("baseline", 1), 5000);

        const QString hubEdit = testState("hub-local", 4);
        b.setLayoutSavePending(true);
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);
        hub.sendUiState(hubEdit);
        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 5000);

        hub.getReply = hubEdit;
        b.discardPendingLayoutAndSync();
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), hubEdit, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(layoutChanges.count(), 1, 5000);
        QVERIFY(hub.setStates.isEmpty());
    }

    void hubChangeDuringWidgetLocalDebounceRequiresExplicitDiscard() {
        FakeHub hub;
        const QString baseline = testState("widget-baseline", 1);
        const QString hubEdit = testState("widget-hub-edit", 2);
        hub.getReply = baseline;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), baseline, 5000);

        bool widgetPending = true;
        b.setLocalUiStatePendingProbe([&widgetPending] {
            return widgetPending;
        });
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);
        hub.getReply = hubEdit;
        hub.sendUiState(hubEdit);
        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 5000);
        QCOMPARE(layoutChanges.count(), 0);
        QCOMPARE(b.uiState(), baseline);

        b.discardPendingLayoutAndSync();
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), hubEdit, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(layoutChanges.count(), 1, 5000);
        QVERIFY2(widgetPending,
                 "Discard must bypass, not mutate, the QML pending-state probe");
        QVERIFY(hub.setStates.isEmpty());
    }

    void disconnectCannotImplicitlyDiscardADebounceConflict() {
        XeneonString directory(xeneon_config_dir());
        const QString configPath =
            directory.qstring() + QStringLiteral("/config.toml");
        QFile::remove(configPath);
        const QString baseline = testState("baseline", 1);
        const QString hubEdit = testState("hub-local", 5);

        ConfigHandle* seed = xeneon_config_load();
        QVERIFY(seed);
        QCOMPARE(
            xeneon_config_set_ui_state(seed, baseline.toUtf8().constData()), 0);
        QVERIFY(xeneon_config_save(seed) >= 0);
        xeneon_config_free(seed);

        FakeHub hub;
        hub.getReply = baseline;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), baseline, 5000);

        ConfigHandle* hubConfig = xeneon_config_load();
        QVERIFY(hubConfig);
        QCOMPARE(
            xeneon_config_set_ui_state(
                hubConfig, hubEdit.toUtf8().constData()),
            0);
        QVERIFY(xeneon_config_save(hubConfig) >= 0);
        xeneon_config_free(hubConfig);
        hub.getReply = hubEdit;

        b.setLayoutSavePending(true);
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);
        hub.sendUiState(hubEdit);
        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 5000);
        QCOMPARE(b.uiState(), baseline);

        hub.client->abort();
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 5000);
        QTest::qWait(100);
        QCOMPARE(layoutChanges.count(), 0);
        QCOMPARE(b.uiState(), baseline);

        // Discard is the first operation allowed to adopt the Hub's disk state.
        b.setLayoutSavePending(false);
        b.discardLocalAndReload();
        QTRY_COMPARE_WITH_TIMEOUT(layoutChanges.count(), 1, 5000);
        QCOMPARE(b.uiState(), hubEdit);
    }

    void offlineAtomicReplacementCannotDiscardPendingLocalEdit() {
        XeneonString directory(xeneon_config_dir());
        const QString configPath =
            directory.qstring() + QStringLiteral("/config.toml");
        QFile::remove(configPath);
        const QString baseline = testState("offline-baseline", 1);
        const QString external = testState("offline-external", 2);

        ConfigHandle* seed = xeneon_config_load();
        QVERIFY(seed);
        QCOMPARE(
            xeneon_config_set_ui_state(seed, baseline.toUtf8().constData()), 0);
        QVERIFY(xeneon_config_save(seed) >= 0);
        xeneon_config_free(seed);

        ManagerBackend b;
        QCOMPARE(b.uiState(), baseline);
        b.setLayoutSavePending(true);
        int preflightCalls = 0;
        b.setOfflineExternalChangePreflight([&preflightCalls] {
            ++preflightCalls;
            return false;
        });
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);

        ConfigHandle* writer = xeneon_config_load();
        QVERIFY(writer);
        QCOMPARE(
            xeneon_config_set_ui_state(
                writer, external.toUtf8().constData()),
            0);
        QVERIFY(xeneon_config_save(writer) >= 0);
        xeneon_config_free(writer);

        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 5000);
        QVERIFY(preflightCalls >= 1);
        QCOMPARE(layoutChanges.count(), 0);
        QCOMPARE(b.uiState(), baseline);

        // The external document is adopted only after an explicit Discard.
        b.setLayoutSavePending(false);
        b.discardLocalAndReload();
        QTRY_COMPARE_WITH_TIMEOUT(layoutChanges.count(), 1, 5000);
        QCOMPARE(b.uiState(), external);
    }

    void hubOwnedFieldsRefreshWithoutDisconnectOrLayoutReload() {
        XeneonString directory(xeneon_config_dir());
        const QString configPath =
            directory.qstring() + QStringLiteral("/config.toml");
        QFile::remove(configPath);
        const QString state = testState("stable-layout", 1);

        ConfigHandle* seed = xeneon_config_load();
        QVERIFY(seed);
        QCOMPARE(
            xeneon_config_set_ui_state(seed, state.toUtf8().constData()), 0);
        QVERIFY(xeneon_config_save(seed) >= 0);
        xeneon_config_free(seed);

        FakeHub hub;
        hub.getReply = state;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), state, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(
            b.configDiskGenerationProbeCountForTest() > 0, 5000);

        QSignalSpy fieldChanges(&b, &ManagerBackend::hubConfigChanged);
        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);
        ConfigHandle* hubConfig = xeneon_config_load();
        QVERIFY(hubConfig);
        QCOMPARE(
            xeneon_config_set_target_connector(hubConfig, "DP-WIZARD"), 0);
        QCOMPARE(
            xeneon_config_set_target_model(hubConfig, "Configured by wizard"), 0);
        QCOMPARE(
            xeneon_config_set_starter_layout(hubConfig, "developer"), 0);
        QVERIFY(xeneon_config_save(hubConfig) >= 0);
        xeneon_config_free(hubConfig);

        // The Manager remains connected. An authoritative Hub state receipt
        // refreshes the other Hub-owned fields without reloading DashboardStore.
        hub.sendUiState(state);
        QTRY_COMPARE_WITH_TIMEOUT(fieldChanges.count(), 1, 5000);
        QCOMPARE(layoutChanges.count(), 0);
        QCOMPARE(b.targetConnector(), QStringLiteral("DP-WIZARD"));
        QCOMPARE(b.targetModel(), QStringLiteral("Configured by wizard"));
        QCOMPARE(b.starterLayout(), QStringLiteral("developer"));
        QVERIFY(b.hubConnected());
    }

    void currentHubTokenSkipsUnchangedPeriodicDiskGenerationProbes() {
        XeneonString directory(xeneon_config_dir());
        const QString configPath =
            directory.qstring() + QStringLiteral("/config.toml");
        QFile::remove(configPath);
        const QString state = testState("token-stable-layout", 1);

        ConfigHandle* seed = xeneon_config_load();
        QVERIFY(seed);
        QCOMPARE(
            xeneon_config_set_ui_state(seed, state.toUtf8().constData()), 0);
        QCOMPARE(
            xeneon_config_set_target_connector(seed, "DP-BASELINE"), 0);
        QVERIFY(xeneon_config_save(seed) >= 0);
        xeneon_config_free(seed);

        FakeHub hub;
        hub.getReply = state;
        hub.getGenerationToken = QStringLiteral("hub-generation-1");
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(
            b.targetConnector(), QStringLiteral("DP-BASELINE"), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(
            b.lastHubConfigGenerationTokenForTest(),
            hub.getGenerationToken,
            5000);
        QCOMPARE(b.configDiskGenerationProbeCountForTest(), 0);

        // Simulate bytes changing behind the live Hub. The Hub's unchanged
        // in-memory token remains authoritative, so repeated 500 ms pulls must
        // neither inspect the disk generation nor adopt those bytes.
        ConfigHandle* external = xeneon_config_load();
        QVERIFY(external);
        QCOMPARE(
            xeneon_config_set_target_connector(external, "DP-CHANGED"), 0);
        QVERIFY(xeneon_config_save(external) >= 0);
        xeneon_config_free(external);
        QTest::qWait(650);
        QCOMPARE(b.configDiskGenerationProbeCountForTest(), 0);
        QCOMPARE(b.targetConnector(), QStringLiteral("DP-BASELINE"));

        // Once the Hub advertises a new token, the Manager takes one fresh
        // snapshot and exposes the changed Hub-owned fields.
        QSignalSpy fieldChanges(&b, &ManagerBackend::hubConfigChanged);
        hub.getGenerationToken = QStringLiteral("hub-generation-2");
        hub.sendUiState(
            state, -1000, -1, -1000, hub.getGenerationToken);
        QTRY_COMPARE_WITH_TIMEOUT(
            b.targetConnector(), QStringLiteral("DP-CHANGED"), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(fieldChanges.count(), 1, 5000);
        QCOMPARE(b.configDiskGenerationProbeCountForTest(), 0);

        // Autostart is a Hub-owned field too. It previously fell outside the
        // before/after signature, so a token-aware reload could silently leave
        // the Manager switch stale until the window regained focus.
        ConfigHandle* autostartOnly = xeneon_config_load();
        QVERIFY(autostartOnly);
        QCOMPARE(xeneon_config_set_autostart(autostartOnly, 1), 0);
        QVERIFY(xeneon_config_save(autostartOnly) >= 0);
        xeneon_config_free(autostartOnly);
        hub.getGenerationToken = QStringLiteral("hub-generation-3");
        hub.sendUiState(
            state, -1000, -1, -1000, hub.getGenerationToken);
        QTRY_COMPARE_WITH_TIMEOUT(fieldChanges.count(), 2, 5000);
        QCOMPARE(b.configDiskGenerationProbeCountForTest(), 0);
    }

    void hubDiskLayoutChangeEmitsExactlyOneLiveReload() {
        XeneonString directory(xeneon_config_dir());
        const QString configPath =
            directory.qstring() + QStringLiteral("/config.toml");
        QFile::remove(configPath);
        const QString before = testState("before", 1);
        const QString after = testState("after", 2);

        ConfigHandle* seed = xeneon_config_load();
        QVERIFY(seed);
        QCOMPARE(
            xeneon_config_set_ui_state(seed, before.toUtf8().constData()), 0);
        QVERIFY(xeneon_config_save(seed) >= 0);
        xeneon_config_free(seed);

        FakeHub hub;
        hub.getReply = before;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), before, 5000);

        ConfigHandle* hubConfig = xeneon_config_load();
        QVERIFY(hubConfig);
        QCOMPARE(
            xeneon_config_set_ui_state(hubConfig, after.toUtf8().constData()), 0);
        QVERIFY(xeneon_config_save(hubConfig) >= 0);
        xeneon_config_free(hubConfig);
        hub.getReply = after;

        QSignalSpy layoutChanges(&b, &ManagerBackend::configChanged);
        hub.sendUiState(after);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), after, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(layoutChanges.count(), 1, 5000);
        QTest::qWait(100);
        QCOMPARE(layoutChanges.count(), 1);
    }

    // A tagged mutation acknowledgement, not the old 1.5-second timer, is the
    // proof that a layout reached the Hub. A stale pull must remain ignored no
    // matter how much wall-clock time passes while the newest request is pending.
    void pendingMutationIgnoresStalePullBeyondOldWindow() {
        FakeHub hub;
        hub.getReply = testState("baseline", 0);
        hub.holdSetAcks = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(
            b.uiState(), testState("baseline", 0), 5000);

        clockMs_ = 100000;
        const QString mine = testState("mine", 1);
        QVERIFY(b.saveUiState(mine));
        QTRY_COMPARE_WITH_TIMEOUT(hub.setStates.size(), 1, 5000);
        QVERIFY(b.hasPendingUiStateForTest());
        QSignalSpy spy(&b, &ManagerBackend::configChanged);
        const int beforeStale = spy.count();
        clockMs_ = 500000;
        hub.sendUiState(testState("stale", 2));
        QTest::qWait(100);
        QCOMPARE(spy.count(), beforeStale);
        const int afterStale = beforeStale;
        QTest::qWait(100);
        QCOMPARE(spy.count(), afterStale);
        QCOMPARE(b.uiState(), mine);

        hub.sendAck(
            true,
            QStringLiteral("setUiState"),
            QString(),
            hub.setRequestIds[0],
            1);
        QTRY_VERIFY_WITH_TIMEOUT(!b.hasPendingUiStateForTest(), 5000);
        QCOMPARE(b.uiState(), mine);

        const QString fresh = testState("fresh", 3);
        hub.sendUiState(fresh);
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), fresh, 5000);
        QCOMPARE(spy.count(), afterStale + 1);
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
        b.saveUiState(testState("A", 1));   // offline → buffered pending edit

        // Bring the hub up but HOLD its getUiState reply, so we sit inside the reconnect
        // window (pull sent, not yet answered) - exactly where the heisenbug lives.
        FakeHub hub; hub.holdGet = true; hub.getReply = QString();
        QVERIFY(hub.start());
        QVERIFY(b.startHub());
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 8000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("getUiState")), 8000);
        QVERIFY(hub.getPending);   // reply is genuinely withheld → we're in the window

        // Live edit B on the CONNECTED socket must win over the buffered A.
        b.saveUiState(testState("B", 2));
        QTRY_VERIFY_WITH_TIMEOUT(hub.setStates.contains(testState("B", 2)), 8000);

        // Release the held pull reply: the (now superseded) reconcile must NOT re-push A.
        hub.releaseGet();
        QTest::qWait(200);   // give any (buggy) stale re-push time to arrive

        QVERIFY(!hub.setStates.isEmpty());
        QCOMPARE(hub.setStates.last(), testState("B", 2));   // newer edit wins
        const int bIdx = hub.setStates.lastIndexOf(testState("B", 2));
        QVERIFY2(!hub.setStates.mid(bIdx + 1).contains(testState("A", 1)),
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
            FakeHub hub1; hub1.getReply = testState("S0", 1);
            QVERIFY(hub1.start());
            QVERIFY(b.startHub());
            QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 8000);
            QTRY_VERIFY_WITH_TIMEOUT(b.uiState() == testState("S0", 1), 8000);
            // Connected edit A - the fix records that the hub will now hold A.
            b.saveUiState(testState("A", 1));
            QTRY_VERIFY_WITH_TIMEOUT(hub1.setStates.contains(testState("A", 1)), 8000);
        }  // hub1 destroyed → the socket drops → b disconnects
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 8000);

        // Offline edit B (buffered while disconnected).
        b.saveUiState(testState("B", 2));

        // Hub restarts persisting A (the last thing it applied). b auto-reconnects,
        // pulls A, and must KEEP + push the newer offline edit B - not drop it.
        FakeHub hub2; hub2.getReply = testState("A", 1);
        QVERIFY(hub2.start());
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 12000);
        QTRY_VERIFY_WITH_TIMEOUT(hub2.setStates.contains(testState("B", 2)), 12000);
        QCOMPARE(hub2.setStates.last(), testState("B", 2));
    }

    // ── #7 companion: after a disconnect both Hub and Manager changed. Neither
    //    document may be silently discarded; retain the Manager edit and require
    //    an explicit Retry/Discard decision. ──
    void reconnectSurfacesConflictWhenHubChanged() {
        FakeHub hub; hub.getReply = testState("OLD", 1); QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QSignalSpy conflicts(&b, &ManagerBackend::externalConfigConflict);
        QSignalSpy saveErrors(&b, &ManagerBackend::layoutSaveError);
        clockMs_ = 100000;
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        // First pull establishes the tracked baseline: lastHubState = OLD.
        QTRY_VERIFY_WITH_TIMEOUT(b.uiState() == testState("OLD", 1), 5000);

        // Drop the connection so the next edit buffers as an offline (pending) edit.
        hub.client->abort();
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 5000);

        // The hub CHANGED while we were offline (device-side edit): OLD → NEW.
        hub.getReply = testState("NEW", 9);
        hub.setStates.clear();
        hub.received.clear();

        // Offline edit buffers AND triggers a reconnect (tryConnectHub in pushLive).
        b.saveUiState(testState("stale", 42));

        // On reconnect the pull returns NEW != OLD. No setUiState is sent until
        // the owner chooses, and the exact pending Manager bytes remain recoverable.
        QTRY_VERIFY_WITH_TIMEOUT(hub.received.contains(QStringLiteral("getUiState")), 8000);
        QTRY_COMPARE_WITH_TIMEOUT(conflicts.count(), 1, 8000);
        QCOMPARE(saveErrors.count(), 1);
        QVERIFY2(hub.setStates.isEmpty(),
                 "a conflicting buffered edit must wait for an explicit choice");
        QVERIFY(b.hasPendingUiStateForTest());
        QCOMPARE(b.pendingUiStateForTest(), testState("stale", 42));

        // Discard is explicit and only then may the Hub document replace it.
        b.discardPendingLayoutAndSync();
        QTRY_VERIFY_WITH_TIMEOUT(
            b.uiState() == testState("NEW", 9), 8000);
        QVERIFY(!b.hasPendingUiStateForTest());
    }

    // ── PULL-before-PUSH: an edit made while OFFLINE is buffered, and on reconnect
    //    the hub is pulled FIRST; since the hub didn't change, our edit is (re)pushed
    //    rather than lost - and getUiState is seen before setUiState. ──
    void reconnectKeepsOfflineEdit() {
        // No server yet → the save buffers as a pending offline edit.
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        b.saveUiState(testState("offline", 42));

        // Bring the hub up and force a connect.
        FakeHub hub; hub.getReply = QString(); QVERIFY(hub.start());
        clockMs_ = 500000;   // well past any suppression window
        QVERIFY(b.startHub());

        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 8000);
        QCOMPARE(hub.setStates.last(), testState("offline", 42));
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

        b.saveUiState(testState("connected", 9));
        // Pushed over the socket…
        QTRY_VERIFY_WITH_TIMEOUT(!hub.setStates.isEmpty(), 5000);
        QCOMPARE(hub.setStates.last(), testState("connected", 9));
        // …and the in-memory copy reflects the edit…
        QCOMPARE(b.uiState(), testState("connected", 9));
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

        ConfigHandle* stale = xeneon_config_load();
        QVERIFY(stale);
        QCOMPARE(xeneon_config_set_target_edid_hash(stale, "old-target-hash"), 0);
        QVERIFY(xeneon_config_save(stale) >= 0);
        xeneon_config_free(stale);

        HubEmu hub;                          // in-memory config: stale old hash
        QVERIFY(hub.srv.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QVERIFY(b.setTargetDisplay(QStringLiteral("DP-9"), QStringLiteral("XENEON EDGE 45")));

        // The HUB adopted the change into its LIVE config…
        XeneonString hc(xeneon_config_get_target_connector(hub.cfg));
        XeneonString hm(xeneon_config_get_target_model(hub.cfg));
        XeneonString hh(xeneon_config_get_target_edid_hash(hub.cfg));
        QCOMPARE(hc.qstring(), QStringLiteral("DP-9"));
        QCOMPARE(hm.qstring(), QStringLiteral("XENEON EDGE 45"));
        QVERIFY(hh.qstring().isEmpty());

        // …so the hub's next save cannot clobber it.
        hub.save();

        ConfigHandle* onDisk = xeneon_config_load();
        QVERIFY(onDisk);
        XeneonString dc(xeneon_config_get_target_connector(onDisk));
        XeneonString dm(xeneon_config_get_target_model(onDisk));
        XeneonString dh(xeneon_config_get_target_edid_hash(onDisk));
        xeneon_config_free(onDisk);
        QCOMPARE(dc.qstring(), QStringLiteral("DP-9"));
        QCOMPARE(dm.qstring(), QStringLiteral("XENEON EDGE 45"));
        QVERIFY(dh.qstring().isEmpty());
    }

    void disconnectReloadsHubOwnedGenerationBeforeOfflineSave() {
        XeneonString cd(xeneon_config_dir());
        const QString cfgPath = cd.qstring() + "/config.toml";
        QFile::remove(cfgPath);

        ManagerBackend b;
        {
            HubEmu hub;
            QVERIFY(hub.srv.start());
            QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
            QVERIFY(b.setTargetDisplay(
                QStringLiteral("DP-8"), QStringLiteral("XENEON EDGE")));
        }
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 8000);

        // The Hub's setter replaced config.toml while the Manager still held
        // the older generation. The disconnect reload must make the next
        // legitimate offline write succeed instead of either clobbering or
        // rejecting the user's edit.
        QVERIFY(b.saveUiState(testState("offline-after-hub", 1)));
        QCOMPARE(b.uiState(), testState("offline-after-hub", 1));
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

    void connectedSetterSurfacesUncertainDurability() {
        FakeHub hub;
        hub.getReply = QString();
        hub.ackFieldSetters = true;
        hub.setterDurabilityUncertain = true;
        QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QSignalSpy errors(&b, &ManagerBackend::saveError);
        QVERIFY(b.setTargetDisplay(QStringLiteral("DP-3"), QStringLiteral("Panel")));
        QCOMPARE(errors.count(), 1);
        QVERIFY(errors.takeFirst().at(0).toString().contains(
            QStringLiteral("crash durability")));
        QVERIFY(b.setAutostart(false));
        QCOMPARE(errors.count(), 1);
        QVERIFY(errors.takeFirst().at(0).toString().contains(
            QStringLiteral("crash durability")));
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

        QVERIFY(b.saveUiState(testState("offline", 5)));
        QVERIFY(QFile::exists(cfg));               // sole writer persisted directly
        QVERIFY(b.confirmShutdownUiStatePersisted());
    }

    void durableOfflineSaveNeedsNoAckDuringReconnectPull() {
        ManagerBackend b;
        const QString state = testState("offline-durable-reconnect", 1);
        QVERIFY(b.saveUiState(state));
        QVERIFY(b.confirmShutdownUiStatePersisted());

        FakeHub hub;
        hub.holdGet = true;
        QVERIFY(hub.start());
        QVERIFY(b.startHub());
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(hub.getPending, 5000);

        QElapsedTimer elapsed;
        elapsed.start();
        QVERIFY(b.confirmShutdownUiStatePersisted());
        QVERIFY2(
            elapsed.elapsed() < 250,
            "a disk-durable edit awaiting reconnect reconciliation needs no empty-id ack");
    }

    void unsupportedDashboardSchemaDoesNotOpenAnEditableBackend() {
        XeneonString cd(xeneon_config_dir());
        const QString path = cd.qstring() + QStringLiteral("/config.toml");
        QFile::remove(path);

        ConfigHandle* config = xeneon_config_load();
        QVERIFY(config);
        QCOMPARE(xeneon_config_save(config), 0);
        xeneon_config_free(config);

        QFile file(path);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QByteArray bytes = file.readAll();
        file.close();
        const int table = bytes.indexOf("\n[display]");
        QVERIFY(table > 0);
        bytes.insert(table,
                     "\nui_state = '{\"version\":99,\"pages\":[],"
                     "\"futureOnly\":true}'\n");
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QCOMPARE(file.write(bytes), bytes.size());
        file.close();

        ManagerBackend backend;
        QVERIFY(!backend.configAvailable());

        QFile::remove(path);
    }
};

int main(int argc, char** argv) {
    if (argc > 1 && QByteArray(argv[1]) == QByteArrayLiteral("--hub"))
        return runDetachedAppImageHub(argc, argv);
    QGuiApplication application(argc, argv);
    TstManagerBackendSync test;
    return QTest::qExec(&test, argc, argv);
}
#include "tst_manager_backend_sync.moc"
