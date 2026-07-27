// Integration tests for ControlServer over a REAL QLocalSocket. Covers the full
// newline-delimited JSON protocol: ping, getUiState, setUiState (honest ok/fail
// ack), empty/malformed/unknown, shutdown ordering, the 8 MiB buffer cap,
// re-entrancy (multiple lines + a handler that re-enters the event loop), and
// that the socket is confined to $XDG_RUNTIME_DIR.
#include <QtTest>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QDir>
#include <QFile>
#include <QCoreApplication>

#include <sys/stat.h>
#include <unistd.h>

#include "control_server.h"
#include "control_protocol.h"
#include "control_socket_path.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

// Resolved the same way production does - the point of the shared header.
static QString sockPath() { return xeneon::controlSocketPath(); }

// The path the socket must NEVER land on: what a bare QLocalServer name resolves
// to via QDir::tempPath(). A live hub's node sits here on a developer machine.
static QString legacyTmpPath() {
    return QDir::tempPath() + QStringLiteral("/xeneon-edge-hub-ctl");
}

// Simulates a session with no XDG_RUNTIME_DIR, with TMPDIR aimed at `tmpRoot` so
// the fallback stays inside the test's sandbox. Restores both on scope exit -
// including when a QVERIFY bails out early, which is why this is a guard object
// and not a pair of calls: a leaked unset XDG_RUNTIME_DIR would trash every slot
// that runs afterwards.
class EnvSwap {
public:
    explicit EnvSwap(const QString& tmpRoot)
        : savedRuntime_(qgetenv("XDG_RUNTIME_DIR")), savedTmpdir_(qgetenv("TMPDIR")),
          hadTmpdir_(qEnvironmentVariableIsSet("TMPDIR")) {
        qputenv("TMPDIR", QFile::encodeName(tmpRoot));
        qunsetenv("XDG_RUNTIME_DIR");
    }
    ~EnvSwap() {
        qputenv("XDG_RUNTIME_DIR", savedRuntime_);
        if (hadTmpdir_)
            qputenv("TMPDIR", savedTmpdir_);
        else
            qunsetenv("TMPDIR");
    }
    Q_DISABLE_COPY_MOVE(EnvSwap)
private:
    QByteArray savedRuntime_;
    QByteArray savedTmpdir_;
    bool hadTmpdir_;
};

class TstControlServer : public QObject {
    Q_OBJECT

    ControlServer* srv_ = nullptr;
    QString providerState_;
    bool ackResult_ = true;
    bool liveApplyResult_ = true;
    // Stand-in for main()'s per-field apply handlers: record what the owner was told
    // to apply and control whether it reports success.
    bool applyResult_ = true;
    bool applyDurabilityUncertain_ = false;
    QString gotConnector_;
    QString gotModel_;
    bool gotAutostart_ = false;
    QString gotLicense_;
    int gotActivePage_ = -999;

    // Open a client, send one request line, collect `nLines` reply lines. The
    // server and client share this thread's event loop, so we PUMP events (rather
    // than block on the client fd) - otherwise the server never accepts/replies.
    QList<QJsonObject> exchange(const QByteArray& req, int nLines = 1) {
        QLocalSocket c;
        c.connectToServer(sockPath());
        QElapsedTimer t; t.start();
        while (c.state() != QLocalSocket::ConnectedState && t.elapsed() < 3000)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        if (c.state() != QLocalSocket::ConnectedState) return {};

        QByteArray line = req;
        if (!line.endsWith('\n')) line.append('\n');
        c.write(line);
        c.flush();

        QByteArray buf;
        QList<QJsonObject> out;
        t.restart();
        while (out.size() < nLines && t.elapsed() < 3000) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            buf += c.readAll();
            int nl;
            while ((nl = buf.indexOf('\n')) >= 0) {
                out << QJsonDocument::fromJson(buf.left(nl)).object();
                buf.remove(0, nl + 1);
            }
        }
        return out;
    }

private slots:
    void init() {
        providerState_.clear();
        ackResult_ = true;
        liveApplyResult_ = true;
        applyResult_ = true;
        applyDurabilityUncertain_ = false;
        gotConnector_.clear();
        gotModel_.clear();
        gotAutostart_ = false;
        gotLicense_.clear();
        gotActivePage_ = -999;
        srv_ = new ControlServer(this);
        srv_->setStateProvider([this] { return providerState_; });
        connect(srv_, &ControlServer::uiStateReceived, this,
                [this](const QString&, bool* ok, bool* liveApplied) {
                    if (ok) *ok = ackResult_;
                    if (liveApplied) *liveApplied = liveApplyResult_;
                });
        connect(srv_, &ControlServer::targetDisplayReceived, this,
                [this](const QString& c, const QString& m, bool* ok,
                       bool* durabilityUncertain) {
                    gotConnector_ = c; gotModel_ = m;
                    if (ok) *ok = applyResult_;
                    if (durabilityUncertain)
                        *durabilityUncertain = applyDurabilityUncertain_;
                });
        connect(srv_, &ControlServer::autostartReceived, this,
                [this](bool enabled, bool* ok, bool* durabilityUncertain) {
                    gotAutostart_ = enabled;
                    if (ok) *ok = applyResult_;
                    if (durabilityUncertain)
                        *durabilityUncertain = applyDurabilityUncertain_;
                });
        connect(srv_, &ControlServer::licenseKeyReceived, this,
                [this](const QString& key, bool* ok) {
                    gotLicense_ = key;
                    if (ok) *ok = applyResult_;
                });
        QVERIFY(srv_->start());
    }
    void cleanup() {
        delete srv_;
        srv_ = nullptr;
        QLocalServer::removeServer(sockPath());
    }

    void ping() {
        const auto r = exchange("{\"type\":\"ping\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("pong"));
    }

    void getUiState() {
        providerState_ = QStringLiteral("{\"layout\":\"grid\"}");
        const auto r = exchange("{\"type\":\"getUiState\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("uiState"));
        QCOMPARE(r[0].value("state").toString(), providerState_);
        QVERIFY(!r[0].contains(QStringLiteral("configGenerationToken")));
    }

    void getUiStateIncludesLivePanelContext() {
        providerState_ = QStringLiteral("{\"layout\":\"pages\"}");
        srv_->setRotationProvider([] { return 270; });
        srv_->setPageProvider([] { return 2; });
        srv_->setStateLiveProvider([] { return false; });
        srv_->setConfigGenerationTokenProvider(
            [] { return QStringLiteral("opaque-generation-7"); });
        const auto r = exchange("{\"type\":\"getUiState\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("uiState"));
        QCOMPARE(r[0].value("state").toString(), providerState_);
        QCOMPARE(r[0].value("rotation").toInt(), 270);
        QCOMPARE(r[0].value("currentPage").toInt(), 2);
        QCOMPARE(r[0].value("stateLive").toBool(), false);
        QCOMPARE(
            r[0].value("configGenerationToken").toString(),
            QStringLiteral("opaque-generation-7"));
    }

    void setActivePageInvokesHandlerAndAcks() {
        srv_->setActivePageHandler([this](int page) { gotActivePage_ = page; });
        const auto r = exchange(
            "{\"type\":\"setActivePage\",\"page\":4,\"requestId\":\"page-1\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("page-1"));
        QCOMPARE(gotActivePage_, 4);

        // A missing/non-number page is explicitly represented as unknown (-1),
        // leaving clamping/rejection to the same owner callback as production.
        const auto missing = exchange("{\"type\":\"setActivePage\"}");
        QCOMPARE(missing.size(), 1);
        QCOMPARE(missing[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(gotActivePage_, -1);
    }

    void setUiStateOkAck() {
        ackResult_ = true;
        QSignalSpy spy(srv_, &ControlServer::uiStateReceived);
        const auto r = exchange(
            "{\"type\":\"setUiState\",\"state\":\"{\\\"a\\\":1}\",\"requestId\":\"17\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setUiState"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("17"));
        QCOMPARE(r[0].value("liveApplied").toBool(), true);
        QCOMPARE(r[0].value("queued").toBool(), false);
        QCOMPARE(spy.count(), 1);
    }

    // Honest fail ack: when the owner reports the apply failed, the ack must be an
    // error, not a lie of success (else the Manager silently diverges).
    void setUiStateFailAck() {
        ackResult_ = false;
        const auto r = exchange(
            "{\"type\":\"setUiState\",\"state\":\"{\\\"a\\\":1}\",\"requestId\":\"18\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setUiState"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("18"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("failed to apply state"));
    }

    void setUiStateCanBeStoredButQueuedForLiveApplication() {
        ackResult_ = true;
        liveApplyResult_ = false;
        const auto r = exchange(
            "{\"type\":\"setUiState\",\"state\":\"{\\\"a\\\":1}\","
            "\"requestId\":\"queued-1\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("queued-1"));
        QCOMPARE(r[0].value("liveApplied").toBool(), false);
        QCOMPARE(r[0].value("queued").toBool(), true);
    }

    void setUiStateEmpty() {
        const auto r =
            exchange("{\"type\":\"setUiState\",\"state\":\"\",\"requestId\":\"19\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setUiState"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("19"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("empty state"));
    }

    // ── Per-field setters (B5 two-writer race): the hub is asked to adopt the value
    //    so it stays the single writer of config.toml. Acks carry "for" so a client
    //    can match a reply to its request. ──
    void setTargetDisplayOkAck() {
        applyResult_ = true;
        const auto r = exchange(
            "{\"type\":\"setTargetDisplay\",\"connector\":\"DP-3\","
            "\"model\":\"XENEON EDGE\",\"requestId\":\"target-1\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setTargetDisplay"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("target-1"));
        QCOMPARE(gotConnector_, QStringLiteral("DP-3"));
        QCOMPARE(gotModel_, QStringLiteral("XENEON EDGE"));
    }

    // Honest fail ack: an owner that could not apply/persist must produce an error.
    void setTargetDisplayFailAck() {
        applyResult_ = false;
        const auto r = exchange(
            "{\"type\":\"setTargetDisplay\",\"connector\":\"DP-3\","
            "\"model\":\"M\",\"requestId\":\"target-fail\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setTargetDisplay"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("target-fail"));
        QCOMPARE(r[0].value("message").toString(),
                 QStringLiteral("failed to apply target display"));
    }

    // An all-empty target is rejected rather than blanking the hub's display match.
    void setTargetDisplayEmptyRejected() {
        QSignalSpy spy(srv_, &ControlServer::targetDisplayReceived);
        const auto r = exchange("{\"type\":\"setTargetDisplay\",\"connector\":\"\",\"model\":\"\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("empty target display"));
        QCOMPARE(spy.count(), 0);   // never reached the owner
    }

    // Either identifier alone is a legitimate target.
    void setTargetDisplayModelOnly() {
        applyResult_ = true;
        gotConnector_ = QStringLiteral("unset");
        const auto r = exchange("{\"type\":\"setTargetDisplay\",\"model\":\"XENEON EDGE\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QVERIFY(gotConnector_.isEmpty());
        QCOMPARE(gotModel_, QStringLiteral("XENEON EDGE"));
    }

    void setTargetDisplayReportsUncertainDurability() {
        applyResult_ = true;
        applyDurabilityUncertain_ = true;
        const auto r = exchange(
            "{\"type\":\"setTargetDisplay\",\"connector\":\"DP-3\","
            "\"requestId\":\"target-uncertain\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("durabilityUncertain").toBool(), true);
    }

    void setAutostartOkAck() {
        applyResult_ = true;
        gotAutostart_ = false;
        const auto r = exchange(
            "{\"type\":\"setAutostart\",\"enabled\":true,\"requestId\":\"auto-on\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setAutostart"));
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("auto-on"));
        QVERIFY(gotAutostart_);

        gotAutostart_ = true;
        const auto r2 = exchange(
            "{\"type\":\"setAutostart\",\"enabled\":false,\"requestId\":\"auto-off\"}");
        QCOMPARE(r2[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r2[0].value("requestId").toString(), QStringLiteral("auto-off"));
        QVERIFY(!gotAutostart_);
    }

    void setAutostartFailAck() {
        applyResult_ = false;
        const auto r = exchange("{\"type\":\"setAutostart\",\"enabled\":true}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("failed to apply autostart"));
    }

    void setAutostartReportsUncertainDurability() {
        applyResult_ = true;
        applyDurabilityUncertain_ = true;
        const auto r = exchange(
            "{\"type\":\"setAutostart\",\"enabled\":true,"
            "\"requestId\":\"auto-uncertain\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[0].value("durabilityUncertain").toBool(), true);
    }

    // A missing/non-bool `enabled` must NOT be coerced to false (which would silently
    // turn autostart OFF on a malformed request) - it is rejected.
    void setAutostartRequiresBool() {
        QSignalSpy spy(srv_, &ControlServer::autostartReceived);
        for (const char* req : {"{\"type\":\"setAutostart\"}",
                                "{\"type\":\"setAutostart\",\"enabled\":\"true\"}",
                                "{\"type\":\"setAutostart\",\"enabled\":1}"}) {
            const auto r = exchange(req);
            QCOMPARE(r.size(), 1);
            QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
            QCOMPARE(r[0].value("message").toString(), QStringLiteral("missing enabled flag"));
        }
        QCOMPARE(spy.count(), 0);
    }

    void setLicenseKeyOkAndExplicitClear() {
        applyResult_ = true;
        QSignalSpy spy(srv_, &ControlServer::licenseKeyReceived);

        const auto set = exchange(
            "{\"type\":\"setLicenseKey\",\"key\":\"XE1.invalid.signature\","
            "\"requestId\":\"license-set\"}");
        QCOMPARE(set.size(), 1);
        QCOMPARE(set[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(set[0].value("for").toString(), QStringLiteral("setLicenseKey"));
        QCOMPARE(set[0].value("requestId").toString(), QStringLiteral("license-set"));
        QCOMPARE(gotLicense_, QStringLiteral("XE1.invalid.signature"));

        // Empty string is the deliberate remove-key operation and remains valid.
        const auto clear = exchange(
            "{\"type\":\"setLicenseKey\",\"key\":\"\",\"requestId\":\"license-clear\"}");
        QCOMPARE(clear.size(), 1);
        QCOMPARE(clear[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(clear[0].value("requestId").toString(), QStringLiteral("license-clear"));
        QVERIFY(gotLicense_.isEmpty());
        QCOMPARE(spy.count(), 2);
    }

    void setLicenseKeyFailAck() {
        applyResult_ = false;
        const auto r = exchange("{\"type\":\"setLicenseKey\",\"key\":\"candidate\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("for").toString(), QStringLiteral("setLicenseKey"));
        QCOMPARE(r[0].value("message").toString(),
                 QStringLiteral("failed to apply licence key"));
    }

    void setLicenseKeyRequiresStringField() {
        QSignalSpy spy(srv_, &ControlServer::licenseKeyReceived);
        for (const char* req : {"{\"type\":\"setLicenseKey\"}",
                                "{\"type\":\"setLicenseKey\",\"key\":false}",
                                "{\"type\":\"setLicenseKey\",\"key\":7}"}) {
            const auto r = exchange(req);
            QCOMPARE(r.size(), 1);
            QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
            QCOMPARE(r[0].value("message").toString(), QStringLiteral("missing key field"));
        }
        QCOMPARE(spy.count(), 0);
    }

    void malformedJson() {
        const auto r = exchange("{not json");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("invalid json"));
    }

    void unknownType() {
        const auto r = exchange("{\"type\":\"frobnicate\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("error"));
        QCOMPARE(r[0].value("message").toString(), QStringLiteral("unknown type"));
    }

    // shutdown ORDERING: the ack MUST be written+flushed BEFORE shutdownRequested is
    // emitted. We wire the shutdown slot to immediately tear the server down (as
    // main() quits the loop on shutdown), so the ok is only observable if it was
    // written first - a reversed (emit-before-write) order would close the socket and
    // DROP the ack, making `r` empty.
    void shutdownAcksThenSignals() {
        QSignalSpy spy(srv_, &ControlServer::shutdownRequested);
        ControlServer* dying = srv_;
        QMetaObject::Connection conn = connect(srv_, &ControlServer::shutdownRequested, this,
            [dying] { dying->deleteLater(); });   // tear down on shutdown, like main()
        const auto r = exchange(
            "{\"type\":\"shutdown\",\"requestId\":\"shutdown-1\"}");
        disconnect(conn);
        srv_ = nullptr;   // handed to deleteLater; keep cleanup() from double-deleting
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));   // ack survived
        QCOMPARE(r[0].value("requestId").toString(), QStringLiteral("shutdown-1"));
        QVERIFY(spy.count() >= 1);                                        // signal fired
    }

    // 8 MiB cap: a client that streams a huge line with no newline has its
    // connection dropped rather than growing the buffer unbounded.
    void oversizedMessageDropsConnection() {
        QLocalSocket c;
        c.connectToServer(sockPath());
        QElapsedTimer t; t.start();
        while (c.state() != QLocalSocket::ConnectedState && t.elapsed() < 3000)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QVERIFY(c.state() == QLocalSocket::ConnectedState);

        QByteArray chunk(1024 * 1024, 'x');   // 1 MiB, no newline
        for (int i = 0; i < 10 && c.state() == QLocalSocket::ConnectedState; ++i) {
            c.write(chunk);
            c.flush();
            c.waitForBytesWritten(500);
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        }
        // Server aborts the connection once the buffer exceeds 8 MiB.
        t.restart();
        while (c.state() == QLocalSocket::ConnectedState && t.elapsed() < 3000)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QVERIFY(c.state() != QLocalSocket::ConnectedState);
    }

    // Two complete requests in a single write must both be processed, in order.
    void multipleLinesInOneWrite() {
        const auto r = exchange("{\"type\":\"ping\"}\n{\"type\":\"ping\"}", /*nLines*/ 2);
        QCOMPARE(r.size(), 2);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("pong"));
        QCOMPARE(r[1].value("type").toString(), QStringLiteral("pong"));
    }

    // The cap is per frame, not per read chunk. Two legal complete frames may
    // arrive together with an aggregate larger than the cap and both must run.
    void aggregateReadLargerThanCapKeepsLegalFrames() {
        const QString payload(4 * 1024 * 1024, QLatin1Char('x'));
        const QByteArray first =
            QJsonDocument(QJsonObject{{"type", "setUiState"},
                                      {"state", payload},
                                      {"requestId", "large-1"}})
                .toJson(QJsonDocument::Compact);
        const QByteArray second =
            QJsonDocument(QJsonObject{{"type", "setUiState"},
                                      {"state", payload},
                                      {"requestId", "large-2"}})
                .toJson(QJsonDocument::Compact);
        QVERIFY(first.size() < xeneon::kMaxControlFrameBytes);
        QVERIFY(second.size() < xeneon::kMaxControlFrameBytes);
        QVERIFY(first.size() + second.size() > xeneon::kMaxControlFrameBytes);

        const auto replies = exchange(first + "\n" + second, 2);
        QCOMPARE(replies.size(), 2);
        QCOMPARE(replies[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(replies[0].value("requestId").toString(), QStringLiteral("large-1"));
        QCOMPARE(replies[1].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(replies[1].value("requestId").toString(), QStringLiteral("large-2"));
    }

    // A handler that re-enters the event loop (processEvents) mid-dispatch must not
    // corrupt the per-connection buffer. Send TWO complete requests in ONE write: the
    // FIRST handler re-enters the event loop, so onReadyRead()'s line loop must
    // re-look-up the buffer (not hold a stale iterator) and still process the SECOND
    // line - exercising the multi-line dangling-iterator guard, not just single-line.
    void reentrantHandlerSafe() {
        ackResult_ = true;
        QMetaObject::Connection conn = connect(srv_, &ControlServer::uiStateReceived, this,
            [](const QString&, bool*, bool*) { QCoreApplication::processEvents(); });
        const auto r = exchange(
            "{\"type\":\"setUiState\",\"state\":\"{\\\"x\\\":1}\"}\n"
            "{\"type\":\"setUiState\",\"state\":\"{\\\"y\\\":2}\"}", /*nLines*/ 2);
        disconnect(conn);
        QCOMPARE(r.size(), 2);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("ok"));
        QCOMPARE(r[1].value("type").toString(), QStringLiteral("ok"));
    }

    // ── The socket is confined to $XDG_RUNTIME_DIR ──
    //
    // REGRESSION. The socket used to be a BARE QLocalServer name, and Qt resolves
    // a bare name via QDir::tempPath() - so the hub, and every run of this test,
    // bound the single shared /tmp/xeneon-edge-hub-ctl. Two things followed, both
    // observed on a real machine:
    //   * start()'s removeServer() UNLINKED a live hub's socket. That hub keeps
    //     its listening fd and logs nothing, so it looks healthy while no client
    //     can reach it again until it restarts. Sandboxing XDG_RUNTIME_DIR (see
    //     hermetic.h) did not help - the path was never inside the sandbox.
    //   * /tmp is world-writable, so any local user could squat the node.
    void socketIsConfinedToRuntimeDir() {
        const QString runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
        QVERIFY2(!runtimeDir.isEmpty(), "hermetic.h should guarantee a sandboxed XDG_RUNTIME_DIR");

        // init() already start()ed srv_ on the production-resolved path.
        const QString path = sockPath();
        QVERIFY2(QFileInfo::exists(path),
                 qPrintable(QStringLiteral("no socket node at %1").arg(path)));
        QCOMPARE(QFileInfo(path).canonicalPath(), QFileInfo(runtimeDir).canonicalFilePath());
        struct stat socketStat {};
        QCOMPARE(::lstat(QFile::encodeName(path).constData(), &socketStat), 0);
        QVERIFY(S_ISSOCK(socketStat.st_mode));
        QCOMPARE(socketStat.st_uid, ::getuid());
        QCOMPARE(socketStat.st_mode & 0077, 0u);

        // …and it is a real, serving endpoint there, not just a leftover node.
        const auto r = exchange("{\"type\":\"ping\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("pong"));
    }

    // Starting a server must leave the shared /tmp node completely alone.
    //
    // This deliberately asserts against the REAL shared path rather than a
    // fixture: the whole failure mode was production ESCAPING the sandbox, which
    // a sandboxed stand-in cannot observe. The test only ever READS that path -
    // it is the old production code that wrote to it.
    void startDoesNotTouchSharedTmpSocket() {
        const QString shared = legacyTmpPath();
        // Identify by inode, so a same-path replacement (unlink + rebind, which is
        // exactly what removeServer() + listen() did) is caught, not just deletion.
        const auto snapshot = [&shared]() -> QString {
            struct stat st {};
            if (::lstat(QFile::encodeName(shared).constData(), &st) != 0)
                return QStringLiteral("<absent>");
            return QStringLiteral("ino=%1").arg(st.st_ino);
        };

        const QString before = snapshot();
        delete srv_;                        // the instance init() started
        srv_ = new ControlServer(this);
        QVERIFY(srv_->start());             // start()'s removeServer() used to unlink `shared`

        QCOMPARE(snapshot(), before);
    }

    // ── No XDG_RUNTIME_DIR (headless / su / some systemd contexts) ──
    //
    // The socket must still land in a PRIVATE per-uid directory. The old bare name
    // effectively fell back to the world-writable temp root itself, which is the
    // squattable arrangement this change exists to remove - so "no runtime dir" may
    // not mean "shared path".
    //
    // The fallback is kept inside this test's sandbox by pointing TMPDIR at it:
    // QDir::tempPath() follows TMPDIR, and so, transitively, does the header.
    void fallbackWithoutRuntimeDirIsPrivate() {
        const QString sandbox = qEnvironmentVariable("XDG_RUNTIME_DIR");
        QVERIFY(!sandbox.isEmpty());
        EnvSwap swap(sandbox);              // TMPDIR=sandbox, XDG_RUNTIME_DIR unset

        const QString dir = sandbox + QStringLiteral("/xeneon-edge-hub-") +
                            QString::number(static_cast<uint>(::getuid()));
        const QString path = xeneon::controlSocketPath();
        QCOMPARE(path, dir + QStringLiteral("/xeneon-edge-hub-ctl"));

        // Private: 0700 and owned by us - not the temp root, and not group/other
        // accessible.
        struct stat st {};
        QCOMPARE(::lstat(QFile::encodeName(dir).constData(), &st), 0);
        QVERIFY(S_ISDIR(st.st_mode));
        QCOMPARE(st.st_uid, ::getuid());
        QCOMPARE(st.st_mode & 0777, 0700u);

        // And it is a working endpoint, not merely a well-named directory.
        delete srv_;
        srv_ = new ControlServer(this);
        srv_->setStateProvider([this] { return providerState_; });
        QVERIFY(srv_->start());
        const auto r = exchange("{\"type\":\"ping\"}");
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].value("type").toString(), QStringLiteral("pong"));

        delete srv_;                        // unbind before EnvSwap restores the env
        srv_ = nullptr;
    }

    // A fallback dir that someone else can write to is a hijack of the live-push
    // channel, so it is REFUSED rather than used: no path, and start() fails
    // closed (the hub simply runs without live control) instead of binding it.
    void fallbackRefusesGroupWritableDir() {
        const QString sandbox = qEnvironmentVariable("XDG_RUNTIME_DIR");
        QVERIFY(!sandbox.isEmpty());
        EnvSwap swap(sandbox);

        const QString dir = sandbox + QStringLiteral("/xeneon-edge-hub-") +
                            QString::number(static_cast<uint>(::getuid()));
        QVERIFY(QDir().mkpath(dir));
        const QByteArray raw = QFile::encodeName(dir);
        QCOMPARE(::chmod(raw.constData(), 0777), 0);   // squatted: anyone may write

        QVERIFY2(xeneon::controlSocketPath().isEmpty(),
                 "a world-writable fallback dir must yield no socket path");

        delete srv_;
        srv_ = new ControlServer(this);
        QVERIFY2(!srv_->start(), "start() must fail closed rather than bind a shared dir");
        delete srv_;
        srv_ = nullptr;

        ::chmod(raw.constData(), 0700);   // leave the sandbox tidy for later slots
    }
};

QTEST_GUILESS_MAIN(TstControlServer)
#include "tst_control_server.moc"
